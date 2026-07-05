import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/security/vault_record_sync_mapper.dart';
import 'package:nyamail/src/security/vault_records.dart';

void main() {
  test('vault record sync mapper round trips encrypted records', () async {
    const vaultCrypto = VaultCrypto();
    const recordCrypto = VaultRecordCrypto();
    const mapper = VaultRecordSyncMapper();
    final vaultSecret = vaultCrypto.newVaultSecret();
    final encrypted = await recordCrypto.encryptRecordSet(
      records: VaultRecordSet.fromVaultDocument(
        VaultDocument.empty().upsertMailbox(
          const VaultMailboxItem(
            id: 'mail-1',
            kind: VaultItemKind.imapSmtp,
            address: 'mapped@example.com',
            displayName: 'Mapped',
            provider: 'imap',
            username: 'mapped@example.com',
            secret: 'mapped-secret',
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

    final sync = mapper.toSyncRecord(
      record: encrypted.records.single,
      deviceId: 'device-1',
    );
    final raw = jsonEncode(sync.toJson());

    expect(sync.deviceId, 'device-1');
    expect(sync.versionVector['device-1'], 1);
    expect(sync.metadata['mac'], isNotEmpty);
    expect(raw, isNot(contains('mapped@example.com')));
    expect(raw, isNot(contains('mapped-secret')));

    final restored = mapper.fromSyncRecord(sync);
    expect(restored.syncDirty, isFalse);
    expect(restored.lastSyncedLogicalTime, sync.logicalTime);
    expect(restored.lastSyncedContentHash, sync.contentHash);
    final decrypted = await recordCrypto.decryptRecord(
      record: restored,
      vaultSecret: vaultSecret,
    );

    expect(decrypted.payload['address'], 'mapped@example.com');
    expect(decrypted.payload['secret'], 'mapped-secret');
  });
}
