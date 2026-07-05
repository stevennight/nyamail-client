import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'vault_records.dart';

class LocalVaultRecordSnapshot {
  const LocalVaultRecordSnapshot({
    required this.revision,
    required this.records,
  });

  factory LocalVaultRecordSnapshot.fromJson(Map<String, Object?> json) {
    return LocalVaultRecordSnapshot(
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      records: EncryptedVaultRecordSet.fromJson(
        (json['records'] as Map).cast<String, Object?>(),
      ),
    );
  }

  final int revision;
  final EncryptedVaultRecordSet records;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'records': records.toJson(),
  };
}

class LocalVaultRecordStore {
  const LocalVaultRecordStore({this.supportDirectoryProvider});

  final Future<Directory> Function()? supportDirectoryProvider;

  Future<LocalVaultRecordSnapshot?> read(String profileId) async {
    final file = await _recordFile(profileId);
    if (!await file.exists()) return null;
    final raw = await file.readAsString(encoding: utf8);
    if (raw.trim().isEmpty) return null;
    return LocalVaultRecordSnapshot.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<LocalVaultRecordSnapshot> write({
    required String profileId,
    required int expectedRevision,
    required EncryptedVaultRecordSet records,
  }) async {
    final current = await read(profileId);
    if (current != null && current.revision != expectedRevision) {
      throw LocalVaultRecordStoreConflict(
        'local vault record revision changed from $expectedRevision to ${current.revision}',
      );
    }
    if (current == null && expectedRevision != 0) {
      throw LocalVaultRecordStoreConflict(
        'local vault record revision changed from $expectedRevision to 0',
      );
    }
    final next = LocalVaultRecordSnapshot(
      revision: expectedRevision + 1,
      records: records,
    );
    final file = await _recordFile(profileId);
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
    final file = await _recordFile(profileId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _recordFile(String profileId) async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    return File(
      '${dir.path}/local-vault-records/${_safeRecordProfileId(profileId)}.json',
    );
  }
}

class LocalVaultRecordStoreConflict implements Exception {
  const LocalVaultRecordStoreConflict(this.message);

  final String message;

  @override
  String toString() => 'LocalVaultRecordStoreConflict: $message';
}

String _safeRecordProfileId(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'default';
  }
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
