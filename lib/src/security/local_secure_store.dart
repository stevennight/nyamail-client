import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto_graphy;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/models.dart';

class LocalSecureStore {
  const LocalSecureStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'nyamail.access_token';
  static const _userIdKey = 'nyamail.user_id';
  static const _emailKey = 'nyamail.email';
  static const _deviceIdKey = 'nyamail.device_id';
  static const _deviceNameKey = 'nyamail.device_name';
  static const _devicePlatformKey = 'nyamail.device_platform';
  static const _sessionDevicePublicKeyKey = 'nyamail.session_device_public_key';
  static const _sessionDeviceBoxPublicKeyKey =
      'nyamail.session_device_box_public_key';
  static const _stableDeviceIdKey = 'nyamail.stable_device_id';
  static const _devicePrivateKeyKey = 'nyamail.device_private_key.ed25519';
  static const _devicePublicKeyKey = 'nyamail.device_public_key.ed25519';
  static const _deviceBoxPrivateKeyKey = 'nyamail.device_private_key.x25519';
  static const _deviceBoxPublicKeyKey = 'nyamail.device_public_key.x25519';
  static const _vaultSecretKey = 'nyamail.vault_secret.v1';
  static const _vaultSecretEnvelopeKey = 'nyamail.vault_secret.envelope.v1';
  static const _quickUnlockSecretKey = 'nyamail.vault_quick_unlock.secret.v1';
  static const _quickUnlockKeyKey = 'nyamail.vault_quick_unlock.key.v1';
  static const _quickUnlockEnvelopeKey =
      'nyamail.vault_quick_unlock.envelope.v1';
  static const _quickUnlockMethodKey = 'nyamail.vault_quick_unlock.method.v1';
  static const _apiBaseUrlKey = 'nyamail.api_base_url';
  static const _localProfileIdKey = 'nyamail.local_profile.id';
  static const _localProfileEmailKey = 'nyamail.local_profile.email';
  static const _localProfileDisplayNameKey =
      'nyamail.local_profile.display_name';

  Future<void> saveSession({
    required String accessToken,
    required String userId,
    required String email,
    required String deviceId,
    required String deviceName,
    required String devicePlatform,
    required String devicePublicKey,
    required String deviceKeyAgreementPublicKey,
  }) async {
    await _storage.write(key: _tokenKey, value: accessToken);
    await _storage.write(key: _userIdKey, value: userId);
    await _storage.write(key: _emailKey, value: email);
    await _storage.write(key: _deviceIdKey, value: deviceId);
    await _storage.write(key: _deviceNameKey, value: deviceName);
    await _storage.write(key: _devicePlatformKey, value: devicePlatform);
    await _storage.write(
      key: _sessionDevicePublicKeyKey,
      value: devicePublicKey,
    );
    await _storage.write(
      key: _sessionDeviceBoxPublicKeyKey,
      value: deviceKeyAgreementPublicKey,
    );
  }

  Future<LocalSession?> readSession() async {
    final token = await _storage.read(key: _tokenKey);
    final userId = await _storage.read(key: _userIdKey);
    final email = await _storage.read(key: _emailKey);
    final deviceId = await _storage.read(key: _deviceIdKey);
    final deviceName = await _storage.read(key: _deviceNameKey);
    final devicePlatform = await _storage.read(key: _devicePlatformKey);
    final devicePublicKey = await _storage.read(
      key: _sessionDevicePublicKeyKey,
    );
    final deviceKeyAgreementPublicKey = await _storage.read(
      key: _sessionDeviceBoxPublicKeyKey,
    );
    if (token == null ||
        userId == null ||
        email == null ||
        deviceId == null ||
        deviceName == null ||
        devicePlatform == null ||
        devicePublicKey == null ||
        deviceKeyAgreementPublicKey == null) {
      return null;
    }
    return LocalSession(
      accessToken: token,
      userId: userId,
      email: email,
      deviceId: deviceId,
      deviceName: deviceName,
      devicePlatform: devicePlatform,
      devicePublicKey: devicePublicKey,
      deviceKeyAgreementPublicKey: deviceKeyAgreementPublicKey,
    );
  }

