class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.releaseChannel,
    required this.releasePublicKey,
    required this.gmailOAuthClientId,
    required this.gmailOAuthClientSecret,
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
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
      gmailOAuthClientId:
          String.fromEnvironment('NYAMAIL_GMAIL_OAUTH_CLIENT_ID'),
      gmailOAuthClientSecret:
          String.fromEnvironment('NYAMAIL_GMAIL_OAUTH_CLIENT_SECRET'),
      outlookOAuthClientId:
          String.fromEnvironment('NYAMAIL_OUTLOOK_OAUTH_CLIENT_ID'),
      outlookOAuthClientSecret:
          String.fromEnvironment('NYAMAIL_OUTLOOK_OAUTH_CLIENT_SECRET'),
    );
  }

  final String apiBaseUrl;
  final String releaseChannel;
  final String releasePublicKey;
  final String gmailOAuthClientId;
  final String gmailOAuthClientSecret;
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;
}
