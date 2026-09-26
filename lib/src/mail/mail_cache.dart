import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

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

/// Local message cache backed by one SQLite database per user namespace.
///
/// Every message is one row, so saving a page of previews or a flag change
/// writes only those rows instead of re-serializing the whole mailbox the way
/// the former JSON files did. Row contents stay encrypted with the local cache
/// secret and row keys are keyed hashes of the message ids, so the database
/// reveals no more than the encrypted JSON files did. The decrypted list index
/// is kept in memory; bodies are read (and decrypted) one at a time.
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
  static final Map<String, _SqliteMailStore> _stores =
      <String, _SqliteMailStore>{};

  /// Rows whose index or body column was written; for tests only.
  static int debugIndexWrites = 0;
  static int debugBodyWrites = 0;

  /// Closes every open cache database. The app keeps them open for its whole
  /// lifetime; tests call this before deleting their temporary directories.
  static Future<void> closeAll() async {
    for (final entry in _stores.entries.toList()) {
      await _lockForPath(entry.key).synchronized(() async {
        _stores.remove(entry.key)?.close();
      });
    }
  }

  @override
  Future<void> saveMessages(List<MailMessage> messages) async {
    if (messages.isEmpty) return;
    await _withStore((store) => store.save(messages));
  }

  @override
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
    bool includeBodies = true,
  }) {
    return _withStore((store) async {
      final normalizedQuery = query?.trim() ?? '';
      final mergeBodies = includeBodies || normalizedQuery.isNotEmpty;
      final scoped = <MailMessage>[];
      for (final message in store.sortedMessages) {
        if (mailbox != null && message.effectiveMailbox != mailbox) continue;
        if (accountId != null && message.accountId != accountId) continue;
        if (folderPath != null && message.effectiveFolderPath != folderPath) {
          continue;
        }
        scoped.add(message);
      }
      if (!mergeBodies) {
        return [
          for (final message in scoped)
            message.bodyLoaded ? message.copyWith(bodyLoaded: false) : message,
        ];
      }
      final bodies = await store.bodiesFor(scoped);
      final merged = [
        for (final message in scoped) _mergeBody(message, bodies[message.id]),
      ];
      if (normalizedQuery.isEmpty) return merged;
      return merged
          .where((message) => mailMessageMatchesQuery(message, normalizedQuery))
          .toList(growable: false);
    });
  }

  @override
  Future<MailMessageBody?> loadBody(String messageId) {
    return _withStore((store) => store.loadBody(messageId));
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
    await _withStore((store) async => store.delete(ids));
  }

  @override
  Future<void> clear() async {
    final directory = await _cacheDirectory();
    final prefix = _normalizedDirectoryPath(directory);
    // Close every database of this directory (any secret) before deleting.
    for (final path in _stores.keys.toList()) {
      if (_normalizedDirectoryPath(File(path).parent) != prefix) continue;
      await _lockForPath(path).synchronized(() async {
        _stores.remove(path)?.close();
      });
    }
    if (_safeCacheNamespace(namespace) != null) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    }
    // The root cache directory also holds every user namespace; only remove
    // the files that belong to the anonymous cache.
    if (!await directory.exists()) return;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('mail-') && name.contains('.sqlite') ||
          name == 'messages.json' ||
          name == 'bodies.json') {
        await entity.delete();
      }
    }
  }

  Future<T> _withStore<T>(
    FutureOr<T> Function(_SqliteMailStore store) action,
  ) async {
    final directory = await _cacheDirectory();
    final secret = _normalizedLocalCacheSecret;
    final file = _databaseFile(directory, secret);
    return _lockForPath(file.path).synchronized(() async {
      final store =
          _stores[file.path] ??= await _SqliteMailStore.open(
            directory: directory,
            file: file,
            secret: secret,
          );
      return action(store);
    });
  }

  Future<Directory> _cacheDirectory() async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    final namespace = _safeCacheNamespace(this.namespace);
    if (namespace == null) return Directory('${dir.path}/mail-cache');
    return Directory('${dir.path}/mail-cache/$namespace');
  }

  /// One database per cache secret: opening the cache with a different (or
  /// no) secret sees an empty cache instead of destroying the real one.
  static File _databaseFile(Directory directory, String? secret) {
    final name =
        secret == null ? 'plain' : _secretFingerprint(secret).substring(0, 16);
    return File('${directory.path}/mail-$name.sqlite');
  }

  static String _normalizedDirectoryPath(Directory directory) {
    return directory.path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  }

  static _AsyncMutex _lockForPath(String path) {
    return _locks.putIfAbsent(path, _AsyncMutex.new);
  }

  String? get _normalizedLocalCacheSecret {
    final secret = localCacheSecret?.trim();
    return secret == null || secret.isEmpty ? null : secret;
  }
}

