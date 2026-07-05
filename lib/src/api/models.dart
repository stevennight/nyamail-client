class DeviceInfoPayload {
  const DeviceInfoPayload({
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.keyAgreementPublicKey,
    this.id,
  });

  final String? id;
  final String name;
  final String platform;
  final String publicKey;
  final String keyAgreementPublicKey;

  Map<String, Object?> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'platform': platform,
    'public_key': publicKey,
    'key_agreement_public_key': keyAgreementPublicKey,
  };
}

class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.name,
    required this.platform,
    required this.publicKey,
    required this.keyAgreementPublicKey,
    required this.trusted,
    this.revokedAt,
  });

  factory DeviceSummary.fromJson(Map<String, Object?> json) {
    return DeviceSummary(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      publicKey: json['public_key'] as String? ?? '',
      keyAgreementPublicKey: json['key_agreement_public_key'] as String? ?? '',
      trusted: json['trusted'] as bool? ?? false,
      revokedAt:
          json['revoked_at'] == null
              ? null
              : DateTime.parse(json['revoked_at'] as String),
    );
  }

  final String id;
  final String name;
  final String platform;
  final String publicKey;
  final String keyAgreementPublicKey;
  final bool trusted;
  final DateTime? revokedAt;

  bool get revoked => revokedAt != null;
}

class UserSummary {
  const UserSummary({
    required this.id,
    required this.email,
    required this.displayName,
  });

  factory UserSummary.fromJson(Map<String, Object?> json) {
    return UserSummary(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
    );
  }

  final String id;
  final String email;
  final String displayName;
}

class EncryptedBlob {
  const EncryptedBlob({
    required this.algorithm,
    required this.kdf,
    required this.nonce,
    required this.ciphertext,
    this.metadata = const {},
  });

  factory EncryptedBlob.fromJson(Map<String, Object?> json) {
    return EncryptedBlob(
      algorithm: json['algorithm'] as String? ?? '',
      kdf: json['kdf'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      ciphertext: json['ciphertext'] as String? ?? '',
      metadata: (json['metadata'] as Map?)?.cast<String, String>() ?? const {},
    );
  }

  final String algorithm;
  final String kdf;
  final String nonce;
  final String ciphertext;
  final Map<String, String> metadata;

  Map<String, Object?> toJson() => {
    'algorithm': algorithm,
    'kdf': kdf,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'metadata': metadata,
  };
}

class VaultSnapshot {
  const VaultSnapshot({required this.revision, required this.blob});

  factory VaultSnapshot.fromJson(Map<String, Object?> json) {
    return VaultSnapshot(
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      blob: EncryptedBlob.fromJson(
        (json['blob'] as Map).cast<String, Object?>(),
      ),
    );
  }

  final int revision;
  final EncryptedBlob blob;
}

class MailboxSummary {
  const MailboxSummary({
    required this.id,
    required this.address,
    required this.displayName,
    required this.provider,
    required this.authType,
    required this.vaultItemId,
  });

  factory MailboxSummary.fromJson(Map<String, Object?> json) {
    return MailboxSummary(
      id: json['id'] as String? ?? '',
      address: json['address'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      authType: json['auth_type'] as String? ?? '',
      vaultItemId: json['vault_item_id'] as String? ?? '',
    );
  }

  final String id;
  final String address;
  final String displayName;
  final String provider;
  final String authType;
  final String vaultItemId;
}

class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.deviceId,
    required this.version,
    required this.logicalTime,
    required this.nonce,
    required this.ciphertext,
    required this.contentHash,
    this.versionVector = const {},
    this.algorithm = '',
    this.kdf = '',
    this.metadata = const {},
    this.deleted = false,
    this.updatedAt,
  });

  factory SyncRecord.fromJson(Map<String, Object?> json) {
    return SyncRecord(
      id: json['id'] as String? ?? '',
      entityType: json['entity_type'] as String? ?? '',
      entityId: json['entity_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      versionVector: ((json['version_vector'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), (value as num).toInt()),
      ),
      logicalTime: (json['logical_time'] as num?)?.toInt() ?? 0,
      algorithm: json['algorithm'] as String? ?? '',
      kdf: json['kdf'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      ciphertext: json['ciphertext'] as String? ?? '',
      contentHash: json['content_hash'] as String? ?? '',
      metadata: ((json['metadata'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      deleted: json['deleted'] as bool? ?? false,
      updatedAt:
          json['updated_at'] == null
              ? null
              : DateTime.parse(json['updated_at'] as String),
    );
  }

  final String id;
  final String entityType;
  final String entityId;
  final String deviceId;
  final int version;
  final Map<String, int> versionVector;
  final int logicalTime;
  final String algorithm;
  final String kdf;
  final String nonce;
  final String ciphertext;
  final String contentHash;
  final Map<String, String> metadata;
  final bool deleted;
  final DateTime? updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'entity_type': entityType,
    'entity_id': entityId,
    'device_id': deviceId,
    'version': version,
    if (versionVector.isNotEmpty) 'version_vector': versionVector,
    'logical_time': logicalTime,
    if (algorithm.isNotEmpty) 'algorithm': algorithm,
    if (kdf.isNotEmpty) 'kdf': kdf,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'content_hash': contentHash,
    if (metadata.isNotEmpty) 'metadata': metadata,
    'deleted': deleted,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
  };
}

class SyncPushResult {
  const SyncPushResult({required this.logicalTime});

  factory SyncPushResult.fromJson(Map<String, Object?> json) {
    return SyncPushResult(
      logicalTime: (json['logical_time'] as num?)?.toInt() ?? 0,
    );
  }

  final int logicalTime;
}

class SyncPullResult {
  const SyncPullResult({required this.records, required this.nextCursor});

  factory SyncPullResult.fromJson(Map<String, Object?> json) {
    return SyncPullResult(
      records:
          ((json['records'] as List?) ?? const [])
              .map(
                (item) =>
                    SyncRecord.fromJson((item as Map).cast<String, Object?>()),
              )
              .toList(),
      nextCursor: (json['next_cursor'] as num?)?.toInt() ?? 0,
    );
  }

  final List<SyncRecord> records;
  final int nextCursor;
}

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.user,
    required this.device,
    required this.email,
    required this.deviceId,
    required this.expiresAt,
    this.vault,
    this.recoveryCodes = const [],
    this.requiresApproval = false,
  });

  factory AuthSession.fromJson(Map<String, Object?> json) {
    final user = (json['user'] as Map).cast<String, Object?>();
    final device = (json['device'] as Map).cast<String, Object?>();
    final userSummary = UserSummary.fromJson(user);
    final deviceSummary = DeviceSummary.fromJson(device);
    return AuthSession(
      accessToken: json['access_token'] as String,
      user: userSummary,
      device: deviceSummary,
      email: userSummary.email,
      deviceId: deviceSummary.id,
      expiresAt: DateTime.parse(json['expires_at'] as String),
      vault:
          json['vault'] == null
              ? null
              : VaultSnapshot.fromJson(
                (json['vault'] as Map).cast<String, Object?>(),
              ),
      recoveryCodes:
          ((json['recovery_codes'] as List?) ?? const []).cast<String>(),
      requiresApproval: json['requires_approval'] as bool? ?? false,
    );
  }

  final String accessToken;
  final UserSummary user;
  final DeviceSummary device;
  final String email;
  final String deviceId;
  final DateTime expiresAt;
  final VaultSnapshot? vault;
  final List<String> recoveryCodes;
  final bool requiresApproval;
}

