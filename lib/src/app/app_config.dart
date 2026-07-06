class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.releaseChannel,
    required this.releasePublicKey,
    required this.gmailOAuthClientId,
    required this.gmailOAuthClientSecret,
    required this.gmailAndroidOAuthClientId,
    required this.gmailAndroidOAuthClientSecret,
    required this.gmailAndroidOAuthRedirectUri,
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
    required this.outlookAndroidOAuthClientId,
    required this.outlookAndroidOAuthClientSecret,
    required this.outlookAndroidOAuthRedirectUri,
    required this.oauthRedirectScheme,
    required this.oauthRedirectHost,
    required this.oauthRedirectPath,
  });

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      apiBaseUrl: String.fromEnvironment(
        'NYAMAIL_API_BASE_URL',
        defaultValue: 'http://localhost:8080',
      ),
      releaseChannel: String.fromEnvironment(
        'NYAMAIL_RELEASE_CHANNEL',
        defaultValue: 'dev',
      ),
      releasePublicKey: String.fromEnvironment('NYAMAIL_RELEASE_PUBLIC_KEY'),
      gmailOAuthClientId: String.fromEnvironment(
        'NYAMAIL_GMAIL_OAUTH_CLIENT_ID',
      ),
      gmailOAuthClientSecret: String.fromEnvironment(
        'NYAMAIL_GMAIL_OAUTH_CLIENT_SECRET',
      ),
      gmailAndroidOAuthClientId: String.fromEnvironment(
        'NYAMAIL_GMAIL_ANDROID_OAUTH_CLIENT_ID',
      ),
      gmailAndroidOAuthClientSecret: String.fromEnvironment(
        'NYAMAIL_GMAIL_ANDROID_OAUTH_CLIENT_SECRET',
      ),
      gmailAndroidOAuthRedirectUri: String.fromEnvironment(
        'NYAMAIL_GMAIL_ANDROID_OAUTH_REDIRECT_URI',
      ),
      outlookOAuthClientId: String.fromEnvironment(
        'NYAMAIL_OUTLOOK_OAUTH_CLIENT_ID',
      ),
      outlookOAuthClientSecret: String.fromEnvironment(
        'NYAMAIL_OUTLOOK_OAUTH_CLIENT_SECRET',
      ),
      outlookAndroidOAuthClientId: String.fromEnvironment(
        'NYAMAIL_OUTLOOK_ANDROID_OAUTH_CLIENT_ID',
      ),
      outlookAndroidOAuthClientSecret: String.fromEnvironment(
        'NYAMAIL_OUTLOOK_ANDROID_OAUTH_CLIENT_SECRET',
      ),
      outlookAndroidOAuthRedirectUri: String.fromEnvironment(
        'NYAMAIL_OUTLOOK_ANDROID_OAUTH_REDIRECT_URI',
      ),
      oauthRedirectScheme: String.fromEnvironment(
        'NYAMAIL_OAUTH_REDIRECT_SCHEME',
        defaultValue: 'app.nyamail.client',
      ),
      oauthRedirectHost: String.fromEnvironment('NYAMAIL_OAUTH_REDIRECT_HOST'),
      oauthRedirectPath: String.fromEnvironment(
        'NYAMAIL_OAUTH_REDIRECT_PATH',
        defaultValue: '/oauth2redirect',
      ),
    );
  }

  final String apiBaseUrl;
  final String releaseChannel;
  final String releasePublicKey;
  final String gmailOAuthClientId;
  final String gmailOAuthClientSecret;
  final String gmailAndroidOAuthClientId;
  final String gmailAndroidOAuthClientSecret;
  final String gmailAndroidOAuthRedirectUri;
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;
  final String outlookAndroidOAuthClientId;
  final String outlookAndroidOAuthClientSecret;
  final String outlookAndroidOAuthRedirectUri;
  final String oauthRedirectScheme;
  final String oauthRedirectHost;
  final String oauthRedirectPath;
}
