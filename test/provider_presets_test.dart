import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/provider_presets.dart';

void main() {
  test('gmail preset uses official host names', () {
    final preset = presetForProvider('gmail', 'me@gmail.com');
    expect(preset.imapHost, 'imap.gmail.com');
    expect(preset.smtpHost, 'smtp.gmail.com');
    expect(preset.smtpPort, 465);
    expect(preset.useTls, isTrue);
  });

  test('outlook preset uses STARTTLS SMTP settings', () {
    final preset = presetForProvider('outlook', 'me@outlook.com');
    expect(preset.imapHost, 'outlook.office365.com');
    expect(preset.smtpHost, 'smtp-mail.outlook.com');
    expect(preset.smtpPort, 587);
    expect(preset.useTls, isTrue);
  });

  test('icloud preset uses STARTTLS SMTP settings', () {
    final preset = presetForProvider('icloud', 'me@icloud.com');
    expect(preset.imapHost, 'imap.mail.me.com');
    expect(preset.smtpHost, 'smtp.mail.me.com');
    expect(preset.smtpPort, 587);
    expect(preset.useTls, isTrue);
  });

  test('generic preset derives hosts from domain', () {
    final preset = presetForProvider('imap', 'me@example.com');
    expect(preset.imapHost, 'imap.example.com');
    expect(preset.smtpHost, 'smtp.example.com');
    expect(preset.smtpPort, 587);
    expect(preset.useTls, isTrue);
  });
}
