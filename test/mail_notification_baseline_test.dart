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

  test(
    'older messages discovered later extend the baseline without notifying',
    () {
      final baseline = MailNotificationBaseline();
      final newestKnown = _message('known', DateTime.utc(2026, 7, 7, 10));

      baseline.freshMessages([newestKnown], completeStartupBaseline: true);
      final fresh = baseline.freshMessages([
        newestKnown,
        _message('old-page', DateTime.utc(2024, 1, 1)),
      ]);

      expect(fresh, isEmpty);
    },
  );

  test('only messages newer than the account watermark notify', () {
    final baseline = MailNotificationBaseline();
    final known = _message('known', DateTime.utc(2026, 7, 7, 10));

    baseline.freshMessages([known], completeStartupBaseline: true);
    final fresh = baseline.freshMessages([
      _message('old-page', DateTime.utc(2024, 1, 1)),
      _message('new-mail', DateTime.utc(2026, 7, 7, 10, 1)),
    ]);

    expect(fresh.map((message) => message.id), ['new-mail']);
  });

  test('first observation of another account is primed without notifying', () {
    final baseline = MailNotificationBaseline();
    baseline.freshMessages([
      _message('known', DateTime.utc(2026, 7, 7, 10)),
    ], completeStartupBaseline: true);

    final firstAccountBatch = baseline.freshMessages([
      _message(
        'recovered-account-old-mail',
        DateTime.utc(2020, 1, 1),
        accountId: 'recovered',
      ),
    ]);
    final nextAccountBatch = baseline.freshMessages([
      _message(
        'recovered-account-new-mail',
        DateTime.utc(2026, 7, 7, 11),
        accountId: 'recovered',
      ),
    ]);

    expect(firstAccountBatch, isEmpty);
    expect(nextAccountBatch.map((message) => message.id), [
      'recovered-account-new-mail',
    ]);
  });
}

MailMessage _message(
  String id,
  DateTime receivedAt, {
  String accountId = 'acc',
}) {
  return MailMessage(
    id: id,
    accountId: accountId,
    from: 'Alice <alice@example.com>',
    subject: id,
    preview: id,
    body: id,
    receivedAt: receivedAt,
    read: false,
  );
}
