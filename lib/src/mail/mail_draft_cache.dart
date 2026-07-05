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
    required this.updatedAt,
  });

  factory MailDraft.fromJson(Map<String, Object?> json) {
    return MailDraft(
      accountId: json['account_id'] as String? ?? '',
      to: json['to'] as String? ?? '',
      cc: json['cc'] as String? ?? '',
      bcc: json['bcc'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
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
  final DateTime updatedAt;

  bool get isEmpty {
    return to.trim().isEmpty &&
        cc.trim().isEmpty &&
        bcc.trim().isEmpty &&
        subject.trim().isEmpty &&
        body.trim().isEmpty;
  }

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'to': to,
    'cc': cc,
    'bcc': bcc,
    'subject': subject,
    'body': body,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
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

  Future<MailDraft?> loadComposeDraft() async {
    final file = await _composeDraftFile();
    if (!await file.exists()) return null;
    final raw = await _readCacheText(file);
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final draft = MailDraft.fromJson(decoded.cast<String, Object?>());
    return draft.isEmpty ? null : draft;
  }

  Future<void> saveComposeDraft(MailDraft draft) async {
    if (draft.isEmpty) {
      await deleteComposeDraft();
      return;
    }
    final file = await _composeDraftFile();
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
  }

  Future<void> deleteComposeDraft() async {
    final file = await _composeDraftFile();
    final temp = File('${file.path}.tmp');
    if (await temp.exists()) {
      await temp.delete();
    }
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> clear() async {
    final file = await _composeDraftFile();
    final namespace = _safeDraftNamespace(this.namespace);
    if (namespace == null) {
      await deleteComposeDraft();
      return;
    }
    final dir = file.parent;
    if (await dir.exists()) {
      await dir.delete(recursive: true);
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

String? _safeDraftNamespace(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
