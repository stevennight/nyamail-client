import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_transport.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';

void main() {
  test('vault document round trips mailbox credentials', () async {
    const crypto = VaultCrypto();
    final document = VaultDocument.empty().upsertMailbox(
      const VaultMailboxItem(
        id: 'vault_1',
        kind: VaultItemKind.imapSmtp,
        address: 'me@example.com',
        displayName: 'Me',
        provider: 'imap',
        username: 'me@example.com',
        secret: 'app-password',
        imapHost: 'imap.example.com',
        imapPort: 993,
        smtpHost: 'smtp.example.com',
        smtpPort: 465,
        useTls: true,
      ),
    );

    final blob = await crypto.encryptDocument(
      document: document,
      email: 'owner@example.com',
      password: 'secret',
    );
    final decrypted = await crypto.decryptDocument(
      blob: blob,
      email: 'owner@example.com',
      password: 'secret',
    );

    expect(blob.algorithm, VaultCrypto.algorithm);
    expect(blob.kdf, VaultCrypto.kdfName);
    expect(blob.metadata['server_plaintext'], 'false');
    expect(decrypted.items, hasLength(1));
    expect(decrypted.toCredentials().single.imapHost, 'imap.example.com');
  });

  test(
    'vault document exposes oauth mailbox credentials as oauth2 transport',
    () {
      final document = VaultDocument.empty().upsertMailbox(
        const VaultMailboxItem(
          id: 'vault_oauth',
          kind: VaultItemKind.oauth,
          address: 'me@gmail.com',
          displayName: 'Me',
          provider: 'gmail',
          username: 'me@gmail.com',
          secret: 'access-token',
          imapHost: 'imap.gmail.com',
          imapPort: 993,
          smtpHost: 'smtp.gmail.com',
          smtpPort: 465,
          useTls: true,
        ),
      );

      final credential = document.toCredentials().single;
      expect(credential.authType, MailboxAuthType.oauth2);
      expect(credential.secret, 'access-token');
    },
  );

  test('vault document encrypts oauth provider client settings', () async {
    const crypto = VaultCrypto();
    final document = VaultDocument.empty().upsertOAuthProvider(
      const VaultOAuthProviderConfig(
        provider: 'gmail',
        clientId: 'google-client-id',
        clientSecret: 'google-client-secret',
      ),
    );

    final blob = await crypto.encryptDocument(
      document: document,
      email: 'owner@example.com',
      password: 'secret',
    );
    final decrypted = await crypto.decryptDocument(
      blob: blob,
      email: 'owner@example.com',
      password: 'secret',
    );

    expect(blob.ciphertext, isNot(contains('google-client-secret')));
    expect(decrypted.oauthProviderFor('google')?.clientId, 'google-client-id');
    expect(
      decrypted.oauthProviderFor('gmail')?.clientSecret,
      'google-client-secret',
    );
  });

  test('vault document removes mailbox credentials by vault item id', () {
    final document = VaultDocument.empty()
        .upsertMailbox(
          const VaultMailboxItem(
            id: 'vault_keep',
            kind: VaultItemKind.imapSmtp,
            address: 'keep@example.com',
            displayName: 'Keep',
            provider: 'imap',
            username: 'keep@example.com',
            secret: 'keep-secret',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            useTls: true,
          ),
        )
        .upsertMailbox(
          const VaultMailboxItem(
            id: 'vault_remove',
            kind: VaultItemKind.oauth,
            address: 'remove@example.com',
            displayName: 'Remove',
            provider: 'gmail',
            username: 'remove@example.com',
            secret: 'access-token',
            refreshToken: 'refresh-token',
            imapHost: 'imap.gmail.com',
            imapPort: 993,
            smtpHost: 'smtp.gmail.com',
            smtpPort: 465,
            useTls: true,
          ),
        );

    final updated = document.removeMailbox('vault_remove');

    expect(updated.items, hasLength(1));
    expect(updated.items.single.id, 'vault_keep');
    expect(updated.toCredentials().single.address, 'keep@example.com');
  });

  test('vault rejects wrong password', () async {
    const crypto = VaultCrypto();
    final blob = await crypto.encryptDocument(
      document: VaultDocument.empty().upsertMailbox(
        const VaultMailboxItem(
          id: 'vault_1',
          kind: VaultItemKind.imapSmtp,
          address: 'me@example.com',
          displayName: 'Me',
          provider: 'imap',
          username: 'me@example.com',
          secret: 'app-password',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          useTls: true,
        ),
      ),
      email: 'owner@example.com',
      password: 'secret',
    );

    await expectLater(
      crypto.decryptDocument(
        blob: blob,
        email: 'owner@example.com',
        password: 'wrong',
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test(
    'vault can use a transferable vault secret instead of login password',
    () async {
      const crypto = VaultCrypto();
      final secret = crypto.newVaultSecret();
      final blob = await crypto.encryptDocument(
        document: VaultDocument.empty().upsertMailbox(
          const VaultMailboxItem(
            id: 'vault_2',
            kind: VaultItemKind.imapSmtp,
            address: 'team@example.com',
            displayName: 'Team',
            provider: 'imap',
            username: 'team@example.com',
            secret: 'team-app-password',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            useTls: true,
          ),
        ),
        email: 'owner@example.com',
        password: 'unused-login-password',
        vaultSecret: secret,
      );

      final decrypted = await crypto.decryptDocument(
        blob: blob,
        email: 'owner@example.com',
        password: '',
        vaultSecret: secret,
      );

      expect(blob.kdf, VaultCrypto.directKeyName);
      expect(decrypted.toCredentials().single.secret, 'team-app-password');
      await expectLater(
        crypto.decryptDocument(
          blob: blob,
          email: 'owner@example.com',
          password: 'unused-login-password',
        ),
        throwsA(isA<VaultCryptoException>()),
      );
    },
  );

  test('vault secret can be wrapped by a vault password', () async {
    const crypto = VaultCrypto();
    final secret = crypto.newVaultSecret();

    final envelope = await crypto.wrapVaultSecret(
      vaultSecret: secret,
      password: 'correct horse battery staple',
    );
    final unwrapped = await crypto.unwrapVaultSecret(
      blob: envelope,
      password: 'correct horse battery staple',
    );

    expect(envelope.algorithm, VaultCrypto.vaultSecretWrapAlgorithm);
    expect(envelope.kdf, VaultCrypto.kdfName);
    expect(envelope.ciphertext, isNot(contains(secret)));
    expect(unwrapped, secret);
  });

  test('vault secret wrapper rejects wrong password', () async {
    const crypto = VaultCrypto();
    final envelope = await crypto.wrapVaultSecret(
      vaultSecret: crypto.newVaultSecret(),
      password: 'correct horse battery staple',
    );

    await expectLater(
      crypto.unwrapVaultSecret(blob: envelope, password: 'wrong-password'),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('vault secret can be wrapped for system quick unlock', () async {
    const crypto = VaultCrypto();
    final secret = crypto.newVaultSecret();
    final quickKey = crypto.newQuickUnlockKey();

    final envelope = await crypto.wrapVaultSecretForQuickUnlock(
      vaultSecret: secret,
      quickUnlockKey: quickKey,
      profileId: 'local-vault-1',
    );
    final unwrapped = await crypto.unwrapVaultSecretForQuickUnlock(
      blob: envelope,
      quickUnlockKey: quickKey,
      profileId: 'local-vault-1',
    );

    expect(envelope.algorithm, VaultCrypto.quickUnlockWrapAlgorithm);
    expect(envelope.kdf, VaultCrypto.quickUnlockKeyName);
    expect(envelope.ciphertext, isNot(contains(secret)));
    expect(unwrapped, secret);
  });

  test('quick unlock wrapper rejects the wrong quick key', () async {
    const crypto = VaultCrypto();
    final envelope = await crypto.wrapVaultSecretForQuickUnlock(
      vaultSecret: crypto.newVaultSecret(),
      quickUnlockKey: crypto.newQuickUnlockKey(),
      profileId: 'local-vault-1',
    );

    await expectLater(
      crypto.unwrapVaultSecretForQuickUnlock(
        blob: envelope,
        quickUnlockKey: crypto.newQuickUnlockKey(),
        profileId: 'local-vault-1',
      ),
      throwsA(isA<VaultCryptoException>()),
    );
  });
}
