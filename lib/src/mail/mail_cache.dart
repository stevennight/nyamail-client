import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  @override
  Future<void> saveMessages(List<MailMessage> messages) async {
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final existing = await _loadMessagesFromFile(file);
      final byId = {for (final message in existing) message.id: message};
      var changed = false;
      for (final message in messages) {
        final current = byId[message.id];
        final next =
            current != null && current.bodyLoaded && !message.bodyLoaded
                ? message.copyWith(
                  body: current.body,
                  htmlBody: current.htmlBody,
                  hasAttachments: current.hasAttachments,
                  attachments: current.attachments,
                  bodyLoaded: true,
                )
                : message;
        if (current == null || !_sameCachedMessage(current, next)) {
          changed = true;
        }
        byId[message.id] = next;
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
      final scoped =
          decoded.where((message) {
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
          }).toList();
      if (query == null || query.trim().isEmpty) return scoped;
      return scoped
          .where((message) => mailMessageMatchesQuery(message, query))
          .toList();
    });
  }

  Future<List<MailMessage>> _loadMessagesFromFile(File file) async {
    if (!await file.exists()) return const [];
    try {
      final raw = await _readCacheText(file);
      if (raw == null) return const [];
      final decodedJson = jsonDecode(raw);
      if (decodedJson is! List) {
        await _quarantineUnreadableCache(file);
        return const [];
      }
      final decoded =
          decodedJson
              .map(
                (item) =>
                    _messageFromJson((item as Map).cast<String, Object?>()),
              )
              .toList();
      return decoded;
    } catch (error) {
      if (_isCacheFormatError(error)) {
        await _quarantineUnreadableCache(file);
        return const [];
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
        return;
      }
      final dir = file.parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
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
    'attachments':
        message.attachments
            .map(
              (attachment) => {
                'filename': attachment.filename,
                'content_type': attachment.contentType,
                'part_id': attachment.partId,
                'transfer_encoding': attachment.transferEncoding,
                if (attachment.size != null) 'size': attachment.size,
              },
            )
            .toList(),
  };

  bool _sameCachedMessage(MailMessage first, MailMessage second) {
    return jsonEncode(_messageToJson(first)) ==
        jsonEncode(_messageToJson(second));
  }

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

  @override
  Future<void> updateMessage(MailMessage message) async {
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final existing = await _loadMessagesFromFile(file);
      await _writeMessagesToFile(file, [
        for (final item in existing)
          if (item.id == message.id) message else item,
        if (!existing.any((item) => item.id == message.id)) message,
      ]);
    });
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    final file = await _cacheFile();
    await _lockFor(file).synchronized(() async {
      final remaining =
          (await _loadMessagesFromFile(file))
              .where((message) => message.id != messageId)
              .toList(growable: false);
      await _writeMessagesToFile(file, remaining);
    });
  }

  _AsyncMutex _lockFor(File file) {
    return _locks.putIfAbsent(file.path, _AsyncMutex.new);
  }

  Future<void> _writeMessagesToFile(
    File file,
    Iterable<MailMessage> messages,
  ) async {
    final encoded =
        messages.map(_messageToJson).toList()..sort(
          (a, b) => (b['received_at'] as String).compareTo(
            a['received_at'] as String,
          ),
        );
    await file.parent.create(recursive: true);
    await _writeCacheText(file, jsonEncode(encoded));
  }

  LocalCacheCipher? get _localCacheCipher {
    final secret = localCacheSecret?.trim();
    if (secret == null || secret.isEmpty) return null;
    return LocalCacheCipher(secret);
  }

  Future<String?> _readCacheText(File file) async {
    final raw = await file.readAsString(encoding: utf8);
    final cipher = _localCacheCipher;
    if (cipher != null) {
      final decrypted = await cipher.tryDecryptText(raw);
      if (decrypted != null) return decrypted;
    }
    if (LocalCacheCipher.looksEncrypted(raw)) return null;
    return raw;
  }

  Future<void> _quarantineUnreadableCache(File file) async {
    if (!await file.exists()) return;
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
    }
  }

  Future<void> _writeCacheText(File file, String plaintext) async {
    final cipher = _localCacheCipher;
    final output =
        cipher == null ? plaintext : await cipher.encryptText(plaintext);
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
  }
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