class ReleaseArtifact {
  const ReleaseArtifact({
    required this.id,
    required this.component,
    required this.platform,
    required this.arch,
    required this.channel,
    required this.version,
    required this.build,
    required this.commit,
    required this.url,
    required this.sha256,
    required this.signature,
    required this.minApiVersion,
    required this.force,
    required this.rollout,
    required this.notes,
    this.requiredVersion,
  });

  factory ReleaseArtifact.fromJson(Map<String, Object?> json) {
    return ReleaseArtifact(
      id: json['id'] as String? ?? '',
      component: json['component'] as String? ?? 'client',
      platform: json['platform'] as String? ?? '',
      arch: json['arch'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      version: json['version'] as String? ?? '',
      build: (json['build'] as num?)?.toInt() ?? 0,
      commit: json['commit'] as String? ?? '',
      url: json['url'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      minApiVersion: json['min_api_version'] as String? ?? '',
      force: json['force'] as bool? ?? false,
      rollout: (json['rollout'] as num?)?.toInt() ?? 100,
      notes: json['notes'] as String? ?? '',
      requiredVersion: json['required_version'] as String?,
    );
  }

  final String id;
  final String component;
  final String platform;
  final String arch;
  final String channel;
  final String version;
  final int build;
  final String commit;
  final String url;
  final String sha256;
  final String signature;
  final String minApiVersion;
  final bool force;
  final int rollout;
  final String notes;
  final String? requiredVersion;
}

class ReleaseCheckResult {
  const ReleaseCheckResult({
    required this.updateAvailable,
    this.latest,
    this.reason,
  });

  factory ReleaseCheckResult.fromJson(Map<String, Object?> json) {
    return ReleaseCheckResult(
      updateAvailable: json['update_available'] as bool? ?? false,
      latest:
          json['latest'] == null
              ? null
              : ReleaseArtifact.fromJson(
                (json['latest'] as Map).cast<String, Object?>(),
              ),
      reason: json['reason'] as String?,
    );
  }

  final bool updateAvailable;
  final ReleaseArtifact? latest;
  final String? reason;
}

class VaultShare {
  const VaultShare({
    required this.id,
    required this.fromDeviceId,
    required this.toDeviceId,
    required this.senderPublicKey,
    required this.algorithm,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    required this.pairingCode,
    required this.approvalVersion,
    required this.approvalSignature,
  });

  factory VaultShare.fromJson(Map<String, Object?> json) {
    return VaultShare(
      id: json['id'] as String? ?? '',
      fromDeviceId: json['from_device_id'] as String? ?? '',
      toDeviceId: json['to_device_id'] as String? ?? '',
      senderPublicKey: json['sender_public_key'] as String? ?? '',
      algorithm: json['algorithm'] as String? ?? '',
      nonce: json['nonce'] as String? ?? '',
      ciphertext: json['ciphertext'] as String? ?? '',
      mac: json['mac'] as String? ?? '',
      pairingCode: json['pairing_code'] as String? ?? '',
      approvalVersion: json['approval_version'] as String? ?? '',
      approvalSignature: json['approval_signature'] as String? ?? '',
    );
  }

  final String id;
  final String fromDeviceId;
  final String toDeviceId;
  final String senderPublicKey;
  final String algorithm;
  final String nonce;
  final String ciphertext;
  final String mac;
  final String pairingCode;
  final String approvalVersion;
  final String approvalSignature;
}