/// One open cache database plus the decrypted list index it serves.
class _SqliteMailStore {
  _SqliteMailStore._(this._db, this.secret);

  static const _schemaVersion = 1;
  static const _backgroundCryptoThreshold = 24;
  static const _selectChunk = 400;

  final Database _db;
  final String? secret;
  final Map<String, MailMessage> _index = <String, MailMessage>{};

  /// Decrypted bodies, filled on first search and kept in step with writes so
  /// repeated searches do not decrypt every body again.
  Map<String, MailMessageBody>? _searchBodies;
  List<MailMessage>? _sorted;
  late final Hmac? _rowKeyMac =
      secret == null
          ? null
          : Hmac(
            sha256,
            utf8.encode('nyamail-local-cache-row-v1\u0000${secret!}'),
          );

  static Future<_SqliteMailStore> open({
    required Directory directory,
    required File file,
    required String? secret,
  }) async {
    await directory.create(recursive: true);
    final db = sqlite3.open(file.path);
    final store = _SqliteMailStore._(db, secret);
    try {
      store._migrateSchema();
      await store._importLegacyFiles(directory);
      await store._loadIndex();
    } catch (_) {
      db.close();
      rethrow;
    }
    return store;
  }

  void close() => _db.close();

  List<MailMessage> get sortedMessages {
    return _sorted ??= List<MailMessage>.unmodifiable(
      _index.values.toList()
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt)),
    );
  }

  Future<void> save(List<MailMessage> messages) async {
    final indexWrites = <String, MailMessage>{};
    final bodyWrites = <String, MailMessageBody?>{};
    final loadedUpdates = <MailMessage>[];
    for (final incoming in messages) {
      final normalized = _normalizeCachedMessage(incoming);
      final current = _index[normalized.id];
      final keepsStoredBody =
          current != null &&
          current.id == normalized.id &&
          current.bodyLoaded &&
          !normalized.bodyLoaded;
      final next =
          keepsStoredBody
              ? _stripBody(
                normalized.copyWith(
                  hasAttachments: current.hasAttachments,
                  attachments: current.attachments,
                  bodyLoaded: true,
                ),
              )
              : _stripBody(normalized);
      final indexChanged = current == null || !_sameIndexMessage(current, next);
      if (keepsStoredBody) {
        if (indexChanged) indexWrites[next.id] = next;
        continue;
      }
      if (normalized.bodyLoaded) loadedUpdates.add(normalized);
      final body = _bodyForStorage(normalized);
      if (indexChanged) indexWrites[next.id] = next;
      if (!normalized.bodyLoaded) {
        // Preview-only: nothing is stored for the body.
        if (current?.bodyLoaded ?? false) bodyWrites[next.id] = null;
        continue;
      }
      bodyWrites[next.id] = body;
    }

    // A freshly fetched body often equals the stored one (reopening a
    // message); skip those writes.
    if (loadedUpdates.isNotEmpty) {
      final stored = await _readBodies([
        for (final message in loadedUpdates)
          if (_index[message.id]?.bodyLoaded ?? false) message.id,
      ]);
      for (final message in loadedUpdates) {
        final wanted = bodyWrites[message.id];
        if (_index[message.id]?.bodyLoaded == true &&
            _sameBody(stored[message.id], wanted)) {
          bodyWrites.remove(message.id);
        }
      }
    }
    if (indexWrites.isEmpty && bodyWrites.isEmpty) return;

    final rows = <_PlainRow>[
      for (final id in {...indexWrites.keys, ...bodyWrites.keys})
        _PlainRow(
          key: _rowKey(id),
          meta:
              indexWrites.containsKey(id)
                  ? jsonEncode(_indexToJson(indexWrites[id]!))
                  : null,
          writesBody: bodyWrites.containsKey(id),
          body: switch (bodyWrites[id]) {
            final body? => jsonEncode({
              'body': body.body,
              'html_body': body.htmlBody,
            }),
            null => null,
          },
        ),
    ];
    final encrypted = await _encryptRows(rows);

    _db.execute('BEGIN');
    try {
      for (final row in encrypted) {
        if (row.meta != null && row.writesBody) {
          _db.execute(
            'INSERT INTO messages (key, meta, body) VALUES (?, ?, ?) '
            'ON CONFLICT(key) DO UPDATE SET meta = excluded.meta, '
            'body = excluded.body',
            [row.key, row.meta, row.body],
          );
        } else if (row.meta != null) {
          _db.execute(
            'INSERT INTO messages (key, meta) VALUES (?, ?) '
            'ON CONFLICT(key) DO UPDATE SET meta = excluded.meta',
            [row.key, row.meta],
          );
        } else {
          _db.execute('UPDATE messages SET body = ? WHERE key = ?', [
            row.body,
            row.key,
          ]);
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    MailCache.debugIndexWrites += indexWrites.length;
    MailCache.debugBodyWrites += bodyWrites.length;

    _index.addAll(indexWrites);
    _sorted = null;
    final searchBodies = _searchBodies;
    if (searchBodies != null) {
      bodyWrites.forEach((id, body) {
        if (body == null) {
          searchBodies.remove(id);
        } else {
          searchBodies[id] = body;
        }
      });
    }
  }

  void delete(Set<String> ids) {
    final present = ids.where(_index.containsKey).toList(growable: false);
    if (present.isEmpty) return;
    _db.execute('BEGIN');
    try {
      final statement = _db.prepare('DELETE FROM messages WHERE key = ?');
      try {
        for (final id in present) {
          statement.execute([_rowKey(id)]);
        }
      } finally {
        statement.close();
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    for (final id in present) {
      _index.remove(id);
      _searchBodies?.remove(id);
    }
    _sorted = null;
  }

  Future<MailMessageBody?> loadBody(String messageId) async {
    final indexMessage = _index[messageId];
    if (indexMessage == null) return null;
    final stored =
        _searchBodies?[messageId] ??
        (await _readBodies([messageId]))[messageId];
    if (stored != null) return stored;
    return indexMessage.bodyLoaded
        ? const MailMessageBody(body: '', htmlBody: '')
        : null;
  }

  /// Bodies for [messages] that have one, from the search cache when warm.
  Future<Map<String, MailMessageBody>> bodiesFor(
    List<MailMessage> messages,
  ) async {
    final withBodies = [
      for (final message in messages)
        if (message.bodyLoaded) message.id,
    ];
    final cached = _searchBodies ??= <String, MailMessageBody>{};
    final missing = withBodies.where((id) => !cached.containsKey(id)).toList();
    if (missing.isNotEmpty) cached.addAll(await _readBodies(missing));
    return {
      for (final id in withBodies)
        if (cached[id] case final body?) id: body,
    };
  }

  Future<Map<String, MailMessageBody>> _readBodies(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final idByKey = {for (final id in ids) _rowKey(id): id};
    final keys = idByKey.keys.toList(growable: false);
    final encrypted = <String, String>{};
    for (var start = 0; start < keys.length; start += _selectChunk) {
      final chunk = keys.sublist(
        start,
        start + _selectChunk > keys.length ? keys.length : start + _selectChunk,
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = _db.select(
        'SELECT key, body FROM messages '
        'WHERE body IS NOT NULL AND key IN ($placeholders)',
        chunk,
      );
      for (final row in rows) {
        encrypted[idByKey[row['key'] as String]!] = row['body'] as String;
      }
    }
    if (encrypted.isEmpty) return const {};
    final secret = this.secret;
    final decoded =
        encrypted.length >= _backgroundCryptoThreshold
            ? await Isolate.run(() => _decodeBodyRows(encrypted, secret))
            : await _decodeBodyRows(encrypted, secret);
    return decoded;
  }

  Future<List<_PlainRow>> _encryptRows(List<_PlainRow> rows) {
    final secret = this.secret;
    if (secret == null) return Future.value(rows);
    if (rows.length >= _backgroundCryptoThreshold) {
      return Isolate.run(() => _encryptPlainRows(rows, secret));
    }
    return _encryptPlainRows(rows, secret);
  }

  String _rowKey(String id) {
    final mac = _rowKeyMac;
    if (mac == null) return id;
    return mac.convert(utf8.encode(id)).toString();
  }

  void _migrateSchema() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    final version =
        _db.select('PRAGMA user_version').single.columnAt(0) as int? ?? 0;
    if (version >= _schemaVersion) return;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        key TEXT PRIMARY KEY NOT NULL,
        meta TEXT NOT NULL,
        body TEXT
      ) WITHOUT ROWID
    ''');
    _db.execute('PRAGMA user_version = $_schemaVersion');
  }

  /// One-time import of the former `messages.json` / `bodies.json` files.
  Future<void> _importLegacyFiles(Directory directory) async {
    final indexFile = File('${directory.path}/messages.json');
    final bodiesFile = File('${directory.path}/bodies.json');
    if (!await indexFile.exists()) {
      if (await bodiesFile.exists()) await bodiesFile.delete();
      return;
    }
    final secret = this.secret;
    final rawIndex = await indexFile.readAsString(encoding: utf8);
    final rawBodies =
        await bodiesFile.exists()
            ? await bodiesFile.readAsString(encoding: utf8)
            : null;
    final legacy = await Isolate.run(
      () => _legacyRows(rawIndex, rawBodies, secret),
    );
    if (legacy.corrupt) {
      await _deleteQuietly(indexFile);
      await _deleteQuietly(bodiesFile);
      return;
    }
    final rows = legacy.rows;
    // Encrypted with a secret this cache does not have: leave the files for
    // the cache that does.
    if (rows == null) return;
    final keyed = [
      for (final row in rows)
        _PlainRow(
          key: _rowKey(row.key),
          meta: row.meta,
          body: row.body,
          writesBody: true,
        ),
    ];
    final encrypted = await _encryptRows(keyed);
    _db.execute('BEGIN');
    try {
      final statement = _db.prepare(
        'INSERT OR REPLACE INTO messages (key, meta, body) VALUES (?, ?, ?)',
      );
      try {
        for (final row in encrypted) {
          statement.execute([row.key, row.meta, row.body]);
        }
      } finally {
        statement.close();
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    await _deleteQuietly(indexFile);
    await _deleteQuietly(bodiesFile);
  }

  Future<void> _loadIndex() async {
    final metas = [
      for (final row in _db.select('SELECT meta FROM messages'))
        row['meta'] as String,
    ];
    if (metas.isEmpty) return;
    final secret = this.secret;
    final messages =
        metas.length >= _backgroundCryptoThreshold
            ? await Isolate.run(() => _decodeIndexRows(metas, secret))
            : await _decodeIndexRows(metas, secret);
    for (final message in messages) {
      _index[message.id] = message;
    }
  }
}

class _PlainRow {
  const _PlainRow({
    required this.key,
    required this.meta,
    required this.body,
    required this.writesBody,
  });

  final String key;

  /// Index JSON to store, or null to leave the stored index alone.
  final String? meta;

  /// Body JSON; null clears the body when [writesBody] is set.
  final String? body;
  final bool writesBody;
}

Future<List<_PlainRow>> _encryptPlainRows(
  List<_PlainRow> rows,
  String secret,
) async {
  final cipher = LocalCacheCipher(secret);
  return [
    for (final row in rows)
      _PlainRow(
        key: row.key,
        meta: row.meta == null ? null : await cipher.encryptText(row.meta!),
        body: row.body == null ? null : await cipher.encryptText(row.body!),
        writesBody: row.writesBody,
      ),
  ];
}

Future<String?> _decryptRowText(String raw, String? secret) async {
  if (secret == null) {
    return LocalCacheCipher.looksEncrypted(raw) ? null : raw;
  }
  return LocalCacheCipher(secret).tryDecryptText(raw);
}

Future<List<MailMessage>> _decodeIndexRows(
  List<String> metas,
  String? secret,
) async {
  final messages = <MailMessage>[];
  for (final raw in metas) {
    final plaintext = await _decryptRowText(raw, secret);
    if (plaintext == null) continue;
    try {
      final map = (jsonDecode(plaintext) as Map).cast<String, Object?>();
      messages.add(_normalizeCachedMessage(_stripBody(_messageFromJson(map))));
    } catch (error) {
      if (!_isCacheFormatError(error)) rethrow;
    }
  }
  return messages;
}

Future<Map<String, MailMessageBody>> _decodeBodyRows(
  Map<String, String> rows,
  String? secret,
) async {
  final bodies = <String, MailMessageBody>{};
  for (final entry in rows.entries) {
    final plaintext = await _decryptRowText(entry.value, secret);
    if (plaintext == null) continue;
    try {
      final map = (jsonDecode(plaintext) as Map).cast<String, Object?>();
      bodies[entry.key] = MailMessageBody(
        body: map['body'] as String? ?? '',
        htmlBody: map['html_body'] as String? ?? '',
      );
    } catch (error) {
      if (!_isCacheFormatError(error)) rethrow;
    }
  }
  return bodies;
}

/// Decodes the legacy JSON cache into plaintext rows keyed by message id.
/// `rows` is null when the files are encrypted with another secret.
Future<({List<_PlainRow>? rows, bool corrupt})> _legacyRows(
  String rawIndex,
  String? rawBodies,
  String? secret,
) async {
  final index = await _decodeIndex(rawIndex, secret);
  if (index.shouldQuarantine) return (rows: null, corrupt: true);
  if (index.unreadable) return (rows: null, corrupt: false);
  final bodies = Map<String, MailMessageBody>.of(index.inlineBodies);
  if (rawBodies != null) {
    final decoded = await _decodeBodies(rawBodies, secret);
    bodies.addAll(decoded.bodies);
  }
  final rows = [
    for (final message in index.messages)
      _PlainRow(
        key: message.id,
        meta: jsonEncode(
          _indexToJson(
            bodies.containsKey(message.id)
                ? message.copyWith(bodyLoaded: true)
                : message,
          ),
        ),
        body: switch (bodies[message.id]) {
          final body? when !body.isEmpty => jsonEncode({
            'body': body.body,
            'html_body': body.htmlBody,
          }),
          _ => null,
        },
        writesBody: true,
      ),
  ];
  return (rows: rows, corrupt: false);
}

String _secretFingerprint(String? secret) {
  if (secret == null) return 'plaintext';
  return sha256
      .convert(utf8.encode('nyamail-local-cache-fingerprint-v1\u0000$secret'))
      .toString();
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A locked legacy file is harmless; the import only runs while it exists
    // and replaces rows idempotently.
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

// Decoders for the former JSON cache files, kept for the one-time import.

class _DecodedIndex {
  const _DecodedIndex.loaded(this.messages, this.inlineBodies)
    : shouldQuarantine = false,
      unreadable = false;
  const _DecodedIndex.unreadableEncrypted()
    : messages = const [],
      inlineBodies = const {},
      shouldQuarantine = false,
      unreadable = true;
  const _DecodedIndex.invalid()
    : messages = const [],
      inlineBodies = const {},
      shouldQuarantine = true,
      unreadable = false;

  final List<MailMessage> messages;
  final Map<String, MailMessageBody> inlineBodies;
  final bool shouldQuarantine;

  /// Encrypted with a secret other than the one used to decode it.
  final bool unreadable;
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
