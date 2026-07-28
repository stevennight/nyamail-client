import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/oauth/google_android_oauth_client.dart';
import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/oauth/oauth_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'android google client delegates authorization to native channel',
    () async {
      const channel = MethodChannel('test_google_authorization');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return <String, Object?>{
          'serverAuthCode': 'server-auth-code',
          'accountEmail': 'me@gmail.com',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final progress = <OAuthAuthorizationProgress>[];
      final tokenSet = await const GoogleAndroidOAuthClient(
        channel: channel,
        isSupportedOverride: true,
      ).authorize(
        provider: oauthProviderConfig('gmail'),
        androidClientId: 'android-client-id.apps.googleusercontent.com',
        serverClientId: 'web-client-id.apps.googleusercontent.com',
        serverClientSecret: 'web-client-secret',
        exchangeServerAuthorizationCode: ({
          required provider,
          required clientId,
          clientSecret,
          required code,
        }) async {
          expect(provider.provider, 'gmail');
          expect(clientId, 'web-client-id.apps.googleusercontent.com');
          expect(clientSecret, 'web-client-secret');
          expect(code, 'server-auth-code');
          return const OAuthTokenSet(
            accessToken: 'access-token',
            tokenType: 'Bearer',
            refreshToken: 'refresh-token',
            expiresIn: 3600,
            scope: 'https://mail.google.com/',
          );
        },
        loginHint: 'me@gmail.com',
        forceAccountPicker: true,
        onProgress: progress.add,
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'authorizeGmail');
      expect(calls.single.arguments, {
        'androidClientId': 'android-client-id.apps.googleusercontent.com',
        'serverClientId': 'web-client-id.apps.googleusercontent.com',
        'loginHint': 'me@gmail.com',
        'forceAccountPicker': true,
        'forceRefreshToken': true,
        'scopes': ['https://mail.google.com/'],
      });
      expect(progress, [
        OAuthAuthorizationProgress.waitingForAuthorization,
        OAuthAuthorizationProgress.exchangingToken,
      ]);
      expect(tokenSet.accessToken, 'access-token');
      expect(tokenSet.refreshToken, 'refresh-token');
      expect(tokenSet.expiresIn, 3600);
      expect(tokenSet.scope, 'https://mail.google.com/');
    },
  );

  test('android google client rejects a different selected account', () async {
    const channel = MethodChannel('test_google_authorization_mismatch');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'accessToken': 'access-token',
        'tokenType': 'Bearer',
        'expiresIn': 3600,
        'grantedScopes': ['https://mail.google.com/'],
        'accountEmail': 'other@gmail.com',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      const GoogleAndroidOAuthClient(
        channel: channel,
        isSupportedOverride: true,
      ).authorize(
        provider: oauthProviderConfig('gmail'),
        androidClientId: 'android-client-id.apps.googleusercontent.com',
        serverClientId: 'web-client-id.apps.googleusercontent.com',
        serverClientSecret: 'web-client-secret',
        exchangeServerAuthorizationCode:
            ({
              required provider,
              required clientId,
              clientSecret,
              required code,
            }) async =>
                throw StateError(
                  'exchange should not run for a mismatched account',
                ),
        loginHint: 'me@gmail.com',
      ),
      throwsA(isA<OAuthLoopbackException>()),
    );
  });

  test('android google client rejects unsupported providers', () async {
    await expectLater(
      const GoogleAndroidOAuthClient(isSupportedOverride: true).authorize(
        provider: oauthProviderConfig('outlook'),
        androidClientId: 'android-client-id.apps.googleusercontent.com',
        serverClientId: 'web-client-id.apps.googleusercontent.com',
        serverClientSecret: 'web-client-secret',
        exchangeServerAuthorizationCode:
            ({
              required provider,
              required clientId,
              clientSecret,
              required code,
            }) async => throw StateError('exchange should not run'),
      ),
      throwsA(isA<OAuthLoopbackException>()),
    );
  });

  test(
    'android google client rejects a missing server authorization code',
    () async {
      const channel = MethodChannel('test_google_authorization_missing_code');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var exchangeCalled = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{'accountEmail': 'me@gmail.com'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await expectLater(
        const GoogleAndroidOAuthClient(
          channel: channel,
          isSupportedOverride: true,
        ).authorize(
          provider: oauthProviderConfig('gmail'),
          androidClientId: 'android-client-id.apps.googleusercontent.com',
          serverClientId: 'web-client-id.apps.googleusercontent.com',
          serverClientSecret: 'web-client-secret',
          exchangeServerAuthorizationCode: ({
            required provider,
            required clientId,
            clientSecret,
            required code,
          }) async {
            exchangeCalled = true;
            throw StateError('exchange should not run');
          },
          loginHint: 'me@gmail.com',
        ),
        throwsA(
          isA<OAuthLoopbackException>().having(
            (error) => error.message,
            'message',
            contains('server authorization code'),
          ),
        ),
      );
      expect(exchangeCalled, isFalse);
    },
  );
}
