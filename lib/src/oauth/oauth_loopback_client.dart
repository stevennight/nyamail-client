import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'oauth_pkce.dart';
import 'oauth_provider.dart';

typedef OpenAuthorizationUrl = Future<void> Function(Uri uri);
typedef OAuthRedirectModeResolver = OAuthAuthorizationRedirectMode Function();

enum OAuthAuthorizationRedirectMode { loopback, browserCallback }

class OAuthMobileRedirectConfig {
  const OAuthMobileRedirectConfig({
    this.scheme = 'app.nyamail.client',
    this.host = '',
    this.path = '/oauth2redirect',
  });

  final String scheme;
  final String host;
  final String path;

  Uri get redirectUri {
    final trimmedHost = host.trim();
    return Uri(
      scheme: scheme.trim(),
      host: trimmedHost.isEmpty ? null : trimmedHost,
      path: _normalizedPath(path),
    );
  }

  bool matches(Uri uri) {
    final expected = redirectUri;
    if (uri.scheme != expected.scheme) return false;
    if (expected.host.isNotEmpty && uri.host != expected.host) return false;
    if (expected.path.isNotEmpty && uri.path != expected.path) return false;
    return true;
  }

  static String _normalizedPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.startsWith('/') ? trimmed : '/$trimmed';
  }
}

abstract interface class OAuthCallbackReceiver {
  Future<Uri> waitForCallback({required Duration timeout});
}

class MethodChannelOAuthCallbackReceiver implements OAuthCallbackReceiver {
  MethodChannelOAuthCallbackReceiver({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('app.nyamail.client/oauth_callback');

  final MethodChannel _channel;
  final List<Uri> _pendingCallbacks = [];
  Completer<Uri>? _waitingCallback;
  bool _initialized = false;

  @override
  Future<Uri> waitForCallback({required Duration timeout}) async {
    _ensureInitialized();
    if (_waitingCallback != null) {
      throw const OAuthLoopbackException(
        'Another OAuth authorization is already waiting for a callback.',
      );
    }

    final initial = await _channel.invokeMethod<String>(
      'takeInitialOAuthRedirect',
    );
    final initialUri = _tryParseUri(initial);
    if (initialUri != null) return initialUri;
    if (_pendingCallbacks.isNotEmpty) {
      return _pendingCallbacks.removeAt(0);
    }

    final completer = Completer<Uri>();
    _waitingCallback = completer;
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waitingCallback, completer)) {
          _waitingCallback = null;
        }
        throw TimeoutException('Timed out waiting for OAuth callback.');
      },
    );
  }

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onOAuthRedirect') return null;
      final uri = _tryParseUri(call.arguments as String?);
      if (uri != null) _handleCallback(uri);
      return null;
    });
  }

  void _handleCallback(Uri uri) {
    final waiter = _waitingCallback;
    if (waiter != null && !waiter.isCompleted) {
      _waitingCallback = null;
      waiter.complete(uri);
      return;
    }
    _pendingCallbacks.add(uri);
  }

  Uri? _tryParseUri(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return Uri.tryParse(trimmed);
  }
}

class OAuthLoopbackClient {
  OAuthLoopbackClient({
    http.Client? httpClient,
    OAuthPkce? pkce,
    OpenAuthorizationUrl? openAuthorizationUrl,
    OAuthCallbackReceiver? callbackReceiver,
    OAuthMobileRedirectConfig mobileRedirectConfig =
        const OAuthMobileRedirectConfig(),
    OAuthRedirectModeResolver? redirectModeResolver,
    Duration timeout = const Duration(minutes: 5),
  }) : _httpClient = httpClient ?? http.Client(),
       _pkce = pkce ?? OAuthPkce(),
       _openAuthorizationUrl =
           openAuthorizationUrl ?? _defaultOpenAuthorizationUrl,
       _callbackReceiver =
           callbackReceiver ?? MethodChannelOAuthCallbackReceiver(),
       _mobileRedirectConfig = mobileRedirectConfig,
       _redirectModeResolver =
           redirectModeResolver ??
           (() =>
               Platform.isAndroid
                   ? OAuthAuthorizationRedirectMode.browserCallback
                   : OAuthAuthorizationRedirectMode.loopback),
       _timeout = timeout;

