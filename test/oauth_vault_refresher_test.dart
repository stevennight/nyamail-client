import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/oauth/oauth_provider.dart';
import 'package:nyamail/src/oauth/oauth_vault_refresher.dart';
import 'package:nyamail/src/security/vault_document.dart';

void main() {
  test('refreshes expiring oauth vault items', () async {
    final now = DateTime.utc(2026, 7, 1, 12);
    final document = VaultDocument(
      version: 1,
      oauthProviders: const [
        VaultOAuthProviderConfig(
          provider: 'gmail',
          clientId: 'client-id',
          clientSecret: 'client-secret',
        ),
      ],
      items: [
        _oauthItem(
          secret: 'old-access-token',
          refreshToken: 'refresh-token',
          tokenExpiresAt: now.add(const Duration(minutes: 2)),
        ),
      ],
    );

    final result = await OAuthVaultRefresher(
      clock: () => now,
      refreshTokens: ({
        required OAuthProviderConfig provider,
        required String clientId,
        String? clientSecret,
        required String refreshToken,
      }) async {
        expect(provider.provider, 'gmail');
        expect(clientId, 'client-id');
        expect(clientSecret, 'client-secret');
        expect(refreshToken, 'refresh-token');
        return const OAuthTokenSet(
          accessToken: 'new-access-token',
          tokenType: 'Bearer',
          expiresIn: 3600,
          scope: 'https://mail.google.com/',
        );
      },
    ).refreshExpiring(
      document: document,
      clientIdForProvider: (_) => 'client-id',
      clientSecretForProvider: (_) => 'client-secret',
    );

    final item = result.document.items.single;
    expect(result.changed, isTrue);
    expect(result.refreshedCount, 1);
    expect(result.failures, isEmpty);
    expect(item.secret, 'new-access-token');
    expect(item.refreshToken, 'refresh-token');
    expect(item.tokenExpiresAt, now.add(const Duration(hours: 1)));
    expect(item.tokenScope, 'https://mail.google.com/');
    expect(
      result.document.oauthProviderFor('google')?.clientSecret,
      'client-secret',
    );
  });

  test('skips oauth items that are not near expiry', () async {
    final now = DateTime.utc(2026, 7, 1, 12);
    var refreshCalled = false;
    final document = VaultDocument(
      version: 1,
      items: [
        _oauthItem(
          secret: 'current-access-token',
          refreshToken: 'refresh-token',
          tokenExpiresAt: now.add(const Duration(hours: 2)),
        ),
      ],
    );

    final result = await OAuthVaultRefresher(
      clock: () => now,
      refreshTokens: ({
        required OAuthProviderConfig provider,
        required String clientId,
        String? clientSecret,
        required String refreshToken,
      }) async {
        refreshCalled = true;
        return const OAuthTokenSet(accessToken: 'unused', tokenType: 'Bearer');
      },
    ).refreshExpiring(
      document: document,
      clientIdForProvider: (_) => 'client-id',
    );

    expect(result.changed, isFalse);
    expect(result.document, same(document));
    expect(refreshCalled, isFalse);
  });

  test('records a failure when client id is missing', () async {
    final now = DateTime.utc(2026, 7, 1, 12);
    final document = VaultDocument(
      version: 1,
      items: [
        _oauthItem(
          secret: 'old-access-token',
          refreshToken: 'refresh-token',
          tokenExpiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
    );

    final result = await OAuthVaultRefresher(
      clock: () => now,
      refreshTokens: ({
        required OAuthProviderConfig provider,
        required String clientId,
        String? clientSecret,
        required String refreshToken,
      }) async {
        throw StateError('should not refresh');
      },
    ).refreshExpiring(document: document, clientIdForProvider: (_) => '');

    expect(result.changed, isFalse);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.address, 'me@gmail.com');
    expect(result.document.items.single.secret, 'old-access-token');
  });
}

VaultMailboxItem _oauthItem({
  required String secret,
  required String refreshToken,
  required DateTime tokenExpiresAt,
}) {
  return VaultMailboxItem(
    id: 'vault_oauth',
    kind: VaultItemKind.oauth,
    address: 'me@gmail.com',
    displayName: 'Me',
    provider: 'gmail',
    username: 'me@gmail.com',
    secret: secret,
    refreshToken: refreshToken,
    tokenExpiresAt: tokenExpiresAt,
    tokenScope: '',
    imapHost: 'imap.gmail.com',
    imapPort: 993,
    smtpHost: 'smtp.gmail.com',
    smtpPort: 465,
    useTls: true,
  );
}