  Future<void> clearSession() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _deviceIdKey);
    await _storage.delete(key: _deviceNameKey);
    await _storage.delete(key: _devicePlatformKey);
    await _storage.delete(key: _sessionDevicePublicKeyKey);
    await _storage.delete(key: _sessionDeviceBoxPublicKeyKey);
  }

  Future<String?> readStableDeviceId() {
    return _storage.read(key: _stableDeviceIdKey);
  }

  Future<void> saveStableDeviceId(String deviceId) {
    return _storage.write(key: _stableDeviceIdKey, value: deviceId);
  }

  Future<LocalDeviceKeyPair> readOrCreateDeviceKeyPair() async {
    final existingPrivateKey = await _storage.read(key: _devicePrivateKeyKey);
    final existingPublicKey = await _storage.read(key: _devicePublicKeyKey);
    if (existingPrivateKey != null && existingPublicKey != null) {
      return LocalDeviceKeyPair(
        publicKey: existingPublicKey,
        privateKey: existingPrivateKey,
      );
    }
    final algorithm = crypto_graphy.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final encodedPrivateKey = base64Encode(privateKey);
    final encodedPublicKey = base64Encode(publicKey.bytes);
    await _storage.write(key: _devicePrivateKeyKey, value: encodedPrivateKey);
    await _storage.write(key: _devicePublicKeyKey, value: encodedPublicKey);
    return LocalDeviceKeyPair(
      publicKey: encodedPublicKey,
      privateKey: encodedPrivateKey,
    );
  }

  Future<LocalDeviceKeyPair> readOrCreateDeviceBoxKeyPair() async {
    final existingPrivateKey = await _storage.read(
      key: _deviceBoxPrivateKeyKey,
    );
    final existingPublicKey = await _storage.read(key: _deviceBoxPublicKeyKey);
    if (existingPrivateKey != null && existingPublicKey != null) {
      return LocalDeviceKeyPair(
        publicKey: existingPublicKey,
        privateKey: existingPrivateKey,
      );
    }
    final algorithm = crypto_graphy.X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final encodedPrivateKey = base64Encode(privateKey);
    final encodedPublicKey = base64Encode(publicKey.bytes);
    await _storage.write(
      key: _deviceBoxPrivateKeyKey,
      value: encodedPrivateKey,
    );
    await _storage.write(key: _deviceBoxPublicKeyKey, value: encodedPublicKey);
    return LocalDeviceKeyPair(
      publicKey: encodedPublicKey,
      privateKey: encodedPrivateKey,
    );
  }

  Future<String?> readVaultSecret() {
    return _storage.read(key: _vaultSecretKey);
  }

  Future<void> saveVaultSecret(String secret) {
    return _storage.write(key: _vaultSecretKey, value: secret);
  }

  Future<void> clearVaultSecret() {
    return _storage.delete(key: _vaultSecretKey);
  }

  Future<EncryptedBlob?> readVaultSecretEnvelope() async {
    final value = await _storage.read(key: _vaultSecretEnvelopeKey);
    if (value == null || value.trim().isEmpty) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    return EncryptedBlob.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> saveVaultSecretEnvelope(EncryptedBlob envelope) {
    return _storage.write(
      key: _vaultSecretEnvelopeKey,
      value: jsonEncode(envelope.toJson()),
    );
  }

  Future<void> clearVaultSecretEnvelope() {
    return _storage.delete(key: _vaultSecretEnvelopeKey);
  }

  Future<String?> readQuickUnlockSecret() {
    return _storage.read(key: _quickUnlockSecretKey);
  }

  Future<String?> readQuickUnlockKey() {
    return _storage.read(key: _quickUnlockKeyKey);
  }

  Future<EncryptedBlob?> readQuickUnlockEnvelope() async {
    final value = await _storage.read(key: _quickUnlockEnvelopeKey);
    if (value == null || value.trim().isEmpty) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    return EncryptedBlob.fromJson(decoded.cast<String, Object?>());
  }

  Future<String?> readQuickUnlockMethod() {
    return _storage.read(key: _quickUnlockMethodKey);
  }

  Future<void> saveQuickUnlockMaterial({
    required String quickUnlockKey,
    required EncryptedBlob envelope,
    required String method,
  }) async {
    await _storage.write(key: _quickUnlockKeyKey, value: quickUnlockKey);
    await _storage.write(
      key: _quickUnlockEnvelopeKey,
      value: jsonEncode(envelope.toJson()),
    );
    await _storage.write(key: _quickUnlockMethodKey, value: method);
    await _storage.delete(key: _quickUnlockSecretKey);
  }

  Future<void> clearQuickUnlockMaterial() async {
    await _storage.delete(key: _quickUnlockSecretKey);
    await _storage.delete(key: _quickUnlockKeyKey);
    await _storage.delete(key: _quickUnlockEnvelopeKey);
    await _storage.delete(key: _quickUnlockMethodKey);
  }

  Future<void> clearVaultUnlockMaterial() async {
    await clearVaultSecret();
    await clearVaultSecretEnvelope();
    await clearQuickUnlockMaterial();
  }

  Future<String?> readApiBaseUrl() {
    return _storage.read(key: _apiBaseUrlKey);
  }

  Future<void> saveApiBaseUrl(String value) {
    return _storage.write(key: _apiBaseUrlKey, value: value);
  }

  Future<void> clearApiBaseUrl() {
    return _storage.delete(key: _apiBaseUrlKey);
  }

  Future<void> saveLocalProfile(LocalProfile profile) async {
    await _storage.write(key: _localProfileIdKey, value: profile.id);
    await _storage.write(key: _localProfileEmailKey, value: profile.email);
    await _storage.write(
      key: _localProfileDisplayNameKey,
      value: profile.displayName,
    );
  }

  Future<LocalProfile?> readLocalProfile() async {
    final id = await _storage.read(key: _localProfileIdKey);
    final email = await _storage.read(key: _localProfileEmailKey) ?? '';
    final displayName = await _storage.read(key: _localProfileDisplayNameKey);
    if (id == null || displayName == null) return null;
    return LocalProfile(id: id, email: email, displayName: displayName);
  }

  Future<void> clearLocalProfile() async {
    await _storage.delete(key: _localProfileIdKey);
    await _storage.delete(key: _localProfileEmailKey);
    await _storage.delete(key: _localProfileDisplayNameKey);
  }
}

