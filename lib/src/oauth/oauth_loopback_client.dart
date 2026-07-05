import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'oauth_pkce.dart';
import 'oauth_provider.dart';

typedef OpenAuthorizationUrl = Future<void> Function(Uri uri);

class OAuthLoopbackClient {
  OAuthLoopbackClient({
    http.Client? httpClient,
    OAuthPkce? pkce,
    OpenAuthorizationUrl? openAuthorizationUrl,
    Duration timeout = const Duration(minutes: 5),
  })  : _httpClient = httpClient ?? http.Client(),
        _pkce = pkce ?? OAuthPkce(),
        _openAuthorizationUrl =
            openAuthorizationUrl ?? _defaultOpenAuthorizationUrl,
        _timeout = timeout;

  final http.Client _httpClient;
  final OAuthPkce _pkce;
  final OpenAuthorizationUrl _openAuthorizationUrl;
  final Duration _timeout;

  Future<OAuthTokenSet> authorize({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    String? loginHint,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirectUri = Uri.parse('http://127.0.0.1:${server.port}/oauth');
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

      final requestFuture = server.first.timeout(_timeout);
      final openFuture = _openAuthorizationUrl(authUri);
      final request = await requestFuture;
      final query = request.uri.queryParameters;
      await _writeBrowserResponse(request, query['error'] == null);
      await openFuture;
      final returnedState = query['state'] ?? '';
      if (returnedState != state) {
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

      final response = await _httpClient.post(
        provider.tokenEndpoint,
        headers: const {
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: _tokenRequestBody({
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri.toString(),
          'code_verifier': pkce.verifier,
        }),
      );
      final json = _decodeJson(response);
      return OAuthTokenSet.fromJson(json);
    } finally {
      await server.close(force: true);
    }
  }

  Future<OAuthTokenSet> refresh({
    required OAuthProviderConfig provider,
    required String clientId,
    String? clientSecret,
    required String refreshToken,
  }) async {
    final response = await _httpClient.post(
      provider.tokenEndpoint,
      headers: const {
        'content-type': 'application/x-www-form-urlencoded',
      },
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
    final body = response.body.isEmpty
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
        (body['error_description'] ?? body['error'] ?? responseBody)
            .toString();
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

  Future<void> _writeBrowserResponse(
    HttpRequest request,
    bool success,
  ) async {
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
