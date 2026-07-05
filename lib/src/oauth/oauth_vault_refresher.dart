import '../security/vault_document.dart';
import 'oauth_loopback_client.dart';
import 'oauth_provider.dart';

typedef OAuthTokenRefresh =
    Future<OAuthTokenSet> Function({
      required OAuthProviderConfig provider,
      required String clientId,
      String? clientSecret,
      required String refreshToken,
    });

class OAuthVaultRefresher {
  OAuthVaultRefresher({
    required OAuthTokenRefresh refreshTokens,
    Duration refreshBefore = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _refreshTokens = refreshTokens,
       _refreshBefore = refreshBefore,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final OAuthTokenRefresh _refreshTokens;
  final Duration _refreshBefore;
  final DateTime Function() _clock;

  Future<OAuthVaultRefreshResult> refreshExpiring({
    required VaultDocument document,
    required String Function(String provider) clientIdForProvider,
    String Function(String provider) clientSecretForProvider =
        _emptyOAuthClientSecret,
  }) async {
    final now = _clock().toUtc();
    final threshold = now.add(_refreshBefore);
    final nextItems = <VaultMailboxItem>[];
    final failures = <OAuthVaultRefreshFailure>[];
    var refreshedCount = 0;

    for (final item in document.items) {
      var next = item;
      if (_shouldRefresh(item, threshold)) {
        final clientId = clientIdForProvider(item.provider).trim();
        if (clientId.isEmpty) {
          failures.add(
            OAuthVaultRefreshFailure(
              itemId: item.id,
              address: item.address,
              message:
                  'OAuth client id is not configured for ${item.provider}.',
            ),
          );
        } else {
          try {
            final provider = oauthProviderConfig(item.provider);
            final tokenSet = await _refreshTokens(
              provider: provider,
              clientId: clientId,
              clientSecret: clientSecretForProvider(item.provider),
              refreshToken: item.refreshToken,
            );
            next = item.copyWith(
              secret: tokenSet.accessToken,
              refreshToken:
                  tokenSet.refreshToken?.isNotEmpty == true
                      ? tokenSet.refreshToken
                      : item.refreshToken,
              tokenExpiresAt:
                  tokenSet.expiresIn == null
                      ? item.tokenExpiresAt
                      : now.add(Duration(seconds: tokenSet.expiresIn!)),
              tokenScope: tokenSet.scope ?? item.tokenScope,
            );
            refreshedCount++;
          } catch (error) {
            failures.add(
              OAuthVaultRefreshFailure(
                itemId: item.id,
                address: item.address,
                message: error.toString(),
              ),
            );
          }
        }
      }
      nextItems.add(next);
    }

    return OAuthVaultRefreshResult(
      document:
          refreshedCount == 0 ? document : document.copyWith(items: nextItems),
      refreshedCount: refreshedCount,
      failures: failures,
    );
  }

  bool _shouldRefresh(VaultMailboxItem item, DateTime threshold) {
    if (item.kind != VaultItemKind.oauth || item.refreshToken.isEmpty) {
      return false;
    }
    if (item.secret.isEmpty) return true;
    final expiresAt = item.tokenExpiresAt;
    return expiresAt != null && !expiresAt.toUtc().isAfter(threshold);
  }
}

String _emptyOAuthClientSecret(String provider) => '';

class OAuthVaultRefreshResult {
  const OAuthVaultRefreshResult({
    required this.document,
    required this.refreshedCount,
    this.failures = const [],
  });

  final VaultDocument document;
  final int refreshedCount;
  final List<OAuthVaultRefreshFailure> failures;

  bool get changed => refreshedCount > 0;
}

class OAuthVaultRefreshFailure {
  const OAuthVaultRefreshFailure({
    required this.itemId,
    required this.address,
    required this.message,
  });

  final String itemId;
  final String address;
  final String message;
}
