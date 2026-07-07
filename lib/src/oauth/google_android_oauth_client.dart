import 'dart:io' as io;

import 'package:flutter/services.dart';

import 'oauth_loopback_client.dart';
import 'oauth_provider.dart';

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
    String clientId = '',
    String? loginHint,
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
    onProgress?.call(OAuthAuthorizationProgress.waitingForAuthorization);
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'authorizeGmail',
      {
        'clientId': clientId,
        'loginHint': loginHint ?? '',
        'scopes': provider.scopes,
      },
    );
    onProgress?.call(OAuthAuthorizationProgress.exchangingToken);
    final result = raw ?? const <String, Object?>{};
    final accessToken = (result['accessToken'] as String? ?? '').trim();
    if (accessToken.isEmpty) {
      throw const OAuthLoopbackException(
        'Google Android authorization did not return an access token.',
      );
    }
    final expiresIn = int.tryParse('${result['expiresIn'] ?? ''}');
    final grantedScopes = _scopeValue(result['grantedScopes']).trim();
    return OAuthTokenSet(
      accessToken: accessToken,
      tokenType: (result['tokenType'] as String? ?? 'Bearer').trim(),
      refreshToken: (result['refreshToken'] as String?)?.trim(),
      expiresIn: expiresIn,
      scope: grantedScopes.isEmpty ? provider.scopes.join(' ') : grantedScopes,
    );
  }

  String _scopeValue(Object? value) {
    if (value is String) return value;
    if (value is Iterable) {
      return value.map((item) => item.toString()).join(' ');
    }
    return '';
  }
}