class LocalProfile {
  const LocalProfile({
    required this.id,
    required this.displayName,
    this.email = '',
  });

  final String id;
  final String email;
  final String displayName;

  String get label {
    final display = displayName.trim();
    if (display.isNotEmpty) return display;
    final address = email.trim();
    if (address.isNotEmpty) return address;
    return 'Local vault';
  }
}

class LocalSession {
  const LocalSession({
    required this.accessToken,
    required this.userId,
    required this.email,
    required this.deviceId,
    required this.deviceName,
    required this.devicePlatform,
    required this.devicePublicKey,
    required this.deviceKeyAgreementPublicKey,
  });

  final String accessToken;
  final String userId;
  final String email;
  final String deviceId;
  final String deviceName;
  final String devicePlatform;
  final String devicePublicKey;
  final String deviceKeyAgreementPublicKey;

  DeviceSummary toDeviceSummary() {
    return DeviceSummary(
      id: deviceId,
      name: deviceName,
      platform: devicePlatform,
      publicKey: devicePublicKey,
      keyAgreementPublicKey: deviceKeyAgreementPublicKey,
      trusted: true,
    );
  }
}

class LocalDeviceKeyPair {
  const LocalDeviceKeyPair({required this.publicKey, required this.privateKey});

  final String publicKey;
  final String privateKey;
}
