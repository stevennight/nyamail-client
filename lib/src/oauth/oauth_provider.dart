class OAuthProviderConfig {
  const OAuthProviderConfig({
    required this.provider,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.scopes,
    this.imapHost = '',
    this.imapPort = 993,
    this.smtpHost = '',
    this.smtpPort = 587,
  });

  final String provider;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final List<String> scopes;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
}

OAuthProviderConfig oauthProviderConfig(
  String provider, {
  Uri? authorizationEndpoint,
  Uri? tokenEndpoint,
}) {
  return switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' => OAuthProviderConfig(
        provider: 'gmail',
        authorizationEndpoint: authorizationEndpoint ??
            Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
        tokenEndpoint:
            tokenEndpoint ?? Uri.parse('https://oauth2.googleapis.com/token'),
        scopes: const [
          'https://mail.google.com/',
        ],
        imapHost: 'imap.gmail.com',
        imapPort: 993,
        smtpHost: 'smtp.gmail.com',
        smtpPort: 465,
      ),
    'outlook' || 'microsoft' => OAuthProviderConfig(
        provider: 'outlook',
        authorizationEndpoint: authorizationEndpoint ??
            Uri.parse(
              'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
            ),
        tokenEndpoint: tokenEndpoint ??
            Uri.parse(
              'https://login.microsoftonline.com/common/oauth2/v2.0/token',
            ),
        scopes: const [
          'offline_access',
          'https://outlook.office.com/IMAP.AccessAsUser.All',
          'https://outlook.office.com/SMTP.Send',
        ],
        imapHost: 'outlook.office365.com',
        imapPort: 993,
        smtpHost: 'smtp-mail.outlook.com',
        smtpPort: 587,
      ),
    _ => throw OAuthProviderException('unsupported OAuth provider: $provider'),
  };
}

class OAuthProviderException implements Exception {
  const OAuthProviderException(this.message);

  final String message;

  @override
  String toString() => 'OAuthProviderException: $message';
}
