import 'dart:io';

import 'mail_transport.dart';

class MailboxSetupDiagnostics {
  const MailboxSetupDiagnostics();

  String message({
    required String provider,
    required MailboxCredential credential,
    required Object error,
  }) {
    final suggestions = _suggestions(
      provider: provider,
      credential: credential,
      error: error,
    );
    final buffer = StringBuffer('Mailbox verification failed.');
    if (suggestions.isNotEmpty) {
      buffer.write('\n');
      for (final suggestion in suggestions) {
        buffer.write('\n- ');
        buffer.write(suggestion);
      }
    }
    buffer.write('\n\nTechnical detail: ');
    buffer.write(_technicalDetail(error));
    return buffer.toString();
  }

  List<String> _suggestions({
    required String provider,
    required MailboxCredential credential,
    required Object error,
  }) {
    final normalizedProvider = provider.trim().toLowerCase();
    final detail = _technicalDetail(error).toLowerCase();
    final suggestions = <String>[];

    if (credential.address.trim().isEmpty) {
      suggestions.add('Enter the mailbox address.');
    }
    if (credential.secret.isEmpty) {
      suggestions.add('Enter the provider app password or token.');
    }
    if (credential.imapHost.trim().isEmpty ||
        credential.smtpHost.trim().isEmpty) {
      suggestions.add('Check the IMAP and SMTP host names.');
    }
    if (credential.imapPort <= 0 || credential.smtpPort <= 0) {
      suggestions.add('Check the IMAP and SMTP ports.');
    }
    if (!credential.useTls) {
      suggestions.add(
          'Enable TLS unless your provider explicitly requires plaintext local mail service access.');
    }

    suggestions.addAll(_providerBaselineSuggestions(normalizedProvider));

    if (_looksLikeAuthFailure(detail)) {
      suggestions.add('Check the username and app password or token.');
    }

    if (detail.contains('starttls')) {
      suggestions.add(
          'Use port 465 for implicit TLS, or port 587 only when the SMTP server advertises STARTTLS.');
    }

    if (_looksLikeConnectivityFailure(error, detail)) {
      suggestions.add(
          'Check the host, port, DNS, firewall, and whether IMAP/SMTP access is enabled for this mailbox.');
    }

    suggestions
        .addAll(_providerPortSuggestions(normalizedProvider, credential));
    return _dedupe(suggestions);
  }

  List<String> _providerBaselineSuggestions(String provider) {
    return switch (provider) {
      'gmail' => const [
          'For Gmail, Sign in with Google is preferred; app-password setup only works when your Google account allows app passwords.',
        ],
      'outlook' => const [
          'Outlook.com requires OAuth2/Modern Auth; password or app-password setup only works for accounts or tenants that still allow IMAP/SMTP AUTH.',
        ],
      'icloud' => const [
          'For iCloud, use an app-specific password generated from your Apple account.',
        ],
      _ => const [],
    };
  }

  List<String> _providerPortSuggestions(
    String provider,
    MailboxCredential credential,
  ) {
    if (provider == 'gmail' &&
        (credential.imapHost != 'imap.gmail.com' ||
            credential.imapPort != 993 ||
            credential.smtpHost != 'smtp.gmail.com' ||
            credential.smtpPort != 465 ||
            !credential.useTls)) {
      return const [
        'Gmail preset should normally use imap.gmail.com:993 and smtp.gmail.com:465 with TLS.',
      ];
    }
    if (provider == 'outlook' &&
        (credential.imapHost != 'outlook.office365.com' ||
            credential.imapPort != 993 ||
            credential.smtpHost != 'smtp-mail.outlook.com' ||
            credential.smtpPort != 587 ||
            !credential.useTls)) {
      return const [
        'Outlook preset should normally use outlook.office365.com:993 and smtp-mail.outlook.com:587 with TLS.',
      ];
    }
    if (provider == 'icloud' &&
        (credential.imapHost != 'imap.mail.me.com' ||
            credential.imapPort != 993 ||
            credential.smtpHost != 'smtp.mail.me.com' ||
            credential.smtpPort != 587 ||
            !credential.useTls)) {
      return const [
        'iCloud preset should normally use imap.mail.me.com:993 and smtp.mail.me.com:587 with TLS.',
      ];
    }
    return const [];
  }

  bool _looksLikeAuthFailure(String detail) {
    return detail.contains('auth') ||
        detail.contains('login') ||
        detail.contains('password') ||
        detail.contains('credentials') ||
        detail.contains('535') ||
        detail.contains('534') ||
        detail.contains('530') ||
        detail.contains('invalid') ||
        detail.contains('authentication');
  }

  bool _looksLikeConnectivityFailure(Object error, String detail) {
    return error is SocketException ||
        error is HandshakeException ||
        detail.contains('timed out') ||
        detail.contains('connection') ||
        detail.contains('failed host lookup') ||
        detail.contains('network is unreachable') ||
        detail.contains('refused') ||
        detail.contains('certificate') ||
        detail.contains('handshake');
  }

  String _technicalDetail(Object error) {
    if (error is MailTransportException) return error.message;
    return error.toString();
  }

  List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.trim().isNotEmpty && seen.add(value)) value,
    ];
  }
}
