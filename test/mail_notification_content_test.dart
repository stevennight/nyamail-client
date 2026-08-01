import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_notification_content.dart';

void main() {
  test('uses sender name as title and subject plus preview as body', () {
    final content = MailNotificationContent.fromMessage(
      _message(
        from: '"Alice Example" <alice@example.com>',
        subject: 'Quarterly plan',
        preview: 'First line\nsecond line',
      ),
    );

    expect(content.title, 'Alice Example');
    expect(content.body, 'Quarterly plan\nFirst line second line');
  });

  test('does not repeat a preview that equals the subject', () {
    final content = MailNotificationContent.fromMessage(
      _message(
        from: 'alice@example.com',
        subject: 'Quarterly plan',
        preview: '  Quarterly plan  ',
      ),
    );

    expect(content.title, 'alice@example.com');
    expect(content.body, 'Quarterly plan');
  });

  test('falls back cleanly for missing sender and subject', () {
    final content = MailNotificationContent.fromMessage(
      _message(from: ' ', subject: ' ', preview: ''),
    );

    expect(content.title, 'Unknown sender');
    expect(content.body, '(No subject)');
  });
}

MailMessage _message({
  required String from,
  required String subject,
  required String preview,
}) {
  return MailMessage(
    id: 'acc:inbox:1',
    accountId: 'acc',
    from: from,
    subject: subject,
    preview: preview,
    body: '',
    receivedAt: DateTime.utc(2026, 8, 1),
  );
}
