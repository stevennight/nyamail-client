import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_transport.dart';
import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/oauth/oauth_mailbox_builder.dart';
import 'package:nyamail/src/oauth/oauth_provider.dart';
import 'package:nyamail/src/security/vault_document.dart';

void main() {
  test('oauth mailbox item stores token metadata for encrypted vault', () {
    final item = oauthMailboxItem(
      id: 'vault_oauth',
      address: 'me@gmail.com',
      displayName: '',
      provider: oauthProviderConfig('gmail'),
      tokenSet: const OAuthTokenSet(
        accessToken: 'access-token',
        tokenType: 'Bearer',
        refreshToken: 'refresh-token',
        expiresIn: 3600,
        scope: 'https://mail.google.com/',
      ),
      oauthClientId: 'android-client-id',
      oauthClientSecret: 'android-client-secret',
    );

    expect(item.kind, VaultItemKind.oauth);
    expect(item.displayName, 'me@gmail.com');
    expect(item.secret, 'access-token');
    expect(item.refreshToken, 'refresh-token');
    expect(item.tokenExpiresAt, isNotNull);
    expect(item.tokenScope, 'https://mail.google.com/');
    expect(item.oauthClientId, 'android-client-id');
    expect(item.oauthClientSecret, 'android-client-secret');
    expect(item.imapHost, 'imap.gmail.com');
    expect(item.smtpPort, 465);
  });

  test('oauth mailbox item converts to oauth2 transport credential', () {
    final item = oauthMailboxItem(
      id: 'vault_oauth',
      address: 'me@outlook.com',
      displayName: 'Me',
      provider: oauthProviderConfig('outlook'),
      tokenSet: const OAuthTokenSet(
        accessToken: 'access-token',
        tokenType: 'Bearer',
      ),
    );

    final credential = item.toCredential();
    expect(credential.authType, MailboxAuthType.oauth2);
    expect(credential.secret, 'access-token');
    expect(credential.smtpHost, 'smtp-mail.outlook.com');
  });

  test('vault document round trips oauth token metadata', () {
    final expiresAt = DateTime.utc(2026, 7, 1, 12);
    final document = VaultDocument.empty()
        .upsertOAuthProvider(
          const VaultOAuthProviderConfig(
            provider: 'google',
            clientId: 'client-id',
            clientSecret: 'client-secret',
            androidClientId: 'android-client-id',
            androidClientSecret: 'android-client-secret',
            androidRedirectUri: 'app.nyamail.client:/oauth2redirect',
          ),
        )
        .upsertMailbox(
          VaultMailboxItem(
            id: 'vault_oauth',
            kind: VaultItemKind.oauth,
            address: 'me@gmail.com',
            displayName: 'Me',
            provider: 'gmail',
            username: 'me@gmail.com',
            secret: 'access-token',
            refreshToken: 'refresh-token',
            tokenExpiresAt: expiresAt,
            tokenScope: 'https://mail.google.com/',
            oauthClientId: 'android-client-id',
            imapHost: 'imap.gmail.com',
            imapPort: 993,
            smtpHost: 'smtp.gmail.com',
            smtpPort: 465,
            useTls: true,
          ),
        );

    final decoded = VaultDocument.decodePlaintext(document.encodePlaintext());
    final item = decoded.items.single;
    final provider = decoded.oauthProviderFor('gmail');
    expect(item.refreshToken, 'refresh-token');
    expect(item.tokenExpiresAt, expiresAt);
    expect(item.tokenScope, 'https://mail.google.com/');
    expect(item.oauthClientId, 'android-client-id');
    expect(provider?.clientId, 'client-id');
    expect(provider?.clientSecret, 'client-secret');
    expect(provider?.androidClientId, 'android-client-id');
    expect(provider?.androidClientSecret, 'android-client-secret');
    expect(provider?.androidRedirectUri, 'app.nyamail.client:/oauth2redirect');
    expect(decoded.toCredentials().single.authType, MailboxAuthType.oauth2);
  });
}
