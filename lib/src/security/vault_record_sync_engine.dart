import '../api/models.dart';
import 'local_vault_record_store.dart';
import 'local_vault_sync_state_store.dart';
import 'vault_record_sync_mapper.dart';
import 'vault_records.dart';

typedef PushVaultSyncRecords =
    Future<SyncPushResult> Function(List<SyncRecord> records);

typedef PullVaultSyncRecords =
    Future<SyncPullResult> Function({required int after, required int limit});

class VaultRecordSyncResult {
  const VaultRecordSyncResult({
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.cursor,
  });

  final int pushed;
  final int pulled;
  final int conflicts;
  final int cursor;
}

class VaultRecordSyncEngine {
  const VaultRecordSyncEngine({
    required this.recordStore,
    required this.stateStore,
    this.mapper = const VaultRecordSyncMapper(),
  });

  final LocalVaultRecordStore recordStore;
  final LocalVaultSyncStateStore stateStore;
  final VaultRecordSyncMapper mapper;

  Future<VaultRecordSyncResult> sync({
    required String profileId,
    required String deviceId,
    required PushVaultSyncRecords pushRecords,
    required PullVaultSyncRecords pullRecords,
    int pullLimit = 500,
  }) async {
    final local = await recordStore.read(profileId);
    final state =
        await stateStore.read(profileId) ?? LocalVaultSyncState.empty();
    var pushed = 0;
    var conflicts = 0;
    var mergedLocal = local?.records ?? EncryptedVaultRecordSet.empty();
    final locallyDirtyIds = <String>{};
    if (local != null && local.records.records.isNotEmpty) {
      final outgoing = <SyncRecord>[];
      for (final record in local.records.records) {
        if (!record.syncDirty) continue;
        locallyDirtyIds.add(record.id);
        outgoing.add(mapper.toSyncRecord(record: record, deviceId: deviceId));
      }
      if (outgoing.isNotEmpty) {
        final pushResult = await pushRecords(outgoing);
        pushed = outgoing.length;
        mergedLocal = _markPushedRecordsClean(
          local.records,
          deviceId: deviceId,
          logicalTime: pushResult.logicalTime,
        );
      }
    }

    final pulled = await pullRecords(after: state.cursor, limit: pullLimit);
    if (pulled.records.isNotEmpty) {
      final mergeResult = _mergePulledRecords(
        local: mergedLocal,
        pulled: pulled.records,
        locallyDirtyIds: locallyDirtyIds,
      );
      mergedLocal = mergeResult.records;
      conflicts = mergeResult.conflicts;
    }
    if (local != null && (pushed > 0 || pulled.records.isNotEmpty)) {
      await recordStore.write(
        profileId: profileId,
        expectedRevision: local.revision,
        records: mergedLocal,
      );
    } else if (local == null && pulled.records.isNotEmpty) {
      await recordStore.write(
        profileId: profileId,
        expectedRevision: 0,
        records: mergedLocal,
      );
    }
    final nextState = state.copyWith(
      cursor: pulled.nextCursor,
      lastSyncedAt: DateTime.now().toUtc(),
    );
    await stateStore.write(profileId: profileId, state: nextState);
    return VaultRecordSyncResult(
      pushed: pushed,
      pulled: pulled.records.length,
      conflicts: conflicts,
      cursor: pulled.nextCursor,
    );
  }

  EncryptedVaultRecordSet _markPushedRecordsClean(
    EncryptedVaultRecordSet local, {
    required String deviceId,
    required int logicalTime,
  }) {
    return EncryptedVaultRecordSet(
      version: local.version,
      records: [
        for (final record in local.records)
          if (record.syncDirty)
            record.copyWith(
              versionVector: _outgoingVector(record, deviceId),
              syncDirty: false,
              lastSyncedLogicalTime: logicalTime,
              lastSyncedContentHash: record.contentHash,
            )
          else
            record,
      ],
    );
  }

  _VaultRecordMergeResult _mergePulledRecords({
    required EncryptedVaultRecordSet local,
    required List<SyncRecord> pulled,
    required Set<String> locallyDirtyIds,
  }) {
    final byId = {for (final record in local.records) record.id: record};
    var conflicts = 0;
    for (final syncRecord in pulled) {
      final remote = mapper.fromSyncRecord(syncRecord);
      final current = byId[remote.id];
      if (locallyDirtyIds.contains(remote.id) &&
          current != null &&
          current.contentHash != remote.contentHash) {
        conflicts++;
        continue;
      }
      if (current?.syncDirty == true &&
          current!.contentHash != remote.contentHash) {
        conflicts++;
        continue;
      }
      if (_shouldApplyRemote(current: current, remote: remote)) {
        byId[remote.id] = remote;
      }
    }
    final records =
        byId.values.toList()..sort((a, b) {
          final type = a.type.compareTo(b.type);
          return type == 0 ? a.id.compareTo(b.id) : type;
        });
    return _VaultRecordMergeResult(
      records: EncryptedVaultRecordSet(
        version: local.version,
        records: records,
      ),
      conflicts: conflicts,
    );
  }

  bool _shouldApplyRemote({
    required EncryptedVaultRecord? current,
    required EncryptedVaultRecord remote,
  }) {
    if (current == null) return true;
    if (current.contentHash == remote.contentHash) return true;
    if (remote.deleted && remote.version >= current.version) return true;
    if (current.deleted && remote.version <= current.version) return false;
    return remote.version > current.version;
  }

  Map<String, int> _outgoingVector(
    EncryptedVaultRecord record,
    String deviceId,
  ) {
    final vector = Map<String, int>.from(record.versionVector);
    if (deviceId.trim().isNotEmpty) {
      vector[deviceId] = record.version;
    }
    return vector;
  }
}

class _VaultRecordMergeResult {
  const _VaultRecordMergeResult({
    required this.records,
    required this.conflicts,
  });

  final EncryptedVaultRecordSet records;
  final int conflicts;
}
