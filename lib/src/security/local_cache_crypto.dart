import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto_graphy;

class LocalCacheCipher {
  const LocalCacheCipher(this.secret, {crypto_graphy.AesGcm? cipher})
    : _cipher = cipher;

  static const format = 'nyamail-local-cache-aes256gcm-v1';
  static const _nonceLength = 12;
  static const _domain = 'nyamail-local-cache-v1';

  final String secret;
  final crypto_graphy.AesGcm? _cipher;

  Future<String> encryptText(String plaintext) async {
    return encryptBytesToText(utf8.encode(plaintext));
  }

  Future<String> encryptBytesToText(
    List<int> plaintext, {
    Map<String, Object?> metadata = const {},
  }) async {
    final nonce = _randomBytes(_nonceLength);
    final secretBox = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
        .encrypt(
          plaintext,
          secretKey: crypto_graphy.SecretKey(_cacheKeyBytes()),
          nonce: nonce,
        );
    return jsonEncode({
      'format': format,
      'nonce': _encode(secretBox.nonce),
      'ciphertext': _encode(secretBox.cipherText),
      'mac': _encode(secretBox.mac.bytes),
      'plaintext_length': plaintext.length,
      if (metadata.isNotEmpty) 'metadata': metadata,
    });
  }

  Future<String?> tryDecryptText(String raw) async {
    final payload = await tryDecryptPayload(raw);
    if (payload == null) return null;
    return utf8.decode(payload.bytes);
  }

  Future<LocalCachePayload?> tryDecryptPayload(String raw) async {
    try {
      final decoded = _decodeWrapper(raw);
      if (decoded == null) return null;
      final nonce = _decode(decoded['nonce'] as String? ?? '');
      final ciphertext = _decode(decoded['ciphertext'] as String? ?? '');
      final mac = _decode(decoded['mac'] as String? ?? '');
      final plaintext = await (_cipher ?? crypto_graphy.AesGcm.with256bits())
          .decrypt(
            crypto_graphy.SecretBox(
              ciphertext,
              nonce: nonce,
              mac: crypto_graphy.Mac(mac),
            ),
            secretKey: crypto_graphy.SecretKey(_cacheKeyBytes()),
          );
      return LocalCachePayload(
        bytes: plaintext,
        metadata:
            ((decoded['metadata'] as Map?) ?? const {}).cast<String, Object?>(),
      );
    } on crypto_graphy.SecretBoxAuthenticationError {
      return null;
    } on LocalCacheCipherException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static bool looksEncrypted(String raw) => _decodeWrapper(raw) != null;

  static Map<String, Object?>? _decodeWrapper(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, Object?>();
      return map['format'] == format ? map : null;
    } on FormatException {
      return null;
    }
  }

  List<int> _cacheKeyBytes() {
    final root = _decode(secret);
    return sha256.convert([...utf8.encode(_domain), 0, ...root]).bytes;
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static String _encode(List<int> bytes) => base64UrlEncode(bytes);

  static List<int> _decode(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException catch (error) {
      throw LocalCacheCipherException(
        'local cache encoding is invalid: ${error.message}',
      );
    }
  }
}

String localCacheSecretFromPassword({
  required String email,
  required String password,
}) {
  final normalizedEmail = email.trim().toLowerCase();
  final material = utf8.encode(
    'nyamail-local-cache-password-v1\u0000$normalizedEmail\u0000$password',
  );
  return base64UrlEncode(sha256.convert(material).bytes);
}

class LocalCachePayload {
  const LocalCachePayload({required this.bytes, required this.metadata});

  final List<int> bytes;
  final Map<String, Object?> metadata;
}

class LocalCacheCipherException implements Exception {
  const LocalCacheCipherException(this.message);

  final String message;

  @override
  String toString() => 'LocalCacheCipherException: $message';
}
