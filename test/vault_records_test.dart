import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_records.dart';

void main() {
  test('vault document migrates to record set and back', () {
    final updatedAt = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final document = VaultDocument.empty()
        .upsertMailbox(
          const VaultMailboxItem(
            id: 'mail-1',
            kind: VaultItemKind.oauth,
            address: 'me@example.com',
            displayName: 'Me',
            provider: 'gmail',
            username: 'me@example.com',
            secret: 'access-token',
            refreshToken: 'refresh-token',
            tokenScope: 'scope',
            imapHost: 'imap.gmail.com',
            imapPort: 993,
            smtpHost: 'smtp.gmail.com',
            smtpPort: 587,
            useTls: true,
          ),
        )
        .upsertOAuthProvider(
          const VaultOAuthProviderConfig(
            provider: 'google',
            clientId: 'client-id',
            clientSecret: 'client-secret',
          ),
        );

    final records = VaultRecordSet.fromVaultDocument(
      document,
      updatedAt: updatedAt,
    );

    expect(records.records, hasLength(2));
    expect(records.records.first.type, VaultRecordTypes.mailAccount);
    expect(records.records.first.updatedAt, updatedAt);
    expect(records.records.last.id, 'oauth_provider:gmail');

    final restored = records.toVaultDocument();
    expect(restored.items.single.address, 'me@example.com');
    expect(restored.items.single.refreshToken, 'refresh-token');
    expect(restored.oauthProviders.single.provider, 'gmail');
    expect(restored.oauthProviders.single.clientSecret, 'client-secret');
  });

  test('deleted vault records stay as tombstones outside document view', () {
    final document = VaultDocument.empty().upsertMailbox(
      const VaultMailboxItem(
        id: 'mail-1',
        kind: VaultItemKind.imapSmtp,
        address: 'me@example.com',
        displayName: 'Me',
        provider: 'imap',
        username: 'me@example.com',
        secret: 'app-password',
        imapHost: 'imap.example.com',
        imapPort: 993,
        smtpHost: 'smtp.example.com',
        smtpPort: 587,
        useTls: true,
      ),
    );

    final deleted = VaultRecordSet.fromVaultDocument(
      document,
    ).markDeleted(id: 'mail-1', deletedAt: DateTime.utc(2026, 2, 3));

    expect(deleted.records.single.deleted, isTrue);
    expect(deleted.records.single.payload, isEmpty);
    expect(deleted.records.single.version, 2);
    expect(deleted.toVaultDocument().items, isEmpty);
  });

  test('vault record set round trips json plaintext', () {
    final records = VaultRecordSet.fromVaultDocument(
      VaultDocument.empty().upsertOAuthProvider(
        const VaultOAuthProviderConfig(
          provider: 'outlook',
          clientId: 'client-id',
        ),
      ),
      updatedAt: DateTime.utc(2026, 3, 4),
    );

    final decoded = VaultRecordSet.decodePlaintext(records.encodePlaintext());

    expect(decoded.records.single.id, 'oauth_provider:outlook');
    expect(
      decoded.toVaultDocument().oauthProviders.single.clientId,
      'client-id',
    );
  });
}
