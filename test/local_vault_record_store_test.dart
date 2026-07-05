import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/local_vault_record_store.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/security/vault_records.dart';

void main() {
  test(
    'local vault record store persists encrypted records with revisions',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-record-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const recordCrypto = VaultRecordCrypto();
      const vaultCrypto = VaultCrypto();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final records = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.imapSmtp,
              address: 'private@example.com',
              displayName: 'Private',
              provider: 'imap',
              username: 'private@example.com',
              secret: 'private-app-password',
              imapHost: 'imap.example.com',
              imapPort: 993,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              useTls: true,
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      final store = LocalVaultRecordStore(
        supportDirectoryProvider: () async => temp,
      );

      final saved = await store.write(
        profileId: 'local-owner',
        expectedRevision: 0,
        records: records,
      );
      final loaded = await store.read('local-owner');

      expect(saved.revision, 1);
      expect(loaded?.revision, 1);
      expect(loaded?.records.records.single.type, VaultRecordTypes.mailAccount);
      await expectLater(
        store.write(
          profileId: 'local-owner',
          expectedRevision: 0,
          records: records,
        ),
        throwsA(isA<LocalVaultRecordStoreConflict>()),
      );

      final raw = await File(
        '${temp.path}/local-vault-records/local-owner.json',
      ).readAsString(encoding: utf8);
      expect(raw, isNot(contains('private@example.com')));
      expect(raw, isNot(contains('private-app-password')));

      final decrypted = await recordCrypto.decryptRecordSet(
        records: loaded!.records,
        vaultSecret: vaultSecret,
      );
      expect(
        decrypted.toVaultDocument().items.single.secret,
        'private-app-password',
      );
    },
  );

  test(
    'local vault record store can persist migrated legacy document',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-record-migration-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const recordCrypto = VaultRecordCrypto();
      const vaultCrypto = VaultCrypto();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final legacy = VaultDocument.empty().upsertOAuthProvider(
        const VaultOAuthProviderConfig(
          provider: 'google',
          clientId: 'google-client-id',
          clientSecret: 'google-client-secret',
        ),
      );
      final migrated = VaultRecordSet.fromVaultDocument(
        legacy,
        updatedAt: DateTime.utc(2026, 4, 5),
      );
      final encrypted = await recordCrypto.encryptRecordSet(
        records: migrated,
        vaultSecret: vaultSecret,
      );
      final store = LocalVaultRecordStore(
        supportDirectoryProvider: () async => temp,
      );

      await store.write(
        profileId: 'owner@example.com',
        expectedRevision: 0,
        records: encrypted,
      );
      final loaded = await store.read('owner@example.com');
      final restored = await recordCrypto.decryptRecordSet(
        records: loaded!.records,
        vaultSecret: vaultSecret,
      );

      expect(
        restored.toVaultDocument().oauthProviders.single.provider,
        'gmail',
      );
      expect(
        restored.toVaultDocument().oauthProviders.single.clientSecret,
        'google-client-secret',
      );
    },
  );
}
