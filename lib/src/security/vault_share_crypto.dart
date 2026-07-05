import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart' as crypto_graphy;

import '../api/models.dart';

class VaultShareCrypto {
  const VaultShareCrypto({
    crypto_graphy.X25519? keyAgreement,
    crypto_graphy.AesGcm? cipher,
  })  : _keyAgreement = keyAgreement,
        _cipher = cipher;

  static const algorithm = 'nyamail-device-vault-share-x25519-aes256gcm-v1';
  static const nonceLength = 12;

  final crypto_graphy.X25519? _keyAgreement;
  final crypto_graphy.AesGcm? _cipher;

  Future<VaultSharePayload> encryptForDevice({
    required String recipientPublicKey,
    required String plaintext,
  }) async {
    final x25519 = _keyAgreement ?? crypto_graphy.X25519();
    final senderKeyPair = await x25519.newKeyPair();
    final senderPublicKey = await senderKeyPair.extractPublicKey();
    final recipientKey = crypto_graphy.SimplePublicKey(
      _decodeBytes(recipientPublicKey),
      type: crypto_graphy.KeyPairType.x25519,
    );
    final sharedKey = await x25519.sharedSecretKey(
      keyPair: senderKeyPair,
      remotePublicKey: recipientKey,
    );
    final nonce = _randomBytes(nonceLength);
    final box = await (_cipher ?? crypto_graphy.AesGcm.with256bits()).encrypt(
      utf8.encode(plaintext),
      secretKey: sharedKey,
      nonce: nonce,
    );
    return VaultSharePayload(
      senderPublicKey: base64Encode(senderPublicKey.bytes),
      algorithm: algorithm,
      nonce: base64Encode(box.nonce),
      ciphertext: base64Encode(box.cipherText),
      mac: base64Encode(box.mac.bytes),
    );
  }

  Future<String> decryptFromShare({
    required VaultShare share,
    required String privateKey,
  }) async {
    if (share.algorithm != algorithm) {
      throw VaultShareCryptoException(
        'unsupported vault share format: ${share.algorithm}',
      );
    }
    final x25519 = _keyAgreement ?? crypto_graphy.X25519();
    final keyPair = await x25519.newKeyPairFromSeed(_decodeBytes(privateKey));
    final senderKey = crypto_graphy.SimplePublicKey(
      _decodeBytes(share.senderPublicKey),
      type: crypto_graphy.KeyPairType.x25519,
    );
    final sharedKey = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: senderKey,
    );
    try {
      final plaintext =
          await (_cipher ?? crypto_graphy.AesGcm.with256bits()).decrypt(
        crypto_graphy.SecretBox(
          _decodeBytes(share.ciphertext),
          nonce: _decodeBytes(share.nonce),
          mac: crypto_graphy.Mac(_decodeBytes(share.mac)),
        ),
        secretKey: sharedKey,
      );
      return utf8.decode(plaintext);
    } on crypto_graphy.SecretBoxAuthenticationError {
      throw const VaultShareCryptoException(
        'vault share authentication failed',
      );
    }
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  List<int> _decodeBytes(String value) {
    try {
      return base64.decode(value);
    } on FormatException catch (error) {
      throw VaultShareCryptoException(
        'vault share encoding is invalid: ${error.message}',
      );
    }
  }
}

class VaultSharePayload {
  const VaultSharePayload({
    required this.senderPublicKey,
    required this.algorithm,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  final String senderPublicKey;
  final String algorithm;
  final String nonce;
  final String ciphertext;
  final String mac;
}

class VaultShareCryptoException implements Exception {
  const VaultShareCryptoException(this.message);

  final String message;

  @override
  String toString() => 'VaultShareCryptoException: $message';
}
