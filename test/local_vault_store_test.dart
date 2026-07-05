import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/local_vault_store.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';

void main() {
  test(
    'local vault store persists encrypted snapshots with revisions',
    () async {
      final temp = await Directory.systemTemp.createTemp('nyamail-vault-test-');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final store = LocalVaultStore(supportDirectoryProvider: () async => temp);
      const crypto = VaultCrypto();
      final secret = crypto.newVaultSecret();
      final blob = await crypto.encryptDocument(
        document: VaultDocument.empty(),
        email: 'owner@example.com',
        password: '',
        vaultSecret: secret,
      );

      final saved = await store.write(
        profileId: 'local-owner',
        expectedRevision: 0,
        blob: blob,
      );
      final loaded = await store.read('local-owner');

      expect(saved.revision, 1);
      expect(loaded?.revision, 1);
      expect(loaded?.blob.metadata['server_plaintext'], 'false');
      expect(
        () => store.write(
          profileId: 'local-owner',
          expectedRevision: 0,
          blob: blob,
        ),
        throwsA(isA<LocalVaultStoreConflict>()),
      );
    },
  );
}
