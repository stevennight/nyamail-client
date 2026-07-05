import '../security/vault_document.dart';
import 'oauth_loopback_client.dart';
import 'oauth_provider.dart';

VaultMailboxItem oauthMailboxItem({
  required String id,
  required String address,
  required String displayName,
  required OAuthProviderConfig provider,
  required OAuthTokenSet tokenSet,
}) {
  return VaultMailboxItem(
    id: id,
    kind: VaultItemKind.oauth,
    address: address,
    displayName: displayName.trim().isEmpty ? address : displayName.trim(),
    provider: provider.provider,
    username: address,
    secret: tokenSet.accessToken,
    refreshToken: tokenSet.refreshToken ?? '',
    tokenExpiresAt: tokenSet.expiresIn == null
        ? null
        : DateTime.now().toUtc().add(Duration(seconds: tokenSet.expiresIn!)),
    tokenScope: tokenSet.scope ?? provider.scopes.join(' '),
    imapHost: provider.imapHost,
    imapPort: provider.imapPort,
    smtpHost: provider.smtpHost,
    smtpPort: provider.smtpPort,
    useTls: true,
  );
}
