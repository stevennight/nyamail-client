import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../security/local_cache_crypto.dart';
import 'mail_models.dart';
import 'mail_transport.dart';

abstract class MailMessageCache {
  Future<void> saveMessages(List<MailMessage> messages);
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
  });
  Future<void> updateMessage(MailMessage message);
  Future<void> deleteMessage(String messageId);
  Future<void> deleteMessages(Iterable<String> messageIds);
  Future<void> clear();
}

class MailCache implements MailMessageCache {
  const MailCache({
    this.namespace,
    this.localCacheSecret,
    this.supportDirectoryProvider,
  });

  final String? namespace;
  final String? localCacheSecret;
  final Future<Directory> Function()? supportDirectoryProvider;

  static final Map<String, _AsyncMutex> _locks = <String, _AsyncMutex>{};
  static final Map<String, _CachedMessageFile> _memoryCaches =
      <String, _CachedMessageFile>{};
  static const _backgroundCacheWorkThreshold = 48 * 1024;
  static const _maxMemoryCaches = 2;
  static int _memoryAccessSequence = 0;

  @override
  Future<void> saveMessages(List<MailMessage> messages) async {
    if (messages.isEmpty) return;
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final existing = await _loadMessagesFromFile(file);
      final byId = {for (final message in existing) message.id: message};
      var changed = false;
      for (final message in messages) {
        final normalized = _normalizeCachedMessage(message);
        final current = byId[normalized.id];
        final next =
            current != null && current.bodyLoaded && !normalized.bodyLoaded
                ? normalized.copyWith(
                  body: current.body,
                  htmlBody: current.htmlBody,
                  hasAttachments: current.hasAttachments,
                  attachments: current.attachments,
                  bodyLoaded: true,
                )
                : normalized;
        if (current == null || !_sameCachedMessage(current, next)) {
          changed = true;
        }
        byId[normalized.id] = next;
      }
      if (!changed) return;
      await _writeMessagesToFile(file, byId.values);
    });
  }

  @override
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
  }) async {
    final file = await _cacheFile();
    return _lockFor(file).synchronized(() async {
      final decoded = await _loadMessagesFromFile(file);
      final normalizedQuery = query?.trim() ?? '';
      if (mailbox == null &&
          accountId == null &&
          folderPath == null &&
          normalizedQuery.isEmpty) {
        return decoded;
      }
      final scoped = decoded
          .where((message) {
            if (mailbox != null && message.effectiveMailbox != mailbox) {
              return false;
            }
            if (accountId != null && message.accountId != accountId) {
              return false;
            }
            if (folderPath != null &&
                message.effectiveFolderPath != folderPath) {
              return false;
            }
            return true;
          })
          .toList(growable: false);
      if (normalizedQuery.isEmpty) return scoped;
      return scoped
          .where((message) => mailMessageMatchesQuery(message, normalizedQuery))
          .toList(growable: false);
    });
  }

  Future<List<MailMessage>> _loadMessagesFromFile(File file) async {
    final memory = _memoryFor(file);
    final remembered = memory.messages;
    if (remembered != null) return remembered;
    if (!await file.exists()) return _rememberMessages(file, const []);
    try {
      final raw = await file.readAsString(encoding: utf8);
      final secret = _normalizedLocalCacheSecret;
      final decoded =
          raw.length >= _backgroundCacheWorkThreshold
              ? await Isolate.run(() => _decodeCachedMessages(raw, secret))
              : await _decodeCachedMessages(raw, secret);
      if (decoded.shouldQuarantine) {
        await _quarantineUnreadableCache(file);
        return _rememberMessages(file, const []);
      }
      return _rememberMessages(file, decoded.messages);
    } catch (error) {
      if (_isCacheFormatError(error)) {
        await _quarantineUnreadableCache(file);
        return _rememberMessages(file, const []);
      }
      rethrow;
    }
  }

  Future<File> _cacheFile() async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    final namespace = _safeCacheNamespace(this.namespace);
    if (namespace == null) {
      return File('${dir.path}/mail-cache/messages.json');
    }
    return File('${dir.path}/mail-cache/$namespace/messages.json');
  }

  @override
  Future<void> clear() async {
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final namespace = _safeCacheNamespace(this.namespace);
      if (namespace == null) {
        if (await file.exists()) {
          await file.delete();
        }
        _forgetMessagesForFile(file);
        return;
      }
      final dir = file.parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _forgetMessagesInDirectory(dir);
    });
  }

  @override
  Future<void> updateMessage(MailMessage message) {
    return saveMessages([message]);
  }

  @override
  Future<void> deleteMessage(String messageId) {
    return deleteMessages([messageId]);
  }

  @override
  Future<void> deleteMessages(Iterable<String> messageIds) async {
    final ids = messageIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final existing = await _loadMessagesFromFile(file);
      final remaining = existing
          .where((message) => !ids.contains(message.id))
          .toList(growable: false);
      if (remaining.length == existing.length) return;
      await _writeMessagesToFile(file, remaining);
    });
  }

  _AsyncMutex _lockFor(File file) {
    return _locks.putIfAbsent(file.path, _AsyncMutex.new);
  }

  _CachedMessageFile _memoryFor(File file) {
    final key = _memoryKeyFor(file);
    final memory = _memoryCaches.putIfAbsent(key, _CachedMessageFile.new);
    memory.lastAccess = ++_memoryAccessSequence;
    while (_memoryCaches.length > _maxMemoryCaches) {
      String? oldestKey;
      var oldestAccess = _memoryAccessSequence;
      for (final entry in _memoryCaches.entries) {
        if (entry.key == key) continue;
        if (oldestKey == null || entry.value.lastAccess < oldestAccess) {
          oldestKey = entry.key;
          oldestAccess = entry.value.lastAccess;
        }
      }
      if (oldestKey == null) break;
      _memoryCaches.remove(oldestKey);
    }
    return memory;
  }

  List<MailMessage> _rememberMessages(
    File file,
    Iterable<MailMessage> messages,
  ) {
    final remembered = List<MailMessage>.unmodifiable(
      messages.map(_normalizeCachedMessage),
    );
    _memoryFor(file).messages = remembered;
    return remembered;
  }

  void _forgetMessagesForFile(File file) {
    final prefix = '${file.path}\u0000';
    _memoryCaches.removeWhere((key, _) => key.startsWith(prefix));
  }

  void _forgetMessagesInDirectory(Directory dir) {
    final normalizedDir = dir.path.replaceAll('\\', '/');
    final prefix =
        normalizedDir.endsWith('/') ? normalizedDir : '$normalizedDir/';
    _memoryCaches.removeWhere((key, _) {
      final path = key.split('\u0000').first;
      final normalizedPath = path.replaceAll('\\', '/');
      return normalizedPath == normalizedDir ||
          normalizedPath.startsWith(prefix);
    });
  }

  String _memoryKeyFor(File file) {
    final secret = _normalizedLocalCacheSecret;
    final keyMaterial = secret ?? 'plaintext';
    final fingerprint = sha256.convert(utf8.encode(keyMaterial)).toString();
    return '${file.path}\u0000$fingerprint';
  }

  Future<void> _writeMessagesToFile(
    File file,
    Iterable<MailMessage> messages,
  ) async {
    final snapshot = List<MailMessage>.of(messages)
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    await file.parent.create(recursive: true);
    final secret = _normalizedLocalCacheSecret;
    final output =
        _estimatedCachePayloadSize(snapshot) >= _backgroundCacheWorkThreshold
            ? await Isolate.run(
              () => _serializeCachedMessages(snapshot, secret),
            )
            : await _serializeCachedMessages(snapshot, secret);
    final temp = File(
      '${file.path}.tmp-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
    await temp.writeAsString(output, encoding: utf8, flush: true);
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    }
    _rememberMessages(file, snapshot);
  }

  String? get _normalizedLocalCacheSecret {
    final secret = localCacheSecret?.trim();
    return secret == null || secret.isEmpty ? null : secret;
  }

  Future<void> _quarantineUnreadableCache(File file) async {
    if (!await file.exists()) {
      _forgetMessagesForFile(file);
      return;
    }
    final backup = File(
      '${file.path}.invalid-${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
    try {
      await file.rename(backup.path);
    } catch (_) {
      try {
        await file.delete();
      } catch (_) {
        // If the platform keeps the file locked, leave it in place and let the
        // next successful write replace it.
      }
    } finally {
      _forgetMessagesForFile(file);
    }
  }
}