  final http.Client _httpClient;
  final OAuthPkce _pkce;
  final OpenAuthorizationUrl _openAuthorizationUrl;
  final OAuthCallbackReceiver _callbackReceiver;
  final OAuthMobileRedirectConfig _mobileRedirectConfig;
  final OAuthRedirectModeResolver _redirectModeResolver;
  final Duration _timeout;

  Future<OAuthTokenSet> authorize({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    String? loginHint,
    Uri? mobileRedirectUri,
  }) async {
    return switch (_redirectModeResolver()) {
      OAuthAuthorizationRedirectMode.browserCallback =>
        _authorizeWithBrowserCallback(
          provider: provider,
          clientId: clientId,
          clientSecret: clientSecret,
          loginHint: loginHint,
          redirectUri: mobileRedirectUri ?? _mobileRedirectConfig.redirectUri,
        ),
      OAuthAuthorizationRedirectMode.loopback => _authorizeWithLoopback(
        provider: provider,
        clientId: clientId,
        clientSecret: clientSecret,
        loginHint: loginHint,
      ),
    };
  }

  Future<OAuthTokenSet> _authorizeWithLoopback({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    String? loginHint,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = Uri.parse('http://127.0.0.1:${server.port}/oauth');
      final requestData = _buildAuthorizationRequest(
        provider: provider,
        clientId: clientId,
        loginHint: loginHint,
        redirectUri: redirectUri,
      );

      final requestFuture = server.first.timeout(_timeout);
      final openFuture = _openAuthorizationUrl(requestData.authUri);
      final request = await requestFuture;
      final query = request.uri.queryParameters;
      await _writeBrowserResponse(request, query['error'] == null);
      await openFuture;
      final code = _authorizationCodeFromQuery(
        query,
        expectedState: requestData.state,
      );
      return _exchangeAuthorizationCode(
        provider: provider,
        clientId: clientId,
        clientSecret: clientSecret,
        code: code,
        redirectUri: requestData.redirectUri,
        codeVerifier: requestData.pkce.verifier,
      );
    } finally {
      await server.close(force: true);
    }
  }

  Future<OAuthTokenSet> _authorizeWithBrowserCallback({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    String? loginHint,
    required Uri redirectUri,
  }) async {
    final requestData = _buildAuthorizationRequest(
      provider: provider,
      clientId: clientId,
      loginHint: loginHint,
      redirectUri: redirectUri,
    );
    final callbackFuture = _callbackReceiver.waitForCallback(timeout: _timeout);
    final openFuture = _openAuthorizationUrl(requestData.authUri);
    final callbackUri = await callbackFuture;
    await openFuture;
    final expectedRedirect = OAuthMobileRedirectConfig(
      scheme: redirectUri.scheme,
      host: redirectUri.host,
      path: redirectUri.path,
    );
    if (!expectedRedirect.matches(callbackUri)) {
      throw OAuthLoopbackException(
        'OAuth callback redirect mismatch: ${callbackUri.toString()}',
      );
    }
    final code = _authorizationCodeFromQuery(
      callbackUri.queryParameters,
      expectedState: requestData.state,
    );
    return _exchangeAuthorizationCode(
      provider: provider,
      clientId: clientId,
      clientSecret: clientSecret,
      code: code,
      redirectUri: requestData.redirectUri,
      codeVerifier: requestData.pkce.verifier,
    );
  }

  Future<OAuthTokenSet> refresh({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    required String refreshToken,
  }) async {
    final response = await _httpClient.post(
      provider.tokenEndpoint,
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: _tokenRequestBody({
        'client_id': clientId,
        'client_secret': clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      }),
    );
    return OAuthTokenSet.fromJson(_decodeJson(response));
  }

  Map<String, String> _tokenRequestBody(Map<String, String?> values) {
    return {
      for (final entry in values.entries)
        if (entry.value?.trim().isNotEmpty == true)
          entry.key: entry.value!.trim(),
    };
  }

