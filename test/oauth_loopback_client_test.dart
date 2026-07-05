import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/oauth/oauth_provider.dart';

void main() {
  test('oauth provider presets include mail endpoints and scopes', () {
    final gmail = oauthProviderConfig('gmail');
    expect(gmail.authorizationEndpoint.host, 'accounts.google.com');
    expect(gmail.scopes, contains('https://mail.google.com/'));
    expect(gmail.imapHost, 'imap.gmail.com');

    final outlook = oauthProviderConfig('outlook');
    expect(outlook.scopes, contains('offline_access'));
    expect(
      outlook.scopes,
      contains('https://outlook.office.com/IMAP.AccessAsUser.All'),
    );
    expect(
      outlook.scopes,
      contains('https://outlook.office.com/SMTP.Send'),
    );
  });

  test('loopback client exchanges authorization code with pkce verifier',
      () async {
    final server = await _FakeOAuthServer.start();
    try {
      final provider = OAuthProviderConfig(
        provider: 'test',
        authorizationEndpoint: server.authorizationEndpoint,
        tokenEndpoint: server.tokenEndpoint,
        scopes: const ['mail.read', 'offline_access'],
      );
      final tokenSet = await OAuthLoopbackClient(
        timeout: const Duration(seconds: 5),
        openAuthorizationUrl: (uri) async {
          server.authorizationUri = uri;
          final redirectUri = Uri.parse(uri.queryParameters['redirect_uri']!);
          final state = uri.queryParameters['state']!;
          final response = await http.get(
            redirectUri.replace(queryParameters: {
              'code': 'auth-code',
              'state': state,
            }),
          );
          expect(response.statusCode, 200);
        },
      ).authorize(
        provider: provider,
        clientId: 'client-123',
        loginHint: 'me@example.com',
      );

      expect(tokenSet.accessToken, 'access-token');
      expect(tokenSet.refreshToken, 'refresh-token');
      expect(tokenSet.toRedactedJson()['access_token'], 'redacted');
      expect(server.tokenBody['client_id'], 'client-123');
      expect(server.tokenBody.containsKey('client_secret'), isFalse);
      expect(server.tokenBody['code'], 'auth-code');
      expect(server.tokenBody['grant_type'], 'authorization_code');
      expect(server.tokenBody['code_verifier'], isNotEmpty);
      expect(server.authorizationUri?.queryParameters['code_challenge'],
          isNotEmpty);
      expect(server.authorizationUri?.queryParameters['code_challenge_method'],
          'S256');
      expect(server.authorizationUri?.queryParameters['scope'],
          'mail.read offline_access');
      expect(server.authorizationUri?.queryParameters['login_hint'],
          'me@example.com');
    } finally {
      await server.close();
    }
  });

  test('loopback client sends optional client secret for token requests',
      () async {
    final server = await _FakeOAuthServer.start();
    try {
      final provider = OAuthProviderConfig(
        provider: 'test',
        authorizationEndpoint: server.authorizationEndpoint,
        tokenEndpoint: server.tokenEndpoint,
        scopes: const ['mail.read'],
      );
      await OAuthLoopbackClient(
        timeout: const Duration(seconds: 5),
        openAuthorizationUrl: (uri) async {
          final redirectUri = Uri.parse(uri.queryParameters['redirect_uri']!);
          final state = uri.queryParameters['state']!;
          await http.get(
            redirectUri.replace(queryParameters: {
              'code': 'auth-code',
              'state': state,
            }),
          );
        },
      ).authorize(
        provider: provider,
        clientId: 'desktop-client-id',
        clientSecret: 'desktop-client-secret',
      );

      expect(server.tokenBody['client_secret'], 'desktop-client-secret');
    } finally {
      await server.close();
    }
  });

  test('loopback client sends optional client secret for refresh requests',
      () async {
    final server = await _FakeOAuthServer.start();
    try {
      final provider = OAuthProviderConfig(
        provider: 'test',
        authorizationEndpoint: server.authorizationEndpoint,
        tokenEndpoint: server.tokenEndpoint,
        scopes: const ['mail.read'],
      );
      await OAuthLoopbackClient().refresh(
        provider: provider,
        clientId: 'desktop-client-id',
        clientSecret: 'desktop-client-secret',
        refreshToken: 'refresh-token',
      );

      expect(server.tokenBody['client_secret'], 'desktop-client-secret');
      expect(server.tokenBody['grant_type'], 'refresh_token');
    } finally {
      await server.close();
    }
  });

  test('loopback client rejects state mismatch', () async {
    final server = await _FakeOAuthServer.start();
    try {
      final provider = OAuthProviderConfig(
        provider: 'test',
        authorizationEndpoint: server.authorizationEndpoint,
        tokenEndpoint: server.tokenEndpoint,
        scopes: const ['mail.read'],
      );

      await expectLater(
        OAuthLoopbackClient(
          timeout: const Duration(seconds: 5),
          openAuthorizationUrl: (uri) async {
            final redirectUri = Uri.parse(uri.queryParameters['redirect_uri']!);
            await http.get(
              redirectUri.replace(queryParameters: {
                'code': 'auth-code',
                'state': 'wrong-state',
              }),
            );
          },
        ).authorize(provider: provider, clientId: 'client-123'),
        throwsA(isA<OAuthLoopbackException>()),
      );
    } finally {
      await server.close();
    }
  });

  test('loopback client explains missing client secret errors', () async {
    final server = await _FakeOAuthServer.start(
      tokenStatusCode: 400,
      tokenResponse: const {
        'error': 'invalid_request',
        'error_description': 'client_secret is missing.',
      },
    );
    try {
      final provider = OAuthProviderConfig(
        provider: 'test',
        authorizationEndpoint: server.authorizationEndpoint,
        tokenEndpoint: server.tokenEndpoint,
        scopes: const ['mail.read'],
      );

      await expectLater(
        OAuthLoopbackClient(
          timeout: const Duration(seconds: 5),
          openAuthorizationUrl: (uri) async {
            final redirectUri = Uri.parse(uri.queryParameters['redirect_uri']!);
            final state = uri.queryParameters['state']!;
            await http.get(
              redirectUri.replace(queryParameters: {
                'code': 'auth-code',
                'state': state,
              }),
            );
          },
        ).authorize(provider: provider, clientId: 'web-client-123'),
        throwsA(
          isA<OAuthLoopbackException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Google Desktop clients'),
              contains('client secret'),
              contains('configured'),
            ),
          ),
        ),
      );
    } finally {
      await server.close();
    }
  });
}