class _CachedMessageFile {
  List<MailMessage>? messages;
  int lastAccess = 0;
}

class _DecodedCachedMessages {
  const _DecodedCachedMessages.loaded(this.messages) : shouldQuarantine = false;
  const _DecodedCachedMessages.unreadableEncrypted()
    : messages = const [],
      shouldQuarantine = false;
  const _DecodedCachedMessages.invalid()
    : messages = const [],
      shouldQuarantine = true;

  final List<MailMessage> messages;
  final bool shouldQuarantine;
}

Future<_DecodedCachedMessages> _decodeCachedMessages(
  String raw,
  String? secret,
) async {
  var plaintext = raw;
  if (secret != null) {
    final decrypted = await LocalCacheCipher(secret).tryDecryptText(raw);
    if (decrypted != null) {
      plaintext = decrypted;
    } else if (LocalCacheCipher.looksEncrypted(raw)) {
      return const _DecodedCachedMessages.unreadableEncrypted();
    }
  } else if (LocalCacheCipher.looksEncrypted(raw)) {
    return const _DecodedCachedMessages.unreadableEncrypted();
  }
  try {
    final decodedJson = jsonDecode(plaintext);
    if (decodedJson is! List) return const _DecodedCachedMessages.invalid();
    return _DecodedCachedMessages.loaded([
      for (final item in decodedJson)
        _messageFromJson((item as Map).cast<String, Object?>()),
    ]);
  } on FormatException {
    return const _DecodedCachedMessages.invalid();
  } on TypeError {
    return const _DecodedCachedMessages.invalid();
  } on ArgumentError {
    return const _DecodedCachedMessages.invalid();
  }
}

