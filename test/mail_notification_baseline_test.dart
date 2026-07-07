import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_notification_baseline.dart';

void main() {
  test('startup baseline records existing unread mail without notifying', () {
    final baseline = MailNotificationBaseline();
    final oldMessage = _message('old', DateTime.utc(2010, 2, 9));

    final firstFresh = baseline.freshMessages([oldMessage]);
    final completedFresh = baseline.freshMessages([
      oldMessage,
      _message('older-sync', DateTime.utc(2009, 1, 1)),
    ], completeStartupBaseline: true);
    final afterStartupFresh = baseline.freshMessages([
      oldMessage,
      _message('older-sync', DateTime.utc(2009, 1, 1)),
      _message('new-after-start', DateTime.utc(2026, 7, 7)),
    ]);

    expect(firstFresh, isEmpty);
    expect(completedFresh, isEmpty);
    expect(afterStartupFresh.map((message) => message.id), ['new-after-start']);
  });

  test('suppressed startup refresh can extend baseline after completion', () {
    final baseline = MailNotificationBaseline();
    final oldMessage = _message('old', DateTime.utc(2010, 2, 9));
    final oldFromRefresh = _message('old-refresh', DateTime.utc(2010, 2, 10));

    expect(
      baseline.freshMessages([oldMessage], completeStartupBaseline: true),
      isEmpty,
    );
    baseline.prime([oldMessage, oldFromRefresh]);

    final fresh = baseline.freshMessages([
      oldMessage,
      oldFromRefresh,
      _message('new-after-refresh', DateTime.utc(2026, 7, 7)),
    ]);

    expect(fresh.map((message) => message.id), ['new-after-refresh']);
  });
}

MailMessage _message(String id, DateTime receivedAt) {
  return MailMessage(
    id: id,
    accountId: 'acc',
    from: 'Alice <alice@example.com>',
    subject: id,
    preview: id,
    body: id,
    receivedAt: receivedAt,
    read: false,
  );
}
