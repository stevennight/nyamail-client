import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/system/notification_service.dart';

void main() {
  test('notification payloads normalize to message IDs', () {
    expect(
      notificationMessageIdFromPayload(' account:inbox:100 '),
      'account:inbox:100',
    );
    expect(notificationMessageIdFromPayload('  '), isNull);
    expect(notificationMessageIdFromPayload(null), isNull);
  });

  test('notification IDs are stable, positive, and message-specific', () {
    final first = notificationIdForKey('account:inbox:100');
    final repeated = notificationIdForKey('account:inbox:100');
    final other = notificationIdForKey('account:inbox:101');

    expect(first, repeated);
    expect(first, greaterThan(0));
    expect(first, isNot(other));
  });
}
