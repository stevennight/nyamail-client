import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/system/notification_grouping.dart';
import 'package:nyamail/src/system/system_behavior_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'defaults to opening a message when its notification is selected',
    () async {
      final settings = await const SystemBehaviorSettingsStore().load();

      expect(settings.openMessageFromNotification, isTrue);
    },
  );

  test('persists notification message opening preference', () async {
    const store = SystemBehaviorSettingsStore();
    final disabled = SystemBehaviorSettings.defaults.copyWith(
      newMailNotifications: true,
      openMessageFromNotification: false,
    );

    await store.save(disabled);
    final restored = await store.load();

    expect(restored.newMailNotifications, isTrue);
    expect(restored.openMessageFromNotification, isFalse);
  });

  test('defaults notification grouping to a single stack', () async {
    final settings = await const SystemBehaviorSettingsStore().load();

    expect(settings.notificationGrouping, NotificationGrouping.stack);
  });

  test('persists the notification grouping preference', () async {
    const store = SystemBehaviorSettingsStore();

    await store.save(
      SystemBehaviorSettings.defaults.copyWith(
        notificationGrouping: NotificationGrouping.perAccount,
      ),
    );
    final restored = await store.load();

    expect(restored.notificationGrouping, NotificationGrouping.perAccount);
  });
}