  Map<String, Object?> _decodeJson(http.Response response) {
    final body =
        response.body.isEmpty
            ? <String, Object?>{}
            : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _tokenRequestErrorMessage(body, response.body);
      throw OAuthLoopbackException('OAuth token request failed: $error');
    }
    return body;
  }

  String _tokenRequestErrorMessage(
    Map<String, Object?> body,
    String responseBody,
  ) {
    final raw =
        (body['error_description'] ?? body['error'] ?? responseBody).toString();
    if (raw.toLowerCase().contains('client_secret is missing')) {
      return 'client_secret is missing. Some OAuth clients, including Google '
          'Desktop clients, require the generated client secret during token '
          'exchange even though desktop and mobile apps cannot keep it truly '
          'secret. Rebuild or rerun NyaMail with that provider client secret '
          'configured, or use a provider/client type that accepts a public '
          'PKCE flow without one.';
    }
    return raw;
  }

  _OAuthAuthorizationRequest _buildAuthorizationRequest({
    required OAuthProviderConfig provider,
    required String clientId,
    required Uri redirectUri,
    String? loginHint,
  }) {
    final pkce = _pkce.createPair();
    final state = _pkce.createState();
    final authUri = provider.authorizationEndpoint.replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri.toString(),
        'scope': provider.scopes.join(' '),
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': pkce.challengeMethod,
        'access_type': 'offline',
        'prompt': 'consent',
        if (loginHint != null && loginHint.trim().isNotEmpty)
          'login_hint': loginHint.trim(),
      },
    );
    return _OAuthAuthorizationRequest(
      authUri: authUri,
      redirectUri: redirectUri,
      state: state,
      pkce: pkce,
    );
  }

  String _authorizationCodeFromQuery(
    Map<String, String> query, {
    required String expectedState,
  }) {
    final returnedState = query['state'] ?? '';
    if (returnedState != expectedState) {
      throw const OAuthLoopbackException('OAuth state mismatch');
    }
    final error = query['error'];
    if (error != null) {
      throw OAuthLoopbackException('OAuth authorization failed: $error');
    }
    final code = query['code'];
    if (code == null || code.isEmpty) {
      throw const OAuthLoopbackException('OAuth authorization code missing');
    }
    return code;
  }

  Future<OAuthTokenSet> _exchangeAuthorizationCode({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    required String code,
    required Uri redirectUri,
    required String codeVerifier,
  }) async {
    final response = await _httpClient.post(
      provider.tokenEndpoint,
      headers: const {'content-type': 'application/x-www-form-urlencoded'},
      body: _tokenRequestBody({
        'client_id': clientId,
        'client_secret': clientSecret,
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri.toString(),
        'code_verifier': codeVerifier,
      }),
    );
    return OAuthTokenSet.fromJson(_decodeJson(response));
  }

  Future<void> _writeBrowserResponse(HttpRequest request, bool success) async {
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write(
        success
            ? '<html><body>NyaMail authorization complete. You can close this window.</body></html>'
            : '<html><body>NyaMail authorization failed. Return to the app.</body></html>',
      );
    await request.response.close();
  }

  static Future<void> _defaultOpenAuthorizationUrl(Uri uri) async {
    final target = uri.toString();
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', target]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [target]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [target]);
      return;
    }
    throw OAuthLoopbackException(
      'Opening a browser is not supported on this platform.',
    );
  }
}

class _OAuthAuthorizationRequest {
  const _OAuthAuthorizationRequest({
    required this.authUri,
    required this.redirectUri,
    required this.state,
    required this.pkce,
  });

  final Uri authUri;
  final Uri redirectUri;
  final String state;
  final OAuthPkcePair pkce;
}

class OAuthTokenSet {
  const OAuthTokenSet({
    required this.accessToken,
    required this.tokenType,
    this.refreshToken,
    this.expiresIn,
    this.scope,
  });

  factory OAuthTokenSet.fromJson(Map<String, Object?> json) {
    final accessToken = json['access_token'] as String? ?? '';
    if (accessToken.isEmpty) {
      throw const OAuthLoopbackException('OAuth access token missing');
    }
    return OAuthTokenSet(
      accessToken: accessToken,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      refreshToken: json['refresh_token'] as String?,
      expiresIn: (json['expires_in'] as num?)?.toInt(),
      scope: json['scope'] as String?,
    );
  }

  final String accessToken;
  final String tokenType;
  final String? refreshToken;
  final int? expiresIn;
  final String? scope;

  Map<String, Object?> toRedactedJson() {
    return {
      'access_token': accessToken.isEmpty ? 'missing' : 'redacted',
      'token_type': tokenType,
      if (refreshToken != null)
        'refresh_token': refreshToken!.isEmpty ? 'missing' : 'redacted',
      if (expiresIn != null) 'expires_in': expiresIn,
      if (scope != null) 'scope': scope,
    };
  }
}

class OAuthLoopbackException implements Exception {
  const OAuthLoopbackException(this.message);

  final String message;

  @override
  String toString() => 'OAuthLoopbackException: $message';
}
