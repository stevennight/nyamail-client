import 'dart:io' as io;

import 'package:flutter/services.dart';

import 'oauth_loopback_client.dart';
import 'oauth_provider.dart';

typedef GoogleServerAuthorizationCodeExchange =
    Future<OAuthTokenSet> Function({
      required OAuthProviderConfig provider,
      required String clientId,
      String? clientSecret,
      required String code,
    });

class GoogleAndroidOAuthClient {
  const GoogleAndroidOAuthClient({
    MethodChannel channel = const MethodChannel(
      'com.nyatori.nyamail/google_authorization',
    ),
    bool? isSupportedOverride,
  }) : _channel = channel,
       _isSupportedOverride = isSupportedOverride;

  final MethodChannel _channel;
  final bool? _isSupportedOverride;

  bool get isSupported => _isSupportedOverride ?? io.Platform.isAndroid;

  Future<OAuthTokenSet> authorize({
    required OAuthProviderConfig provider,
    required String androidClientId,
    required String serverClientId,
    required String serverClientSecret,
    required GoogleServerAuthorizationCodeExchange
    exchangeServerAuthorizationCode,
    String? loginHint,
    bool forceAccountPicker = false,
    bool forceRefreshToken = true,
    OAuthAuthorizationProgressCallback? onProgress,
  }) async {
    if (!isSupported) {
      throw const OAuthLoopbackException(
        'Google Android authorization is only available on Android.',
      );
    }
    if (provider.provider != 'gmail') {
      throw OAuthLoopbackException(
        'Google Android authorization does not support ${provider.provider}.',
      );
    }
    if (androidClientId.trim().isEmpty) {
      throw const OAuthLoopbackException(
        'Google Android client ID is not configured.',
      );
    }
    if (serverClientId.trim().isEmpty) {
      throw const OAuthLoopbackException(
        'Google Web client ID is not configured for Android offline access.',
      );
    }
    if (serverClientSecret.trim().isEmpty) {
      throw const OAuthLoopbackException(
        'Google Web client secret is not configured for Android offline access.',
      );
    }
    onProgress?.call(OAuthAuthorizationProgress.waitingForAuthorization);
    final raw = await _channel
        .invokeMapMethod<String, Object?>('authorizeGmail', {
          'androidClientId': androidClientId.trim(),
          'serverClientId': serverClientId.trim(),
          'loginHint': loginHint ?? '',
          'forceAccountPicker': forceAccountPicker,
          'forceRefreshToken': forceRefreshToken,
          'scopes': provider.scopes,
        });
    onProgress?.call(OAuthAuthorizationProgress.exchangingToken);
    final result = raw ?? const <String, Object?>{};
    final expectedEmail = loginHint?.trim() ?? '';
    final accountEmail = (result['accountEmail'] as String? ?? '').trim();
    if (expectedEmail.isNotEmpty &&
        accountEmail.isNotEmpty &&
        expectedEmail.toLowerCase() != accountEmail.toLowerCase()) {
      throw OAuthLoopbackException(
        'Google authorization returned $accountEmail, but this mailbox is '
        '$expectedEmail. Choose the same Google account as the mailbox address.',
      );
    }
    final serverAuthCode = (result['serverAuthCode'] as String? ?? '').trim();
    if (serverAuthCode.isEmpty) {
      throw const OAuthLoopbackException(
        'Google Android authorization did not return a server authorization '
        'code. Verify that the Web client belongs to the same Google Cloud '
        'project as the Android client.',
      );
    }
    final tokenSet = await exchangeServerAuthorizationCode(
      provider: provider,
      clientId: serverClientId.trim(),
      clientSecret: serverClientSecret.trim(),
      code: serverAuthCode,
    );
    if (tokenSet.refreshToken?.trim().isEmpty ?? true) {
      throw const OAuthLoopbackException(
        'Google token exchange did not return a refresh token. Revoke the '
        'existing grant and authorize again.',
      );
    }
    return tokenSet;
  }
}
