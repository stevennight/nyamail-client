import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_graphy;

import '../api/models.dart';
import 'vault_document.dart';

class VaultCrypto {
  const VaultCrypto({crypto_graphy.AesGcm? cipher, crypto_graphy.Pbkdf2? kdf})
    : _cipher = cipher,
      _kdf = kdf;

  static const algorithm = 'nyamail-vault-aes256gcm-v1';
  static const vaultSecretWrapAlgorithm =
      'nyamail-vault-secret-wrap-aes256gcm-v1';
  static const quickUnlockWrapAlgorithm =
      'nyamail-vault-secret-quick-wrap-aes256gcm-v1';
  static const kdfName = 'pbkdf2-hmac-sha256';
  static const directKeyName = 'direct-vault-secret-v1';
  static const quickUnlockKeyName = 'direct-quick-unlock-key-v1';
  static const kdfIterations = 210000;
  static const saltLength = 16;
  static const nonceLength = 12;
  static const vaultSecretLength = 32;

  final crypto_graphy.AesGcm? _cipher;
  final crypto_graphy.Pbkdf2? _kdf;

  Future<EncryptedBlob> createInitialVault({
    required String email,
    required String password,
    String? vaultSecret,
  }) async {
    return encryptDocument(
      document: VaultDocument.empty(),
      email: email,
      password: password,
      vaultSecret: vaultSecret,
    );
  }

  Future<EncryptedBlob> encryptDocument({
    required VaultDocument document,
    required String email,
    required String password,
    String? vaultSecret,
  }) async {
    final salt = _randomBytes(saltLength);
    final nonce = _randomBytes(nonceLength);
    final key = await _encryptionKey(
      email: email,
      password: password,
      salt: salt,
      vaultSecret: vaultSecret,
    );
    final plaintext = utf8.encode(document.encodePlaintext());
    final secretBox = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
        .encrypt(plaintext, secretKey: key, nonce: nonce);
    return EncryptedBlob(
      algorithm: algorithm,
      kdf: vaultSecret == null ? kdfName : directKeyName,
      nonce: _encodeBytes(secretBox.nonce),
      ciphertext: _encodeBytes(secretBox.cipherText),
      metadata: {
        'contains': 'mailbox credentials only',
        'server_plaintext': 'false',
        'salt': _encodeBytes(salt),
        'mac': _encodeBytes(secretBox.mac.bytes),
        if (vaultSecret == null) 'kdf_iterations': kdfIterations.toString(),
        'key_bits': '256',
      },
    );
  }

  Future<VaultDocument> decryptDocument({
    required EncryptedBlob blob,
    required String email,
    required String password,
    String? vaultSecret,
  }) async {
    if (blob.ciphertext.isEmpty) return VaultDocument.empty();
    if (blob.algorithm != algorithm ||
        (blob.kdf != kdfName && blob.kdf != directKeyName)) {
      throw VaultCryptoException(
        'unsupported vault format: ${blob.algorithm}/${blob.kdf}',
      );
    }
    final salt = _decodeMetadataBytes(blob, 'salt');
    final mac = _decodeMetadataBytes(blob, 'mac');
    final nonce = _decodeBytes(blob.nonce);
    final encrypted = _decodeBytes(blob.ciphertext);
    final key = await _decryptionKey(
      blob: blob,
      email: email,
      password: password,
      salt: salt,
      vaultSecret: vaultSecret,
    );
    try {
      final plaintext = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
          .decrypt(
            crypto_graphy.SecretBox(
              encrypted,
              nonce: nonce,
              mac: crypto_graphy.Mac(mac),
            ),
            secretKey: key,
          );
      return VaultDocument.decodePlaintext(utf8.decode(plaintext));
    } on crypto_graphy.SecretBoxAuthenticationError {
      throw const VaultCryptoException('vault authentication failed');
    } on FormatException catch (error) {
      throw VaultCryptoException(
        'vault plaintext is invalid: ${error.message}',
      );
    }
  }

