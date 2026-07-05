import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../api/models.dart';

class LocalVaultSnapshot {
  const LocalVaultSnapshot({required this.revision, required this.blob});

  factory LocalVaultSnapshot.fromJson(Map<String, Object?> json) {
    return LocalVaultSnapshot(
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      blob: EncryptedBlob.fromJson(
        (json['blob'] as Map).cast<String, Object?>(),
      ),
    );
  }

  final int revision;
  final EncryptedBlob blob;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'blob': blob.toJson(),
  };
}

class LocalVaultStore {
  const LocalVaultStore({this.supportDirectoryProvider});

  final Future<Directory> Function()? supportDirectoryProvider;

  Future<LocalVaultSnapshot?> read(String profileId) async {
    final file = await _vaultFile(profileId);
    if (!await file.exists()) return null;
    final raw = await file.readAsString(encoding: utf8);
    if (raw.trim().isEmpty) return null;
    return LocalVaultSnapshot.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<LocalVaultSnapshot> write({
    required String profileId,
    required int expectedRevision,
    required EncryptedBlob blob,
  }) async {
    final current = await read(profileId);
    if (current != null && current.revision != expectedRevision) {
      throw LocalVaultStoreConflict(
        'local vault revision changed from $expectedRevision to ${current.revision}',
      );
    }
    final next = LocalVaultSnapshot(revision: expectedRevision + 1, blob: blob);
    final file = await _vaultFile(profileId);
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(jsonEncode(next.toJson()), encoding: utf8);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
    } catch (_) {
      if (await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
    return next;
  }

  Future<void> clear(String profileId) async {
    final file = await _vaultFile(profileId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _vaultFile(String profileId) async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    return File('${dir.path}/local-vaults/${_safeProfileId(profileId)}.json');
  }
}

class LocalVaultStoreConflict implements Exception {
  const LocalVaultStoreConflict(this.message);

  final String message;

  @override
  String toString() => 'LocalVaultStoreConflict: $message';
}

String _safeProfileId(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'default';
  }
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
