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
          'accessToken': 'access-token',
          'tokenType': 'Bearer',
          'refreshToken': 'refresh-token',
          'expiresIn': 3600,
          'grantedScopes': ['https://mail.google.com/'],
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
        clientId: 'android-client-id.apps.googleusercontent.com',
        loginHint: 'me@gmail.com',
        forceAccountPicker: true,
        onProgress: progress.add,
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'authorizeGmail');
      expect(calls.single.arguments, {
        'clientId': 'android-client-id.apps.googleusercontent.com',
        'loginHint': 'me@gmail.com',
        'forceAccountPicker': true,
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
        clientId: 'android-client-id.apps.googleusercontent.com',
        loginHint: 'me@gmail.com',
      ),
      throwsA(isA<OAuthLoopbackException>()),
    );
  });

  test('android google client rejects unsupported providers', () async {
    await expectLater(
      const GoogleAndroidOAuthClient(
        isSupportedOverride: true,
      ).authorize(provider: oauthProviderConfig('outlook')),
      throwsA(isA<OAuthLoopbackException>()),
    );
  });
}
