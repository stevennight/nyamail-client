import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalVaultSyncState {
  const LocalVaultSyncState({required this.cursor, this.lastSyncedAt});

  factory LocalVaultSyncState.empty() {
    return const LocalVaultSyncState(cursor: 0);
  }

  factory LocalVaultSyncState.fromJson(Map<String, Object?> json) {
    return LocalVaultSyncState(
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      lastSyncedAt:
          json['last_synced_at'] == null
              ? null
              : DateTime.parse(json['last_synced_at'] as String),
    );
  }

  final int cursor;
  final DateTime? lastSyncedAt;

  LocalVaultSyncState copyWith({int? cursor, DateTime? lastSyncedAt}) {
    return LocalVaultSyncState(
      cursor: cursor ?? this.cursor,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    if (lastSyncedAt != null)
      'last_synced_at': lastSyncedAt!.toUtc().toIso8601String(),
  };
}

class LocalVaultSyncStateStore {
  const LocalVaultSyncStateStore({this.supportDirectoryProvider});

  final Future<Directory> Function()? supportDirectoryProvider;

  Future<LocalVaultSyncState?> read(String profileId) async {
    final file = await _stateFile(profileId);
    if (!await file.exists()) return null;
    final raw = await file.readAsString(encoding: utf8);
    if (raw.trim().isEmpty) return null;
    return LocalVaultSyncState.fromJson(
      (jsonDecode(raw) as Map).cast<String, Object?>(),
    );
  }

  Future<void> write({
    required String profileId,
    required LocalVaultSyncState state,
  }) async {
    final file = await _stateFile(profileId);
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(jsonEncode(state.toJson()), encoding: utf8);
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
  }

  Future<void> clear(String profileId) async {
    final file = await _stateFile(profileId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _stateFile(String profileId) async {
    final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
    final dir = await provider();
    return File(
      '${dir.path}/local-vault-sync/${_safeSyncProfileId(profileId)}.json',
    );
  }
}

String _safeSyncProfileId(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'default';
  }
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}