class _FakeOAuthServer {
  _FakeOAuthServer._(
    this._server, {
    required this.tokenStatusCode,
    required this.tokenResponse,
  });

  final HttpServer _server;
  final int tokenStatusCode;
  final Map<String, Object?> tokenResponse;
  Uri? authorizationUri;
  Map<String, String> tokenBody = const {};

  Uri get authorizationEndpoint =>
      Uri.parse('http://127.0.0.1:${_server.port}/authorize');
  Uri get tokenEndpoint => Uri.parse('http://127.0.0.1:${_server.port}/token');

  static Future<_FakeOAuthServer> start({
    int tokenStatusCode = 200,
    Map<String, Object?> tokenResponse = const {
      'access_token': 'access-token',
      'refresh_token': 'refresh-token',
      'token_type': 'Bearer',
      'expires_in': 3600,
      'scope': 'mail.read offline_access',
    },
  }) async {
    final server = _FakeOAuthServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      tokenStatusCode: tokenStatusCode,
      tokenResponse: tokenResponse,
    );
    unawaited(server._serve());
    return server;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      if (request.uri.path == '/token') {
        final body = await utf8.decoder.bind(request).join();
        tokenBody = Uri.splitQueryString(body);
        request.response
          ..statusCode = tokenStatusCode
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(tokenResponse));
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    }
  }
}
