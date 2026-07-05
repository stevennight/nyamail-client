import '../api/models.dart';
import 'vault_crypto.dart';
import 'vault_record_crypto.dart';
import 'vault_records.dart';

class VaultRecordSyncMapper {
  const VaultRecordSyncMapper();

  SyncRecord toSyncRecord({
    required EncryptedVaultRecord record,
    required String deviceId,
  }) {
    final vector = Map<String, int>.from(record.versionVector);
    if (deviceId.trim().isNotEmpty) {
      vector[deviceId] = record.version;
    }
    return SyncRecord(
      id: record.id,
      entityType: record.type,
      entityId: record.entityId,
      deviceId: deviceId,
      version: record.version,
      versionVector: vector,
      logicalTime: 0,
      algorithm: record.blob.algorithm,
      kdf: record.blob.kdf,
      nonce: record.blob.nonce,
      ciphertext: record.blob.ciphertext,
      contentHash: record.contentHash,
      metadata: record.blob.metadata,
      deleted: record.deleted,
      updatedAt: record.updatedAt,
    );
  }

  EncryptedVaultRecord fromSyncRecord(SyncRecord record) {
    return EncryptedVaultRecord(
      id: record.id,
      type: record.entityType,
      entityId: record.entityId,
      version: record.version,
      updatedAt: record.updatedAt ?? DateTime.now().toUtc(),
      deleted: record.deleted,
      contentHash: record.contentHash,
      versionVector:
          record.versionVector.isEmpty
              ? {record.deviceId: record.version}
              : record.versionVector,
      syncDirty: false,
      lastSyncedLogicalTime: record.logicalTime,
      lastSyncedContentHash: record.contentHash,
      blob: EncryptedBlob(
        algorithm:
            record.algorithm.isEmpty
                ? VaultRecordCrypto.algorithm
                : record.algorithm,
        kdf: record.kdf.isEmpty ? VaultCrypto.directKeyName : record.kdf,
        nonce: record.nonce,
        ciphertext: record.ciphertext,
        metadata: record.metadata,
      ),
    );
  }
}
