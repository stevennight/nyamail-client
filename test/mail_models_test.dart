import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';

void main() {
  test('mailMessageDetailLines includes available recipient metadata', () {
    final message = MailMessage(
      id: 'work:inbox:1',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      to: const ['me@example.com', 'team@example.com'],
      cc: const ['manager@example.com'],
      replyTo: const ['reply@example.com'],
      subject: 'Planning',
      preview: 'Preview',
      body: 'Body',
      receivedAt: DateTime.utc(2026, 7, 1, 8, 30),
    );

    final lines = mailMessageDetailLines(message);

    expect(lines, contains('From Alice <alice@example.com>'));
    expect(lines, contains('To me@example.com, team@example.com'));
    expect(lines, contains('Cc manager@example.com'));
    expect(lines, contains('Reply-To reply@example.com'));
    expect(lines.singleWhere((line) => line.startsWith('Date ')), isNotEmpty);
  });

  test('mailMessageDetailLines omits empty optional recipients', () {
    final message = MailMessage(
      id: 'work:inbox:2',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Planning',
      preview: 'Preview',
      body: 'Body',
      receivedAt: DateTime.utc(2026, 7, 1, 8, 30),
    );

    final lines = mailMessageDetailLines(message);

    expect(lines.any((line) => line.startsWith('To ')), isFalse);
    expect(lines.any((line) => line.startsWith('Cc ')), isFalse);
    expect(lines.any((line) => line.startsWith('Reply-To ')), isFalse);
  });

  test('mailMessageMatchesQuery searches body recipients and attachments', () {
    final message = MailMessage(
      id: 'work:inbox:3',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      to: const ['team@example.com'],
      cc: const ['manager@example.com'],
      replyTo: const ['reply@example.com'],
      subject: 'Planning',
      preview: 'Preview',
      body: 'The launch code is nebula.',
      receivedAt: DateTime.utc(2026, 7, 1, 8, 30),
      attachments: const [
        MailAttachment(
          filename: 'roadmap.pdf',
          contentType: 'application/pdf',
          partId: '2',
        ),
      ],
    );

    expect(mailMessageMatchesQuery(message, 'nebula'), isTrue);
    expect(mailMessageMatchesQuery(message, 'manager@example.com'), isTrue);
    expect(mailMessageMatchesQuery(message, 'roadmap'), isTrue);
    expect(mailMessageMatchesQuery(message, 'missing'), isFalse);
  });
}
