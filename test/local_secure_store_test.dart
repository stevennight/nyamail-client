import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/security/local_secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('clearVaultSecret removes local vault unlock material', () async {
    const store = LocalSecureStore();

    await store.saveVaultSecret('vault-secret');
    expect(await store.readVaultSecret(), 'vault-secret');

    await store.clearVaultSecret();

    expect(await store.readVaultSecret(), isNull);
  });

  test('vault secret envelope can be saved and cleared', () async {
    const store = LocalSecureStore();
    const envelope = EncryptedBlob(
      algorithm: 'wrap',
      kdf: 'kdf',
      nonce: 'nonce',
      ciphertext: 'ciphertext',
      metadata: {'salt': 'salt', 'mac': 'mac'},
    );

    await store.saveVaultSecretEnvelope(envelope);

    final saved = await store.readVaultSecretEnvelope();
    expect(saved?.algorithm, 'wrap');
    expect(saved?.metadata['salt'], 'salt');

    await store.clearVaultSecretEnvelope();

    expect(await store.readVaultSecretEnvelope(), isNull);
  });

  test('quick unlock material can be saved and cleared', () async {
    const store = LocalSecureStore();
    const envelope = EncryptedBlob(
      algorithm: 'quick-wrap',
      kdf: 'quick-key',
      nonce: 'nonce',
      ciphertext: 'ciphertext',
      metadata: {'mac': 'mac'},
    );

    await store.saveQuickUnlockMaterial(
      quickUnlockKey: 'quick-key',
      envelope: envelope,
      method: 'Windows Hello',
    );

    expect(await store.readQuickUnlockKey(), 'quick-key');
    expect(await store.readQuickUnlockEnvelope(), isNotNull);
    expect(
      await store.readQuickUnlockEnvelope().then((value) => value?.kdf),
      'quick-key',
    );
    expect(await store.readQuickUnlockMethod(), 'Windows Hello');
    expect(await store.readQuickUnlockSecret(), isNull);

    await store.clearQuickUnlockMaterial();

    expect(await store.readQuickUnlockKey(), isNull);
    expect(await store.readQuickUnlockEnvelope(), isNull);
    expect(await store.readQuickUnlockMethod(), isNull);
  });

  test('api base url can be saved and cleared', () async {
    const store = LocalSecureStore();

    await store.saveApiBaseUrl('https://nyamail.example.com');
    expect(await store.readApiBaseUrl(), 'https://nyamail.example.com');

    await store.clearApiBaseUrl();

    expect(await store.readApiBaseUrl(), isNull);
  });

  test('clearSession preserves local vault identity', () async {
    const store = LocalSecureStore();

    await store.saveSession(
      accessToken: 'token',
      userId: 'user-1',
      email: 'owner@example.com',
      deviceId: 'device-1',
      deviceName: 'Windows desktop',
      devicePlatform: 'windows',
      devicePublicKey: 'signing-public-key',
      deviceKeyAgreementPublicKey: 'box-public-key',
    );
    await store.saveVaultSecret('vault-secret');
    await store.saveVaultSecretEnvelope(
      const EncryptedBlob(
        algorithm: 'wrap',
        kdf: 'kdf',
        nonce: 'nonce',
        ciphertext: 'ciphertext',
      ),
    );
    await store.saveQuickUnlockMaterial(
      quickUnlockKey: 'quick-key',
      envelope: const EncryptedBlob(
        algorithm: 'quick-wrap',
        kdf: 'quick-key',
        nonce: 'nonce',
        ciphertext: 'ciphertext',
      ),
      method: 'Windows Hello',
    );
    await store.saveLocalProfile(
      const LocalProfile(
        id: 'local-owner',
        email: 'owner@example.com',
        displayName: 'Owner',
      ),
    );

    await store.clearSession();

    expect(await store.readSession(), isNull);
    expect(await store.readVaultSecret(), 'vault-secret');
    expect(await store.readVaultSecretEnvelope(), isNotNull);
    expect(await store.readQuickUnlockKey(), 'quick-key');
    final profile = await store.readLocalProfile();
    expect(profile?.id, 'local-owner');
    expect(profile?.email, 'owner@example.com');
  });

  test('local profile can be saved and cleared', () async {
    const store = LocalSecureStore();

    await store.saveLocalProfile(
      const LocalProfile(
        id: 'local-owner',
        email: 'owner@example.com',
        displayName: 'Owner',
      ),
    );
    final profile = await store.readLocalProfile();

    expect(profile?.id, 'local-owner');
    expect(profile?.email, 'owner@example.com');
    expect(profile?.displayName, 'Owner');

    await store.clearLocalProfile();

    expect(await store.readLocalProfile(), isNull);
  });

  test('local profile does not require an email address', () async {
    const store = LocalSecureStore();

    await store.saveLocalProfile(
      const LocalProfile(id: 'local-vault', displayName: 'Personal vault'),
    );
    final profile = await store.readLocalProfile();

    expect(profile?.id, 'local-vault');
    expect(profile?.email, '');
    expect(profile?.label, 'Personal vault');
  });

  test('clearVaultUnlockMaterial removes every local unlock path', () async {
    const store = LocalSecureStore();

    await store.saveVaultSecret('legacy-secret');
    await store.saveVaultSecretEnvelope(
      const EncryptedBlob(
        algorithm: 'wrap',
        kdf: 'kdf',
        nonce: 'nonce',
        ciphertext: 'ciphertext',
      ),
    );
    await store.saveQuickUnlockMaterial(
      quickUnlockKey: 'quick-key',
      envelope: const EncryptedBlob(
        algorithm: 'quick-wrap',
        kdf: 'quick-key',
        nonce: 'nonce',
        ciphertext: 'ciphertext',
      ),
      method: 'Windows Hello',
    );

    await store.clearVaultUnlockMaterial();

    expect(await store.readVaultSecret(), isNull);
    expect(await store.readVaultSecretEnvelope(), isNull);
    expect(await store.readQuickUnlockKey(), isNull);
    expect(await store.readQuickUnlockEnvelope(), isNull);
  });
}
