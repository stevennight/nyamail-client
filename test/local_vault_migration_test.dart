import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/local_vault_migration.dart';
import 'package:nyamail/src/security/local_vault_record_store.dart';
import 'package:nyamail/src/security/local_vault_store.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';

void main() {
  test(
    'migrates legacy local vault into record vault and removes legacy copy',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-local-vault-migration-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const profileId = 'local-profile';
      const profileEmail = '';
      const vaultCrypto = VaultCrypto();
      const recordCrypto = VaultRecordCrypto();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final legacyStore = LocalVaultStore(
        supportDirectoryProvider: () async => temp,
      );
      final recordStore = LocalVaultRecordStore(
        supportDirectoryProvider: () async => temp,
      );
      final legacyDocument = VaultDocument.empty().upsertOAuthProvider(
        const VaultOAuthProviderConfig(
          provider: 'google',
          clientId: 'google-client-id',
          clientSecret: 'google-client-secret',
        ),
      );
      await legacyStore.write(
        profileId: profileId,
        expectedRevision: 0,
        blob: await vaultCrypto.encryptDocument(
          document: legacyDocument,
          email: profileEmail,
          password: '',
          vaultSecret: vaultSecret,
        ),
      );

      final result = await loadOrMigrateLocalVaultDocument(
        profileId: profileId,
        profileEmail: profileEmail,
        vaultSecret: vaultSecret,
        recordStore: recordStore,
        legacyStore: legacyStore,
        recordCrypto: recordCrypto,
        vaultCrypto: vaultCrypto,
        clock: () => DateTime.utc(2026, 7, 6),
      );

      expect(result.migratedLegacyVault, isTrue);
      expect(result.createdRecordVault, isTrue);
      expect(result.recordRevision, 1);
      expect(result.document.oauthProviders.single.provider, 'gmail');
      expect(await legacyStore.read(profileId), isNull);
      final migrated = await recordStore.read(profileId);
      expect(migrated?.revision, 1);
      final records = await recordCrypto.decryptRecordSet(
        records: migrated!.records,
        vaultSecret: vaultSecret,
      );
      final restored = records.toVaultDocument();
      expect(restored.oauthProviders.single.provider, 'gmail');
      expect(
        restored.oauthProviders.single.clientSecret,
        'google-client-secret',
      );
    },
  );

  test('creates an empty record vault when no legacy vault exists', () async {
    final temp = await Directory.systemTemp.createTemp(
      'nyamail-local-vault-empty-migration-test-',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    const vaultCrypto = VaultCrypto();
    const recordCrypto = VaultRecordCrypto();
    final vaultSecret = vaultCrypto.newVaultSecret();
    final legacyStore = LocalVaultStore(
      supportDirectoryProvider: () async => temp,
    );
    final recordStore = LocalVaultRecordStore(
      supportDirectoryProvider: () async => temp,
    );

    final result = await loadOrMigrateLocalVaultDocument(
      profileId: 'local-profile',
      profileEmail: '',
      vaultSecret: vaultSecret,
      recordStore: recordStore,
      legacyStore: legacyStore,
      recordCrypto: recordCrypto,
      vaultCrypto: vaultCrypto,
    );

    expect(result.migratedLegacyVault, isFalse);
    expect(result.createdRecordVault, isTrue);
    expect(result.document.items, isEmpty);
    expect(await recordStore.read('local-profile'), isNotNull);
  });
}