  String newVaultItemId(String address) {
    final digest = sha256.convert(
      utf8.encode('$address:${DateTime.now().microsecondsSinceEpoch}'),
    );
    return 'vault_${base64UrlEncode(digest.bytes).substring(0, 18)}';
  }

  String newVaultSecret() {
    return _encodeBytes(_randomBytes(vaultSecretLength));
  }

  String newQuickUnlockKey() {
    return _encodeBytes(_randomBytes(vaultSecretLength));
  }

  Future<EncryptedBlob> wrapVaultSecret({
    required String vaultSecret,
    required String password,
  }) async {
    if (password.length < 12) {
      throw const VaultCryptoException(
        'vault password must contain at least 12 characters',
      );
    }
    final secretBytes = _decodeBytes(vaultSecret);
    if (secretBytes.length != vaultSecretLength) {
      throw const VaultCryptoException('vault secret length is invalid');
    }
    final salt = _randomBytes(saltLength);
    final nonce = _randomBytes(nonceLength);
    final key = await _derivePasswordKey(password: password, salt: salt);
    final secretBox = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
        .encrypt(secretBytes, secretKey: key, nonce: nonce);
    return EncryptedBlob(
      algorithm: vaultSecretWrapAlgorithm,
      kdf: kdfName,
      nonce: _encodeBytes(secretBox.nonce),
      ciphertext: _encodeBytes(secretBox.cipherText),
      metadata: {
        'purpose': 'local vault secret wrapper',
        'salt': _encodeBytes(salt),
        'mac': _encodeBytes(secretBox.mac.bytes),
        'kdf_iterations': kdfIterations.toString(),
        'key_bits': '256',
      },
    );
  }

  Future<String> unwrapVaultSecret({
    required EncryptedBlob blob,
    required String password,
  }) async {
    if (blob.algorithm != vaultSecretWrapAlgorithm || blob.kdf != kdfName) {
      throw VaultCryptoException(
        'unsupported vault secret wrapper: ${blob.algorithm}/${blob.kdf}',
      );
    }
    final salt = _decodeMetadataBytes(blob, 'salt');
    final mac = _decodeMetadataBytes(blob, 'mac');
    final nonce = _decodeBytes(blob.nonce);
    final encrypted = _decodeBytes(blob.ciphertext);
    final key = await _derivePasswordKey(password: password, salt: salt);
    try {
      final plaintext = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
          .decrypt(
            crypto_graphy.SecretBox(
              encrypted,
              nonce: nonce,
              mac: crypto_graphy.Mac(mac),
            ),
            secretKey: key,
          );
      if (plaintext.length != vaultSecretLength) {
        throw const VaultCryptoException('vault secret length is invalid');
      }
      return _encodeBytes(plaintext);
    } on crypto_graphy.SecretBoxAuthenticationError {
      throw const VaultCryptoException('vault password is invalid');
    }
  }

  Future<EncryptedBlob> wrapVaultSecretForQuickUnlock({
    required String vaultSecret,
    required String quickUnlockKey,
    required String profileId,
  }) async {
    final secretBytes = _decodeBytes(vaultSecret);
    if (secretBytes.length != vaultSecretLength) {
      throw const VaultCryptoException('vault secret length is invalid');
    }
    final keyBytes = _decodeBytes(quickUnlockKey);
    if (keyBytes.length != vaultSecretLength) {
      throw const VaultCryptoException('quick unlock key length is invalid');
    }
    final nonce = _randomBytes(nonceLength);
    final secretBox = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
        .encrypt(
          secretBytes,
          secretKey: crypto_graphy.SecretKey(keyBytes),
          nonce: nonce,
          aad: _quickUnlockAad(profileId),
        );
    return EncryptedBlob(
      algorithm: quickUnlockWrapAlgorithm,
      kdf: quickUnlockKeyName,
      nonce: _encodeBytes(secretBox.nonce),
      ciphertext: _encodeBytes(secretBox.cipherText),
      metadata: {
        'purpose': 'local system quick unlock wrapper',
        'profile_id': profileId,
        'mac': _encodeBytes(secretBox.mac.bytes),
        'key_bits': '256',
      },
    );
  }

