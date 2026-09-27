import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';

void main() {
  test('people by default', () {
    expect(
      classifyMailCategory(from: 'Bob Chen <bob@example.com>'),
      MailCategory.people,
    );
    // "news" only matches as a whole word.
    expect(
      classifyMailCategory(from: 'Gavin Newsom <gavin.newsom@example.com>'),
      MailCategory.people,
    );
  });

  test('automated senders are notifications', () {
    expect(
      classifyMailCategory(from: 'GitHub <noreply@github.com>'),
      MailCategory.notification,
    );
    expect(
      classifyMailCategory(from: 'Amazon <shipment-tracking@amazon.com>'),
      MailCategory.notification,
    );
    expect(
      classifyMailCategory(
        from: 'Build Bot <bot@example.com>',
        headers: const {'auto-submitted': 'auto-generated'},
      ),
      MailCategory.notification,
    );
  });

  test('subscriptions are newsletters', () {
    expect(
      classifyMailCategory(from: 'The Verge <newsletter@theverge.com>'),
      MailCategory.newsletter,
    );
    expect(
      classifyMailCategory(from: 'Medium Daily Digest <noreply@medium.com>'),
      MailCategory.newsletter,
    );
    expect(
      classifyMailCategory(
        from: 'Shop <hello@shop.example>',
        headers: const {'list-unsubscribe': '<mailto:u@shop.example>'},
      ),
      MailCategory.newsletter,
    );
  });

  test('messages cached without a category fall back to the sender', () {
    final message = MailMessage(
      id: '1',
      accountId: 'a',
      from: 'Slack <notification@slack.com>',
      subject: 's',
      preview: '',
      body: '',
      receivedAt: DateTime.utc(2026),
    );
    expect(message.category, isNull);
    expect(message.effectiveCategory, MailCategory.notification);
  });
}