Future<String> _serializeCachedMessages(
  List<MailMessage> messages,
  String? secret,
) async {
  final plaintext = jsonEncode([
    for (final message in messages) _messageToJson(message),
  ]);
  if (secret == null) return plaintext;
  return LocalCacheCipher(secret).encryptText(plaintext);
}

Map<String, Object?> _messageToJson(MailMessage message) => {
  'id': message.id,
  'account_id': message.accountId,
  'from': message.from,
  'subject': message.subject,
  'preview': message.preview,
  'body': message.body,
  'html_body': message.htmlBody,
  'received_at': message.receivedAt.toUtc().toIso8601String(),
  'to': message.to,
  'cc': message.cc,
  'reply_to': message.replyTo,
  'mailbox': message.mailbox.name,
  'folder_path': message.folderPath,
  'folder_display_name': message.folderDisplayName,
  'read': message.read,
  'starred': message.starred,
  'has_attachments': message.hasAttachments,
  'body_loaded': message.bodyLoaded,
  'attachments': [
    for (final attachment in message.attachments)
      {
        'filename': attachment.filename,
        'content_type': attachment.contentType,
        'part_id': attachment.partId,
        'transfer_encoding': attachment.transferEncoding,
        if (attachment.size != null) 'size': attachment.size,
      },
  ],
};

