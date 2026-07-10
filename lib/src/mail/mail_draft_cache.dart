import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../security/local_cache_crypto.dart';

class MailDraft {
  const MailDraft({
    required this.accountId,
    this.to = '',
    this.cc = '',
    this.bcc = '',
    this.subject = '',
    this.body = '',
    this.htmlBody = '',
    this.attachments = const [],
    required this.updatedAt,
  });

  factory MailDraft.fromJson(Map<String, Object?> json) {
    final rawAttachments = json['attachments'];
    return MailDraft(
      accountId: json['account_id'] as String? ?? '',
      to: json['to'] as String? ?? '',
      cc: json['cc'] as String? ?? '',
      bcc: json['bcc'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
      htmlBody: json['html_body'] as String? ?? '',
      attachments:
          rawAttachments is List
              ? [
                for (final item in rawAttachments)
                  if (item is Map)
                    MailDraftAttachment.fromJson(item.cast<String, Object?>()),
              ]
              : const [],
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  final String accountId;
  final String to;
  final String cc;
  final String bcc;
  final String subject;
  final String body;
  final String htmlBody;
  final List<MailDraftAttachment> attachments;
  final DateTime updatedAt;

  bool get isEmpty {
    return to.trim().isEmpty &&
        cc.trim().isEmpty &&
        bcc.trim().isEmpty &&
        subject.trim().isEmpty &&
        body.trim().isEmpty &&
        htmlBody.trim().isEmpty &&
        attachments.isEmpty;
  }

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'to': to,
    'cc': cc,
    'bcc': bcc,
    'subject': subject,
    'body': body,
    'html_body': htmlBody,
    'attachments': [for (final attachment in attachments) attachment.toJson()],
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

class MailDraftAttachment {
  const MailDraftAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  factory MailDraftAttachment.fromJson(Map<String, Object?> json) {
    final encodedBytes = json['bytes'] as String? ?? '';
    return MailDraftAttachment(
      filename: json['filename'] as String? ?? '',
      contentType: json['content_type'] as String? ?? '',
      bytes: _decodeDraftAttachmentBytes(encodedBytes),
    );
  }

  final String filename;
  final String contentType;
  final List<int> bytes;

  Map<String, Object?> toJson() => {
    'filename': filename,
    'content_type': contentType,
    'bytes': base64Encode(bytes),
  };
}

List<int> _decodeDraftAttachmentBytes(String encodedBytes) {
  if (encodedBytes.isEmpty) return const [];
  try {
    return List<int>.unmodifiable(base64Decode(encodedBytes));
  } on FormatException {
    return const [];
  }
}

class MailDraftCache {
  const MailDraftCache({
    this.namespace,
    this.localCacheSecret,
    this.supportDirectoryProvider,
  });

  final String? namespace;
  final String? localCacheSecret;
  final Future<Directory> Function()? supportDirectoryProvider;
  static final Map<String, _DraftAsyncMutex> _locks =
      <String, _DraftAsyncMutex>{};

  Future<MailDraft?> loadComposeDraft() async {
    final file = await _composeDraftFile();
    return _lockFor(file).synchronized(() async {
      if (!await file.exists()) return null;
      final raw = await _readCacheText(file);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = MailDraft.fromJson(decoded.cast<String, Object?>());
      return draft.isEmpty ? null : draft;
    });
  }

  Future<void> saveComposeDraft(MailDraft draft) async {
    final file = await _composeDraftFile();
    await _lockFor(file).synchronized(() async {
      if (draft.isEmpty) {
        await _deleteComposeDraftFiles(file);
        return;
      }
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      if (await temp.exists()) {
        await temp.delete();
      }
      await temp.writeAsString(
        await _writeCacheText(jsonEncode(draft.toJson())),
        encoding: utf8,
      );
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    });
  }

  Future<void> deleteComposeDraft() async {
    final file = await _composeDraftFile();
    await _lockFor(file).synchronized(() => _deleteComposeDraftFiles(file));
  }

  Future<void> clear() async {
    final file = await _composeDraftFile();
    await _lockFor(file).synchronized(() async {
      final namespace = _safeDraftNamespace(this.namespace);
      if (namespace == null) {
        await _deleteComposeDraftFiles(file);
        return;
      }
      final dir = file.parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
  }

  _DraftAsyncMutex _lockFor(File file) {
    return _locks.putIfAbsent(file.path, _DraftAsyncMutex.new);
  }

  Future<void> _deleteComposeDraftFiles(File file) async {
    final temp = File('${file.path}.tmp');
    if (await temp.exists()) {
      await temp.delete();
    }
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _composeDraftFile() async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    final namespace = _safeDraftNamespace(this.namespace);
    if (namespace == null) {
      return File('${dir.path}/mail-drafts/compose.json');
    }
    return File('${dir.path}/mail-drafts/$namespace/compose.json');
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

  Future<String> _writeCacheText(String plaintext) async {
    final cipher = _localCacheCipher;
    return cipher == null ? plaintext : await cipher.encryptText(plaintext);
  }
}

class _DraftAsyncMutex {
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

String? _safeDraftNamespace(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
