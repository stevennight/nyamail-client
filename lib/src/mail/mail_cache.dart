import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../security/local_cache_crypto.dart';
import 'mail_models.dart';
import 'mail_transport.dart';

/// Body payload for a single cached message.
///
/// Message bodies are stored separately from the list index so that opening a
/// mailbox never has to deserialize (or rewrite) every HTML body on disk.
class MailMessageBody {
  const MailMessageBody({required this.body, required this.htmlBody});

  final String body;
  final String htmlBody;

  bool get isEmpty => body.isEmpty && htmlBody.isEmpty;
}

abstract class MailMessageCache {
  Future<void> saveMessages(List<MailMessage> messages);

  /// Loads cached messages.
  ///
  /// When [includeBodies] is false the returned messages carry no body text and
  /// report `bodyLoaded == false`; callers fetch the body on demand through
  /// [loadBody]. Bodies are always merged when a [query] is supplied because the
  /// search matcher inspects body text.
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
    bool includeBodies = true,
  });

  /// Returns the stored body for [messageId].
  ///
  /// Returns `null` when the message is unknown or its body has never been
  /// fetched; returns an empty [MailMessageBody] when the body was fetched but
  /// genuinely carries no text.
  Future<MailMessageBody?> loadBody(String messageId);

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
    final indexFile = await _indexFile();
    final bodiesFile = await _bodiesFile();
    await _lockFor(indexFile).synchronized(() async {
      final loaded = await _loadFromFiles(indexFile, bodiesFile);
      final byId = {for (final message in loaded.messages) message.id: message};
      final bodies = Map<String, MailMessageBody>.of(loaded.bodies);
      var indexChanged = false;
      var bodiesChanged = false;
      for (final incoming in messages) {
        final normalized = _normalizeCachedMessage(incoming);
        final currentIndex = byId[normalized.id];
        final currentBody = bodies[normalized.id];
        final currentFull =
            currentIndex == null ? null : _mergeBody(currentIndex, currentBody);
        final nextFull =
            currentFull == null
                ? normalized
                : mailMessageUpdatePreservingLoadedBody(
                  current: currentFull,
                  update: normalized,
                );
        final nextIndex = _stripBody(nextFull);
        final nextBody = _bodyForStorage(nextFull);

        if (currentIndex == null ||
            !_sameIndexMessage(currentIndex, nextIndex)) {
          indexChanged = true;
        }
        if (!_sameBody(currentBody, nextBody)) {
          bodiesChanged = true;
        }
        byId[normalized.id] = nextIndex;
        if (nextBody == null) {
          bodies.remove(normalized.id);
        } else {
          bodies[normalized.id] = nextBody;
        }
      }
      if (!indexChanged && !bodiesChanged) return;
      await _writeCache(
        indexFile: indexFile,
        bodiesFile: bodiesFile,
        messages: byId.values,
        bodies: bodies,
        writeIndex: indexChanged,
        writeBodies: bodiesChanged,
      );
    });
  }

  @override
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
    bool includeBodies = true,
  }) async {
    final indexFile = await _indexFile();
    final bodiesFile = await _bodiesFile();
    return _lockFor(indexFile).synchronized(() async {
      final loaded = await _loadFromFiles(indexFile, bodiesFile);
      final normalizedQuery = query?.trim() ?? '';
      final mergeBodies = includeBodies || normalizedQuery.isNotEmpty;
      final scoped = <MailMessage>[];
      for (final message in loaded.messages) {
        if (mailbox != null && message.effectiveMailbox != mailbox) continue;
        if (accountId != null && message.accountId != accountId) continue;
        if (folderPath != null && message.effectiveFolderPath != folderPath) {
          continue;
        }
        scoped.add(
          mergeBodies
              ? _mergeBody(message, loaded.bodies[message.id])
              : (message.bodyLoaded
                  ? message.copyWith(bodyLoaded: false)
                  : message),
        );
      }
      if (normalizedQuery.isEmpty) return scoped;
      return scoped
          .where((message) => mailMessageMatchesQuery(message, normalizedQuery))
          .toList(growable: false);
    });
  }

  @override
  Future<MailMessageBody?> loadBody(String messageId) async {
    final indexFile = await _indexFile();
    final bodiesFile = await _bodiesFile();
    return _lockFor(indexFile).synchronized(() async {
      final loaded = await _loadFromFiles(indexFile, bodiesFile);
      MailMessage? indexMessage;
      for (final message in loaded.messages) {
        if (message.id == messageId) {
          indexMessage = message;
          break;
        }
      }
      if (indexMessage == null) return null;
      final stored = loaded.bodies[messageId];
      if (stored != null) return stored;
      return indexMessage.bodyLoaded
          ? const MailMessageBody(body: '', htmlBody: '')
          : null;
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
    final indexFile = await _indexFile();
    final bodiesFile = await _bodiesFile();
    await _lockFor(indexFile).synchronized(() async {
      final loaded = await _loadFromFiles(indexFile, bodiesFile);
      final remaining = loaded.messages
          .where((message) => !ids.contains(message.id))
          .toList(growable: false);
      if (remaining.length == loaded.messages.length) return;
      final bodies = Map<String, MailMessageBody>.of(loaded.bodies);
      final removedBody = ids.any(bodies.containsKey);
      bodies.removeWhere((id, _) => ids.contains(id));
      await _writeCache(
        indexFile: indexFile,
        bodiesFile: bodiesFile,
        messages: remaining,
        bodies: bodies,
        writeIndex: true,
        writeBodies: removedBody,
      );
    });
  }

  @override
  Future<void> clear() async {
    final indexFile = await _indexFile();
    final bodiesFile = await _bodiesFile();
    await _lockFor(indexFile).synchronized(() async {
      final namespace = _safeCacheNamespace(this.namespace);
      if (namespace == null) {
        for (final file in [indexFile, bodiesFile]) {
          if (await file.exists()) {
            await file.delete();
          }
        }
        _forgetMessagesForFile(indexFile);
        return;
      }
      final dir = indexFile.parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _forgetMessagesInDirectory(dir);
    });
  }

  Future<_LoadedCache> _loadFromFiles(File indexFile, File bodiesFile) async {
    final memory = _memoryFor(indexFile);
    final rememberedMessages = memory.messages;
    if (rememberedMessages != null) {
      return _LoadedCache(rememberedMessages, memory.bodies ?? const {});
    }
    if (!await indexFile.exists()) {
      return _rememberCache(indexFile, const [], const {});
    }
    try {
      final rawIndex = await indexFile.readAsString(encoding: utf8);
      final secret = _normalizedLocalCacheSecret;
      final decodedIndex =
          rawIndex.length >= _backgroundCacheWorkThreshold
              ? await Isolate.run(() => _decodeIndex(rawIndex, secret))
              : await _decodeIndex(rawIndex, secret);
      if (decodedIndex.shouldQuarantine) {
        await _quarantineUnreadableCache(indexFile);
        await _quarantineUnreadableCache(bodiesFile);
        return _rememberCache(indexFile, const [], const {});
      }

      final bodiesFileExisted = await bodiesFile.exists();
      var bodies = <String, MailMessageBody>{};
      var writeBodies = false;
      var writeIndex = false;
      if (bodiesFileExisted) {
        final rawBodies = await bodiesFile.readAsString(encoding: utf8);
        final decodedBodies =
            rawBodies.length >= _backgroundCacheWorkThreshold
                ? await Isolate.run(() => _decodeBodies(rawBodies, secret))
                : await _decodeBodies(rawBodies, secret);
        if (decodedBodies.shouldQuarantine) {
          await _quarantineUnreadableCache(bodiesFile);
        } else {
          bodies = decodedBodies.bodies;
        }
        // Legacy body columns lingering in an already-split index: drop them.
        if (decodedIndex.inlineBodies.isNotEmpty) {
          writeIndex = true;
        }
      } else if (decodedIndex.inlineBodies.isNotEmpty) {
        // First run after the split: migrate bodies out of messages.json.
        bodies = decodedIndex.inlineBodies;
        writeIndex = true;
        writeBodies = true;
      }

      final remembered = _rememberCache(
        indexFile,
        decodedIndex.messages,
        bodies,
      );
      if (writeIndex || writeBodies) {
        await _writeCache(
          indexFile: indexFile,
          bodiesFile: bodiesFile,
          messages: remembered.messages,
          bodies: bodies,
          writeIndex: writeIndex,
          writeBodies: writeBodies,
        );
      }
      return remembered;
    } catch (error) {
      if (_isCacheFormatError(error)) {
        await _quarantineUnreadableCache(indexFile);
        await _quarantineUnreadableCache(bodiesFile);
        return _rememberCache(indexFile, const [], const {});
      }
      rethrow;
    }
  }

  Future<File> _indexFile() async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    final namespace = _safeCacheNamespace(this.namespace);
    if (namespace == null) {
      return File('${dir.path}/mail-cache/messages.json');
    }
    return File('${dir.path}/mail-cache/$namespace/messages.json');
  }

  Future<File> _bodiesFile() async {
    final indexFile = await _indexFile();
    return File('${indexFile.parent.path}/bodies.json');
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

  _LoadedCache _rememberCache(
    File file,
    Iterable<MailMessage> messages,
    Map<String, MailMessageBody> bodies,
  ) {
    final remembered = List<MailMessage>.unmodifiable(
      messages.map((message) => _normalizeCachedMessage(_stripBody(message))),
    );
    final rememberedBodies = Map<String, MailMessageBody>.unmodifiable(bodies);
    final memory =
        _memoryFor(file)
          ..messages = remembered
          ..bodies = rememberedBodies;
    return _LoadedCache(memory.messages!, memory.bodies!);
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

  Future<void> _writeCache({
    required File indexFile,
    required File bodiesFile,
    required Iterable<MailMessage> messages,
    required Map<String, MailMessageBody> bodies,
    required bool writeIndex,
    required bool writeBodies,
  }) async {
    final snapshot = List<MailMessage>.of(messages.map(_stripBody))
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    final secret = _normalizedLocalCacheSecret;

    if (writeIndex) {
      final output =
          _estimatedIndexPayloadSize(snapshot) >= _backgroundCacheWorkThreshold
              ? await Isolate.run(() => _serializeIndex(snapshot, secret))
              : await _serializeIndex(snapshot, secret);
      await _writeFileAtomically(indexFile, output);
    }
    if (writeBodies) {
      if (bodies.isEmpty) {
        if (await bodiesFile.exists()) {
          await bodiesFile.delete();
        }
      } else {
        final payload = Map<String, MailMessageBody>.of(bodies);
        final output =
            _estimatedBodiesPayloadSize(payload) >=
                    _backgroundCacheWorkThreshold
                ? await Isolate.run(() => _serializeBodies(payload, secret))
                : await _serializeBodies(payload, secret);
        await _writeFileAtomically(bodiesFile, output);
      }
    }

    _memoryFor(indexFile)
      ..messages = List<MailMessage>.unmodifiable(
        snapshot.map(_normalizeCachedMessage),
      )
      ..bodies = Map<String, MailMessageBody>.unmodifiable(bodies);
  }

  Future<void> _writeFileAtomically(File file, String output) async {
    await file.parent.create(recursive: true);
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

MailMessage _mergeBody(MailMessage indexMessage, MailMessageBody? body) {
  if (body == null) return indexMessage;
  return indexMessage.copyWith(
    body: body.body,
    htmlBody: body.htmlBody,
    bodyLoaded: true,
  );
}

MailMessage _stripBody(MailMessage message) {
  if (message.body.isEmpty && message.htmlBody.isEmpty) return message;
  return message.copyWith(body: '', htmlBody: '');
}

MailMessageBody? _bodyForStorage(MailMessage message) {
  if (!message.bodyLoaded) return null;
  if (message.body.isEmpty && message.htmlBody.isEmpty) return null;
  return MailMessageBody(body: message.body, htmlBody: message.htmlBody);
}

bool _sameBody(MailMessageBody? first, MailMessageBody? second) {
  if (identical(first, second)) return true;
  if (first == null || second == null) return false;
  return first.body == second.body && first.htmlBody == second.htmlBody;
}

class _CachedMessageFile {
  List<MailMessage>? messages;
  Map<String, MailMessageBody>? bodies;
  int lastAccess = 0;
}

class _LoadedCache {
  const _LoadedCache(this.messages, this.bodies);

  final List<MailMessage> messages;
  final Map<String, MailMessageBody> bodies;
}

class _DecodedIndex {
  const _DecodedIndex.loaded(this.messages, this.inlineBodies)
    : shouldQuarantine = false;
  const _DecodedIndex.unreadableEncrypted()
    : messages = const [],
      inlineBodies = const {},
      shouldQuarantine = false;
  const _DecodedIndex.invalid()
    : messages = const [],
      inlineBodies = const {},
      shouldQuarantine = true;

  final List<MailMessage> messages;
  final Map<String, MailMessageBody> inlineBodies;
  final bool shouldQuarantine;
}

class _DecodedBodies {
  const _DecodedBodies.loaded(this.bodies) : shouldQuarantine = false;
  const _DecodedBodies.unreadableEncrypted()
    : bodies = const {},
      shouldQuarantine = false;
  const _DecodedBodies.invalid() : bodies = const {}, shouldQuarantine = true;

  final Map<String, MailMessageBody> bodies;
  final bool shouldQuarantine;
}

Future<_DecodedIndex> _decodeIndex(String raw, String? secret) async {
  var plaintext = raw;
  if (secret != null) {
    final decrypted = await LocalCacheCipher(secret).tryDecryptText(raw);
    if (decrypted != null) {
      plaintext = decrypted;
    } else if (LocalCacheCipher.looksEncrypted(raw)) {
      return const _DecodedIndex.unreadableEncrypted();
    }
  } else if (LocalCacheCipher.looksEncrypted(raw)) {
    return const _DecodedIndex.unreadableEncrypted();
  }
  try {
    final decodedJson = jsonDecode(plaintext);
    if (decodedJson is! List) return const _DecodedIndex.invalid();
    final messages = <MailMessage>[];
    final inlineBodies = <String, MailMessageBody>{};
    for (final item in decodedJson) {
      final map = (item as Map).cast<String, Object?>();
      final message = _messageFromJson(map);
      messages.add(_stripBody(message));
      final rawBody = map['body'] as String? ?? '';
      final rawHtml = map['html_body'] as String? ?? '';
      final bodyLoaded = map['body_loaded'] as bool? ?? true;
      if (bodyLoaded && (rawBody.isNotEmpty || rawHtml.isNotEmpty)) {
        inlineBodies[message.id] = MailMessageBody(
          body: rawBody,
          htmlBody: rawHtml,
        );
      }
    }
    return _DecodedIndex.loaded(messages, inlineBodies);
  } on FormatException {
    return const _DecodedIndex.invalid();
  } on TypeError {
    return const _DecodedIndex.invalid();
  } on ArgumentError {
    return const _DecodedIndex.invalid();
  }
}

Future<_DecodedBodies> _decodeBodies(String raw, String? secret) async {
  var plaintext = raw;
  if (secret != null) {
    final decrypted = await LocalCacheCipher(secret).tryDecryptText(raw);
    if (decrypted != null) {
      plaintext = decrypted;
    } else if (LocalCacheCipher.looksEncrypted(raw)) {
      return const _DecodedBodies.unreadableEncrypted();
    }
  } else if (LocalCacheCipher.looksEncrypted(raw)) {
    return const _DecodedBodies.unreadableEncrypted();
  }
  try {
    final decodedJson = jsonDecode(plaintext);
    if (decodedJson is! Map) return const _DecodedBodies.invalid();
    final bodies = <String, MailMessageBody>{};
    decodedJson.forEach((key, value) {
      final map = (value as Map).cast<String, Object?>();
      bodies[key as String] = MailMessageBody(
        body: map['body'] as String? ?? '',
        htmlBody: map['html_body'] as String? ?? '',
      );
    });
    return _DecodedBodies.loaded(bodies);
  } on FormatException {
    return const _DecodedBodies.invalid();
  } on TypeError {
    return const _DecodedBodies.invalid();
  } on ArgumentError {
    return const _DecodedBodies.invalid();
  }
}

Future<String> _serializeIndex(
  List<MailMessage> messages,
  String? secret,
) async {
  final plaintext = jsonEncode([
    for (final message in messages) _indexToJson(message),
  ]);
  if (secret == null) return plaintext;
  return LocalCacheCipher(secret).encryptText(plaintext);
}

Future<String> _serializeBodies(
  Map<String, MailMessageBody> bodies,
  String? secret,
) async {
  final plaintext = jsonEncode({
    for (final entry in bodies.entries)
      entry.key: {'body': entry.value.body, 'html_body': entry.value.htmlBody},
  });
  if (secret == null) return plaintext;
  return LocalCacheCipher(secret).encryptText(plaintext);
}

Map<String, Object?> _indexToJson(MailMessage message) => {
  'id': message.id,
  'account_id': message.accountId,
  'from': message.from,
  'subject': message.subject,
  'preview': message.preview,
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
  'message_id_header': message.messageIdHeader,
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
  messageIdHeader: json['message_id_header'] as String? ?? '',
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

bool _sameIndexMessage(MailMessage first, MailMessage second) {
  return first.id == second.id &&
      first.accountId == second.accountId &&
      first.from == second.from &&
      first.subject == second.subject &&
      first.preview == second.preview &&
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
      first.messageIdHeader == second.messageIdHeader &&
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

int _estimatedIndexPayloadSize(Iterable<MailMessage> messages) {
  var size = 0;
  for (final message in messages) {
    size +=
        message.id.length +
        message.accountId.length +
        message.from.length +
        message.subject.length +
        message.preview.length +
        message.folderPath.length +
        message.folderDisplayName.length +
        message.messageIdHeader.length;
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

int _estimatedBodiesPayloadSize(Map<String, MailMessageBody> bodies) {
  var size = 0;
  for (final entry in bodies.entries) {
    size +=
        entry.key.length +
        entry.value.body.length +
        entry.value.htmlBody.length;
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