MailMessage _messageFromJson(Map<String, Object?> json) => MailMessage(
  id: json['id'] as String? ?? '',
  accountId: json['account_id'] as String? ?? '',
  from: decodeMailHeader(json['from'] as String? ?? ''),
  subject: decodeMailHeader(json['subject'] as String? ?? ''),
  preview: json['preview'] as String? ?? '',
  body: json['body'] as String? ?? json['preview'] as String? ?? '',
  htmlBody: json['html_body'] as String? ?? '',
  receivedAt:
      DateTime.tryParse(json['received_at'] as String? ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  to: _stringList(json['to']),
  cc: _stringList(json['cc']),
  replyTo: _stringList(json['reply_to']),
  mailbox: _mailboxFromName(json['mailbox'] as String?),
  folderPath: json['folder_path'] as String? ?? '',
  folderDisplayName: json['folder_display_name'] as String? ?? '',
  read: json['read'] as bool? ?? false,
  starred: json['starred'] as bool? ?? false,
  hasAttachments: json['has_attachments'] as bool? ?? false,
  bodyLoaded: json['body_loaded'] as bool? ?? true,
  attachments:
      ((json['attachments'] as List?) ?? const []).map((item) {
        final data = (item as Map).cast<String, Object?>();
        return MailAttachment(
          filename: decodeMailHeader(
            data['filename'] as String? ?? 'attachment',
          ),
          contentType:
              data['content_type'] as String? ?? 'application/octet-stream',
          partId: data['part_id'] as String? ?? '',
          transferEncoding: data['transfer_encoding'] as String? ?? '',
          size: (data['size'] as num?)?.toInt(),
        );
      }).toList(),
);

MailMessage _normalizeCachedMessage(MailMessage message) {
  return message.copyWith(
    from: decodeMailHeader(message.from),
    subject: decodeMailHeader(message.subject),
    attachments: [
      for (final attachment in message.attachments)
        MailAttachment(
          filename: decodeMailHeader(attachment.filename),
          contentType: attachment.contentType,
          partId: attachment.partId,
          transferEncoding: attachment.transferEncoding,
          size: attachment.size,
        ),
    ],
  );
}

bool _sameCachedMessage(MailMessage first, MailMessage second) {
  return first.id == second.id &&
      first.accountId == second.accountId &&
      first.from == second.from &&
      first.subject == second.subject &&
      first.preview == second.preview &&
      first.body == second.body &&
      first.htmlBody == second.htmlBody &&
      first.receivedAt.isAtSameMomentAs(second.receivedAt) &&
      _sameStringList(first.to, second.to) &&
      _sameStringList(first.cc, second.cc) &&
      _sameStringList(first.replyTo, second.replyTo) &&
      first.mailbox == second.mailbox &&
      first.folderPath == second.folderPath &&
      first.folderDisplayName == second.folderDisplayName &&
      first.read == second.read &&
      first.starred == second.starred &&
      first.hasAttachments == second.hasAttachments &&
      first.bodyLoaded == second.bodyLoaded &&
      _sameAttachments(first.attachments, second.attachments);
}

bool _sameStringList(List<String> first, List<String> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

bool _sameAttachments(List<MailAttachment> first, List<MailAttachment> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    final left = first[index];
    final right = second[index];
    if (left.filename != right.filename ||
        left.contentType != right.contentType ||
        left.partId != right.partId ||
        left.transferEncoding != right.transferEncoding ||
        left.size != right.size) {
      return false;
    }
  }
  return true;
}

int _estimatedCachePayloadSize(Iterable<MailMessage> messages) {
  var size = 0;
  for (final message in messages) {
    size +=
        message.id.length +
        message.accountId.length +
        message.from.length +
        message.subject.length +
        message.preview.length +
        message.body.length +
        message.htmlBody.length +
        message.folderPath.length +
        message.folderDisplayName.length;
    for (final recipient in [
      ...message.to,
      ...message.cc,
      ...message.replyTo,
    ]) {
      size += recipient.length;
    }
    for (final attachment in message.attachments) {
      size +=
          attachment.filename.length +
          attachment.contentType.length +
          attachment.partId.length +
          attachment.transferEncoding.length;
    }
    if (size >= MailCache._backgroundCacheWorkThreshold) return size;
  }
  return size;
}

class _AsyncMutex {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        completer.complete();
      }
    });
  }
}

bool _isCacheFormatError(Object error) {
  return error is FormatException ||
      error is TypeError ||
      error is ArgumentError;
}

String mailCacheNamespaceForUser(String userId) {
  final normalized = userId.trim();
  if (normalized.isEmpty) return 'anonymous';
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'user-${digest.substring(0, 24)}';
}

String? _safeCacheNamespace(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}

List<String> _stringList(Object? value) {
  return ((value as List?) ?? const [])
      .whereType<String>()
      .where((item) => item.trim().isNotEmpty)
      .toList();
}

MailboxKind _mailboxFromName(String? value) {
  for (final kind in MailboxKind.values) {
    if (kind.name == value) return kind;
  }
  return MailboxKind.inbox;
}
