class MailProviderPreset {
  const MailProviderPreset({
    required this.provider,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.useTls,
  });

  final String provider;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final bool useTls;
}

MailProviderPreset presetForProvider(String provider, String address) {
  final domain = address.split('@').length == 2
      ? address.split('@').last.toLowerCase()
      : '';
  return switch (provider) {
    'gmail' => const MailProviderPreset(
        provider: 'gmail',
        imapHost: 'imap.gmail.com',
        imapPort: 993,
        smtpHost: 'smtp.gmail.com',
        smtpPort: 465,
        useTls: true,
      ),
    'outlook' => const MailProviderPreset(
        provider: 'outlook',
        imapHost: 'outlook.office365.com',
        imapPort: 993,
        smtpHost: 'smtp-mail.outlook.com',
        smtpPort: 587,
        useTls: true,
      ),
    'icloud' => const MailProviderPreset(
        provider: 'icloud',
        imapHost: 'imap.mail.me.com',
        imapPort: 993,
        smtpHost: 'smtp.mail.me.com',
        smtpPort: 587,
        useTls: true,
      ),
    _ => MailProviderPreset(
        provider: 'imap',
        imapHost: domain.isEmpty ? '' : 'imap.$domain',
        imapPort: 993,
        smtpHost: domain.isEmpty ? '' : 'smtp.$domain',
        smtpPort: 587,
        useTls: true,
      ),
  };
}
