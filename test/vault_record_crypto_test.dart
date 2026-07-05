import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/security/vault_records.dart';

void main() {
  test('vault record crypto encrypts payloads independently', () async {
    const recordCrypto = VaultRecordCrypto();
    const vaultCrypto = VaultCrypto();
    final vaultSecret = vaultCrypto.newVaultSecret();
    final records = VaultRecordSet.fromVaultDocument(
      VaultDocument.empty()
          .upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.oauth,
              address: 'secret-mailbox@example.com',
              displayName: 'Secret mailbox',
              provider: 'gmail',
              username: 'secret-mailbox@example.com',
              secret: 'access-token-plain',
              refreshToken: 'refresh-token-plain',
              imapHost: 'imap.gmail.com',
              imapPort: 993,
              smtpHost: 'smtp.gmail.com',
              smtpPort: 587,
              useTls: true,
            ),
          )
          .upsertOAuthProvider(
            const VaultOAuthProviderConfig(
              provider: 'gmail',
              clientId: 'client-id-plain',
              clientSecret: 'client-secret-plain',
            ),
          ),
      updatedAt: DateTime.utc(2026, 1, 2),
    );

    final encrypted = await recordCrypto.encryptRecordSet(
      records: records,
      vaultSecret: vaultSecret,
    );
    final raw = jsonEncode(encrypted.toJson());

    expect(encrypted.records, hasLength(2));
    expect(raw, isNot(contains('secret-mailbox@example.com')));
    expect(raw, isNot(contains('access-token-plain')));
    expect(raw, isNot(contains('refresh-token-plain')));
    expect(raw, isNot(contains('client-secret-plain')));
    expect(encrypted.records.first.blob.metadata['server_plaintext'], 'false');

    final decrypted = await recordCrypto.decryptRecordSet(
      records: encrypted,
      vaultSecret: vaultSecret,
    );
    final document = decrypted.toVaultDocument();

    expect(document.items.single.address, 'secret-mailbox@example.com');
    expect(document.items.single.refreshToken, 'refresh-token-plain');
    expect(document.oauthProviders.single.clientSecret, 'client-secret-plain');
  });

  test('vault record crypto rejects the wrong vault secret', () async {
    const recordCrypto = VaultRecordCrypto();
    const vaultCrypto = VaultCrypto();
    final encrypted = await recordCrypto.encryptRecordSet(
      records: VaultRecordSet.fromVaultDocument(
        VaultDocument.empty().upsertOAuthProvider(
          const VaultOAuthProviderConfig(
            provider: 'gmail',
            clientId: 'client-id',
          ),
        ),
      ),
      vaultSecret: vaultCrypto.newVaultSecret(),
    );

    await expectLater(
      recordCrypto.decryptRecordSet(
        records: encrypted,
        vaultSecret: vaultCrypto.newVaultSecret(),
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });
}
