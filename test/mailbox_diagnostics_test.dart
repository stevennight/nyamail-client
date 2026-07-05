import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mailbox_diagnostics.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

void main() {
  const diagnostics = MailboxSetupDiagnostics();

  test('gmail auth failure points to OAuth or app password', () {
    final message = diagnostics.message(
      provider: 'gmail',
      credential: _credential(
        address: 'me@gmail.com',
        imapHost: 'imap.gmail.com',
        smtpHost: 'smtp.gmail.com',
        smtpPort: 465,
      ),
      error: const MailTransportException(
        'IMAP command failed: A0001 NO [AUTHENTICATIONFAILED] Invalid credentials',
      ),
    );

    expect(message, contains('Mailbox verification failed.'));
    expect(message, contains('Check the username and app password or token.'));
    expect(message, contains('Sign in with Google'));
    expect(message, contains('Technical detail: IMAP command failed'));
  });

  test('outlook starttls failure explains port and Modern Auth', () {
    final message = diagnostics.message(
      provider: 'outlook',
      credential: _credential(
        address: 'me@outlook.com',
        imapHost: 'outlook.office365.com',
        smtpHost: 'smtp-mail.outlook.com',
      ),
      error: const MailTransportException(
        'SMTP server does not advertise STARTTLS: smtp-mail.outlook.com:587',
      ),
    );

    expect(message, contains('port 465 for implicit TLS'));
    expect(message, contains('OAuth2/Modern Auth'));
  });

  test('icloud changed ports are called out', () {
    final message = diagnostics.message(
      provider: 'icloud',
      credential: _credential(
        address: 'me@icloud.com',
        imapHost: 'mail.example.com',
        smtpHost: 'smtp.example.com',
        smtpPort: 465,
      ),
      error:
          const MailTransportException('SMTP command failed: 535 auth failed'),
    );

    expect(message, contains('app-specific password'));
    expect(message, contains('imap.mail.me.com:993'));
    expect(message, contains('smtp.mail.me.com:587'));
  });

  test('socket failures point to host port network checks', () {
    final message = diagnostics.message(
      provider: 'imap',
      credential: _credential(
        address: 'me@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      ),
      error: const SocketException('Failed host lookup: imap.example.com'),
    );

    expect(message, contains('host, port, DNS, firewall'));
  });
}

MailboxCredential _credential({
  required String address,
  required String imapHost,
  required String smtpHost,
  int smtpPort = 587,
}) {
  return MailboxCredential(
    accountId: 'acct_1',
    address: address,
    displayName: address,
    imapHost: imapHost,
    imapPort: 993,
    smtpHost: smtpHost,
    smtpPort: smtpPort,
    username: address,
    secret: 'secret',
  );
}
