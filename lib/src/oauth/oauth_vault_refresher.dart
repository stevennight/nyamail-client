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

typedef OAuthAccessTokenReauthorize =
    Future<OAuthTokenSet> Function({
      required OAuthProviderConfig provider,
      required String clientId,
      String? clientSecret,
      required String loginHint,
    });

class OAuthVaultRefresher {
  OAuthVaultRefresher({
    required OAuthTokenRefresh refreshTokens,
    OAuthAccessTokenReauthorize? reauthorizeAccessToken,
    Duration refreshBefore = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _refreshTokens = refreshTokens,
       _reauthorizeAccessToken = reauthorizeAccessToken,
       _refreshBefore = refreshBefore,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final OAuthTokenRefresh _refreshTokens;
  final OAuthAccessTokenReauthorize? _reauthorizeAccessToken;
  final Duration _refreshBefore;
  final DateTime Function() _clock;

  Future<OAuthVaultRefreshResult> refreshExpiring({
    required VaultDocument document,
    required String Function(String provider) clientIdForProvider,
    String Function(String provider) clientSecretForProvider =
        _emptyOAuthClientSecret,
    bool force = false,
    Set<String>? itemIds,
  }) async {
    final now = _clock().toUtc();
    final threshold = now.add(_refreshBefore);
    final nextItems = <VaultMailboxItem>[];
    final failures = <OAuthVaultRefreshFailure>[];
    final refreshedItemIds = <String>{};
    var refreshedCount = 0;

    for (final item in document.items) {
      var next = item;
      if ((itemIds == null || itemIds.contains(item.id)) &&
          _shouldRefresh(item, threshold, force: force)) {
        final clientId =
            item.oauthClientId.trim().isNotEmpty
                ? item.oauthClientId.trim()
                : clientIdForProvider(item.provider).trim();
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
            final clientSecret =
                item.oauthClientId.trim().isNotEmpty
                    ? item.oauthClientSecret
                    : clientSecretForProvider(item.provider);
            final tokenSet =
                item.refreshToken.isNotEmpty
                    ? await _refreshTokens(
                      provider: provider,
                      clientId: clientId,
                      clientSecret: clientSecret,
                      refreshToken: item.refreshToken,
                    )
                    : await _reauthorizeAccessToken!(
                      provider: provider,
                      clientId: clientId,
                      clientSecret: clientSecret,
                      loginHint: item.address,
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
            refreshedItemIds.add(item.id);
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
      refreshedItemIds: refreshedItemIds,
      failures: failures,
    );
  }

  bool _shouldRefresh(
    VaultMailboxItem item,
    DateTime threshold, {
    required bool force,
  }) {
    if (item.kind != VaultItemKind.oauth) {
      return false;
    }
    if (item.refreshToken.isEmpty && _reauthorizeAccessToken == null) {
      return false;
    }
    if (force) return true;
    if (item.secret.isEmpty) return true;
    final expiresAt = item.tokenExpiresAt;
    if (expiresAt == null) return true;
    return !expiresAt.toUtc().isAfter(threshold);
  }
}

String _emptyOAuthClientSecret(String provider) => '';

class OAuthVaultRefreshResult {
  const OAuthVaultRefreshResult({
    required this.document,
    required this.refreshedCount,
    this.refreshedItemIds = const <String>{},
    this.failures = const [],
  });

  final VaultDocument document;
  final int refreshedCount;
  final Set<String> refreshedItemIds;
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