  Future<String> unwrapVaultSecretForQuickUnlock({
    required EncryptedBlob blob,
    required String quickUnlockKey,
    required String profileId,
  }) async {
    if (blob.algorithm != quickUnlockWrapAlgorithm ||
        blob.kdf != quickUnlockKeyName) {
      throw VaultCryptoException(
        'unsupported quick unlock wrapper: ${blob.algorithm}/${blob.kdf}',
      );
    }
    final keyBytes = _decodeBytes(quickUnlockKey);
    if (keyBytes.length != vaultSecretLength) {
      throw const VaultCryptoException('quick unlock key length is invalid');
    }
    final mac = _decodeMetadataBytes(blob, 'mac');
    final nonce = _decodeBytes(blob.nonce);
    final encrypted = _decodeBytes(blob.ciphertext);
    try {
      final plaintext = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
          .decrypt(
            crypto_graphy.SecretBox(
              encrypted,
              nonce: nonce,
              mac: crypto_graphy.Mac(mac),
            ),
            secretKey: crypto_graphy.SecretKey(keyBytes),
            aad: _quickUnlockAad(profileId),
          );
      if (plaintext.length != vaultSecretLength) {
        throw const VaultCryptoException('vault secret length is invalid');
      }
      return _encodeBytes(plaintext);
    } on crypto_graphy.SecretBoxAuthenticationError {
      throw const VaultCryptoException('quick unlock key is invalid');
    }
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<crypto_graphy.SecretKey> _deriveKey({
    required String email,
    required String password,
    required List<int> salt,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    return (_kdf ??
            crypto_graphy.Pbkdf2(
              macAlgorithm: crypto_graphy.Hmac.sha256(),
              iterations: kdfIterations,
              bits: 256,
            ))
        .deriveKey(
          secretKey: crypto_graphy.SecretKey(
            utf8.encode('$normalizedEmail:$password'),
          ),
          nonce: salt,
        );
  }

  Future<crypto_graphy.SecretKey> _derivePasswordKey({
    required String password,
    required List<int> salt,
  }) {
    return (_kdf ??
            crypto_graphy.Pbkdf2(
              macAlgorithm: crypto_graphy.Hmac.sha256(),
              iterations: kdfIterations,
              bits: 256,
            ))
        .deriveKey(
          secretKey: crypto_graphy.SecretKey(utf8.encode(password)),
          nonce: salt,
        );
  }

  Future<crypto_graphy.SecretKey> _encryptionKey({
    required String email,
    required String password,
    required List<int> salt,
    String? vaultSecret,
  }) {
    if (vaultSecret != null) {
      return Future.value(crypto_graphy.SecretKey(_decodeBytes(vaultSecret)));
    }
    return _deriveKey(email: email, password: password, salt: salt);
  }

  Future<crypto_graphy.SecretKey> _decryptionKey({
    required EncryptedBlob blob,
    required String email,
    required String password,
    required List<int> salt,
    String? vaultSecret,
  }) {
    if (blob.kdf == directKeyName) {
      if (vaultSecret == null || vaultSecret.isEmpty) {
        throw const VaultCryptoException('vault secret is required');
      }
      return Future.value(crypto_graphy.SecretKey(_decodeBytes(vaultSecret)));
    }
    return _deriveKey(email: email, password: password, salt: salt);
  }

  List<int> _decodeMetadataBytes(EncryptedBlob blob, String key) {
    final value = blob.metadata[key];
    if (value == null || value.isEmpty) {
      throw VaultCryptoException('vault metadata is missing $key');
    }
    return _decodeBytes(value);
  }

  String _encodeBytes(List<int> bytes) => base64UrlEncode(bytes);

  List<int> _decodeBytes(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException catch (error) {
      throw VaultCryptoException('vault encoding is invalid: ${error.message}');
    }
  }

  List<int> _quickUnlockAad(String profileId) {
    return utf8.encode('nyamail:quick-unlock:v1:${profileId.trim()}');
  }
}

class VaultCryptoException implements Exception {
  const VaultCryptoException(this.message);

  final String message;

  @override
  String toString() => 'VaultCryptoException: $message';
}
