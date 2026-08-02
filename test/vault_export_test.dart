import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_export.dart';

void main() {
  test('vault export encrypts and restores vault configuration only', () async {
    const service = VaultExportService();
    final document = VaultDocument.empty()
        .upsertMailbox(
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
        )
        .upsertOAuthProvider(
          const VaultOAuthProviderConfig(
            provider: 'gmail',
            clientId: 'client-id',
            clientSecret: 'client-secret',
          ),
        );

    final encoded = await service.exportDocument(
      document: document,
      password: 'correct horse battery staple',
    );
    expect(encoded, isNot(contains('app-password')));
    expect(encoded, isNot(contains('me@example.com')));

    final restored = await service.importDocument(
      encoded: encoded,
      password: 'correct horse battery staple',
    );
    expect(restored.items.single.secret, 'app-password');
    expect(restored.oauthProviders.single.clientSecret, 'client-secret');
  });

  test('vault import plan identifies mailbox and provider conflicts', () {
    const current = VaultDocument(
      version: 1,
      items: [
        VaultMailboxItem(
          id: 'local-id',
          kind: VaultItemKind.imapSmtp,
          address: 'ME@example.com',
          displayName: 'Local',
          provider: 'imap',
          username: 'me@example.com',
          secret: 'local-secret',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 587,
          useTls: true,
        ),
      ],
      oauthProviders: [
        VaultOAuthProviderConfig(provider: 'google', clientId: 'local-client'),
      ],
    );
    const incoming = VaultDocument(
      version: 1,
      items: [
        VaultMailboxItem(
          id: 'imported-id',
          kind: VaultItemKind.imapSmtp,
          address: 'me@example.com',
          displayName: 'Imported',
          provider: 'imap',
          username: 'me@example.com',
          secret: 'imported-secret',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 587,
          useTls: true,
        ),
      ],
      oauthProviders: [
        VaultOAuthProviderConfig(
          provider: 'gmail',
          clientId: 'imported-client',
        ),
      ],
    );

    final plan = VaultImportPlan.create(current: current, incoming: incoming);
    expect(plan.mailboxConflicts, hasLength(1));
    expect(plan.oauthProviderConflicts, hasLength(1));
    expect(
      plan.merge(VaultImportConflictPolicy.keepLocal).items.single.secret,
      'local-secret',
    );
    expect(
      plan.merge(VaultImportConflictPolicy.replaceLocal).items.single.id,
      'local-id',
    );
    expect(
      plan.merge(VaultImportConflictPolicy.replaceLocal).items.single.secret,
      'imported-secret',
    );
    expect(
      plan
          .merge(VaultImportConflictPolicy.replaceLocal)
          .oauthProviders
          .single
          .clientId,
      'imported-client',
    );
  });

  test('vault export rejects short passwords and invalid format', () async {
    const service = VaultExportService();
    await expectLater(
      service.exportDocument(
        document: VaultDocument.empty(),
        password: 'short',
      ),
      throwsA(isA<VaultExportException>()),
    );
    await expectLater(
      service.importDocument(
        encoded: '{}',
        password: 'correct horse battery staple',
      ),
      throwsA(isA<VaultExportException>()),
    );
  });
}
