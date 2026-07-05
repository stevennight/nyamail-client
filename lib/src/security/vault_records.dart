import 'dart:convert';

import '../api/models.dart';
import 'vault_document.dart';

abstract final class VaultRecordTypes {
  static const mailAccount = 'mail_account';
  static const oauthProvider = 'oauth_provider';
  static const appSettings = 'app_settings';
  static const syncDeletion = 'sync_deletion';
}

class VaultRecord {
  const VaultRecord({
    required this.id,
    required this.type,
    required this.entityId,
    required this.payload,
    required this.version,
    required this.updatedAt,
    this.deleted = false,
  });

  factory VaultRecord.fromJson(Map<String, Object?> json) {
    return VaultRecord(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      entityId: json['entity_id'] as String? ?? '',
      payload: ((json['payload'] as Map?) ?? const {}).cast<String, Object?>(),
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  final String id;
  final String type;
  final String entityId;
  final Map<String, Object?> payload;
  final int version;
  final DateTime updatedAt;
  final bool deleted;

  VaultRecord copyWith({
    String? id,
    String? type,
    String? entityId,
    Map<String, Object?>? payload,
    int? version,
    DateTime? updatedAt,
    bool? deleted,
  }) {
    return VaultRecord(
      id: id ?? this.id,
      type: type ?? this.type,
      entityId: entityId ?? this.entityId,
      payload: payload ?? this.payload,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'entity_id': entityId,
    'payload': payload,
    'version': version,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    if (deleted) 'deleted': true,
  };
}

class VaultRecordSet {
  const VaultRecordSet({required this.version, required this.records});

  factory VaultRecordSet.empty() {
    return const VaultRecordSet(version: 1, records: []);
  }

  factory VaultRecordSet.fromJson(Map<String, Object?> json) {
    return VaultRecordSet(
      version: (json['version'] as num?)?.toInt() ?? 1,
      records:
          ((json['records'] as List?) ?? const [])
              .map(
                (item) =>
                    VaultRecord.fromJson((item as Map).cast<String, Object?>()),
              )
              .toList(),
    );
  }

  factory VaultRecordSet.decodePlaintext(String plaintext) {
    if (plaintext.trim().isEmpty) return VaultRecordSet.empty();
    return VaultRecordSet.fromJson(
      (jsonDecode(plaintext) as Map).cast<String, Object?>(),
    );
  }

  factory VaultRecordSet.fromVaultDocument(
    VaultDocument document, {
    DateTime? updatedAt,
  }) {
    final timestamp =
        updatedAt?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return VaultRecordSet(
      version: 1,
      records: [
        for (final item in document.items)
          VaultRecord(
            id: item.id,
            type: VaultRecordTypes.mailAccount,
            entityId: item.id,
            payload: item.toJson(),
            version: 1,
            updatedAt: timestamp,
          ),
        for (final provider in document.oauthProviders)
          VaultRecord(
            id: oauthProviderRecordId(provider.provider),
            type: VaultRecordTypes.oauthProvider,
            entityId: provider.provider,
            payload: provider.toJson(),
            version: 1,
            updatedAt: timestamp,
          ),
      ],
    );
  }

  final int version;
  final List<VaultRecord> records;

  VaultDocument toVaultDocument() {
    final mailboxes = <VaultMailboxItem>[];
    final providers = <VaultOAuthProviderConfig>[];
    for (final record in records) {
      if (record.deleted) continue;
      switch (record.type) {
        case VaultRecordTypes.mailAccount:
          mailboxes.add(VaultMailboxItem.fromJson(record.payload));
        case VaultRecordTypes.oauthProvider:
          final provider = VaultOAuthProviderConfig.fromJson(record.payload);
          if (provider.provider.isNotEmpty) providers.add(provider);
      }
    }
    return VaultDocument(
      version: 1,
      items: mailboxes,
      oauthProviders: providers,
    );
  }

  VaultRecordSet upsert(VaultRecord record) {
    final next = [...records];
    final index = next.indexWhere((item) => item.id == record.id);
    if (index >= 0) {
      next[index] = record;
    } else {
      next.add(record);
    }
    return VaultRecordSet(version: version, records: next);
  }

  VaultRecordSet markDeleted({
    required String id,
    required DateTime deletedAt,
  }) {
    final next = [...records];
    final index = next.indexWhere((item) => item.id == id);
    if (index < 0) return this;
    final current = next[index];
    next[index] = current.copyWith(
      version: current.version + 1,
      updatedAt: deletedAt.toUtc(),
      deleted: true,
      payload: const {},
    );
    return VaultRecordSet(version: version, records: next);
  }

  String encodePlaintext() {
    return jsonEncode(toJson());
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'records': records.map((record) => record.toJson()).toList(),
  };
}

class EncryptedVaultRecord {
  const EncryptedVaultRecord({
    required this.id,
    required this.type,
    required this.entityId,
    required this.version,
    required this.updatedAt,
    required this.blob,
    required this.contentHash,
    this.versionVector = const {},
    this.syncDirty = true,
    this.lastSyncedLogicalTime,
    this.lastSyncedContentHash = '',
    this.deleted = false,
  });

  factory EncryptedVaultRecord.fromJson(Map<String, Object?> json) {
    return EncryptedVaultRecord(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      entityId: json['entity_id'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      blob: EncryptedBlob.fromJson(
        (json['blob'] as Map).cast<String, Object?>(),
      ),
      contentHash: json['content_hash'] as String? ?? '',
      versionVector: ((json['version_vector'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
      syncDirty: json['sync_dirty'] as bool? ?? true,
      lastSyncedLogicalTime:
          (json['last_synced_logical_time'] as num?)?.toInt(),
      lastSyncedContentHash: json['last_synced_content_hash'] as String? ?? '',
      deleted: json['deleted'] as bool? ?? false,
    );
  }

  final String id;
  final String type;
  final String entityId;
  final int version;
  final DateTime updatedAt;
  final EncryptedBlob blob;
  final String contentHash;
  final Map<String, int> versionVector;
  final bool syncDirty;
  final int? lastSyncedLogicalTime;
  final String lastSyncedContentHash;
  final bool deleted;

  EncryptedVaultRecord copyWith({
    String? id,
    String? type,
    String? entityId,
    int? version,
    DateTime? updatedAt,
    EncryptedBlob? blob,
    String? contentHash,
    Map<String, int>? versionVector,
    bool? syncDirty,
    int? lastSyncedLogicalTime,
    String? lastSyncedContentHash,
    bool? deleted,
  }) {
    return EncryptedVaultRecord(
      id: id ?? this.id,
      type: type ?? this.type,
      entityId: entityId ?? this.entityId,
      version: version ?? this.version,
      updatedAt: updatedAt ?? this.updatedAt,
      blob: blob ?? this.blob,
      contentHash: contentHash ?? this.contentHash,
      versionVector: versionVector ?? this.versionVector,
      syncDirty: syncDirty ?? this.syncDirty,
      lastSyncedLogicalTime:
          lastSyncedLogicalTime ?? this.lastSyncedLogicalTime,
      lastSyncedContentHash:
          lastSyncedContentHash ?? this.lastSyncedContentHash,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'type': type,
    'entity_id': entityId,
    'version': version,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'blob': blob.toJson(),
    'content_hash': contentHash,
    if (versionVector.isNotEmpty) 'version_vector': versionVector,
    'sync_dirty': syncDirty,
    if (lastSyncedLogicalTime != null)
      'last_synced_logical_time': lastSyncedLogicalTime,
    if (lastSyncedContentHash.isNotEmpty)
      'last_synced_content_hash': lastSyncedContentHash,
    if (deleted) 'deleted': true,
  };
}

class EncryptedVaultRecordSet {
  const EncryptedVaultRecordSet({required this.version, required this.records});

  factory EncryptedVaultRecordSet.empty() {
    return const EncryptedVaultRecordSet(version: 1, records: []);
  }

  factory EncryptedVaultRecordSet.fromJson(Map<String, Object?> json) {
    return EncryptedVaultRecordSet(
      version: (json['version'] as num?)?.toInt() ?? 1,
      records:
          ((json['records'] as List?) ?? const [])
              .map(
                (item) => EncryptedVaultRecord.fromJson(
                  (item as Map).cast<String, Object?>(),
                ),
              )
              .toList(),
    );
  }

  final int version;
  final List<EncryptedVaultRecord> records;

  EncryptedVaultRecordSet upsert(EncryptedVaultRecord record) {
    final next = [...records];
    final index = next.indexWhere((item) => item.id == record.id);
    if (index >= 0) {
      next[index] = record;
    } else {
      next.add(record);
    }
    return EncryptedVaultRecordSet(version: version, records: next);
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'records': records.map((record) => record.toJson()).toList(),
  };
}

String oauthProviderRecordId(String provider) {
  return 'oauth_provider:${normalizeOAuthProviderKey(provider)}';
}
