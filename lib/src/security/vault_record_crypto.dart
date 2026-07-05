import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_graphy;

import '../api/models.dart';
import 'vault_crypto.dart';
import 'vault_records.dart';

class VaultRecordCrypto {
  const VaultRecordCrypto({crypto_graphy.AesGcm? cipher}) : _cipher = cipher;

  static const algorithm = 'nyamail-vault-record-aes256gcm-v1';
  static const nonceLength = 12;

  final crypto_graphy.AesGcm? _cipher;

  Future<EncryptedVaultRecord> encryptRecord({
    required VaultRecord record,
    required String vaultSecret,
  }) async {
    final nonce = _randomBytes(nonceLength);
    final plaintext = utf8.encode(jsonEncode(record.payload));
    final secretBox = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
        .encrypt(plaintext, secretKey: _recordKey(vaultSecret), nonce: nonce);
    final ciphertext = _encodeBytes(secretBox.cipherText);
    return EncryptedVaultRecord(
      id: record.id,
      type: record.type,
      entityId: record.entityId,
      version: record.version,
      updatedAt: record.updatedAt,
      deleted: record.deleted,
      blob: EncryptedBlob(
        algorithm: algorithm,
        kdf: VaultCrypto.directKeyName,
        nonce: _encodeBytes(secretBox.nonce),
        ciphertext: ciphertext,
        metadata: {
          'server_plaintext': 'false',
          'record_id': record.id,
          'record_type': record.type,
          'entity_id': record.entityId,
          'mac': _encodeBytes(secretBox.mac.bytes),
          'key_bits': '256',
        },
      ),
      contentHash: _contentHash(ciphertext),
    );
  }

  Future<VaultRecord> decryptRecord({
    required EncryptedVaultRecord record,
    required String vaultSecret,
  }) async {
    if (record.blob.algorithm != algorithm ||
        record.blob.kdf != VaultCrypto.directKeyName) {
      throw VaultCryptoException(
        'unsupported vault record format: ${record.blob.algorithm}/${record.blob.kdf}',
      );
    }
    final encrypted = _decodeBytes(record.blob.ciphertext);
    final nonce = _decodeBytes(record.blob.nonce);
    final mac = _decodeMetadataBytes(record.blob, 'mac');
    try {
      final plaintext = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
          .decrypt(
            crypto_graphy.SecretBox(
              encrypted,
              nonce: nonce,
              mac: crypto_graphy.Mac(mac),
            ),
            secretKey: _recordKey(vaultSecret),
          );
      final decoded = jsonDecode(utf8.decode(plaintext));
      return VaultRecord(
        id: record.id,
        type: record.type,
        entityId: record.entityId,
        payload: (decoded as Map).cast<String, Object?>(),
        version: record.version,
        updatedAt: record.updatedAt,
        deleted: record.deleted,
      );
    } on crypto_graphy.SecretBoxAuthenticationError {
      throw const VaultCryptoException('vault record authentication failed');
    } on FormatException catch (error) {
      throw VaultCryptoException(
        'vault record plaintext is invalid: ${error.message}',
      );
    }
  }

  Future<EncryptedVaultRecordSet> encryptRecordSet({
    required VaultRecordSet records,
    required String vaultSecret,
  }) async {
    final encrypted = <EncryptedVaultRecord>[];
    for (final record in records.records) {
      encrypted.add(
        await encryptRecord(record: record, vaultSecret: vaultSecret),
      );
    }
    return EncryptedVaultRecordSet(
      version: records.version,
      records: encrypted,
    );
  }

  Future<VaultRecordSet> decryptRecordSet({
    required EncryptedVaultRecordSet records,
    required String vaultSecret,
  }) async {
    final decrypted = <VaultRecord>[];
    for (final record in records.records) {
      decrypted.add(
        await decryptRecord(record: record, vaultSecret: vaultSecret),
      );
    }
    return VaultRecordSet(version: records.version, records: decrypted);
  }

  crypto_graphy.SecretKey _recordKey(String vaultSecret) {
    return crypto_graphy.SecretKey(_decodeBytes(vaultSecret));
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  String _contentHash(String ciphertext) {
    return sha256.convert(utf8.encode(ciphertext)).toString();
  }

  List<int> _decodeMetadataBytes(EncryptedBlob blob, String key) {
    final value = blob.metadata[key];
    if (value == null || value.isEmpty) {
      throw VaultCryptoException('vault record metadata is missing $key');
    }
    return _decodeBytes(value);
  }

  String _encodeBytes(List<int> bytes) => base64UrlEncode(bytes);

  List<int> _decodeBytes(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException catch (error) {
      throw VaultCryptoException(
        'vault record encoding is invalid: ${error.message}',
      );
    }
  }
}
