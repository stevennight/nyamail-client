import 'package:shared_preferences/shared_preferences.dart';

import 'notification_grouping.dart';

class SystemBehaviorSettings {
  const SystemBehaviorSettings({
    required this.minimizeToTray,
    required this.newMailNotifications,
    required this.openMessageFromNotification,
    this.notificationGrouping = NotificationGrouping.stack,
  });

  static const defaults = SystemBehaviorSettings(
    minimizeToTray: false,
    newMailNotifications: false,
    openMessageFromNotification: true,
    notificationGrouping: NotificationGrouping.stack,
  );

  final bool minimizeToTray;
  final bool newMailNotifications;
  final bool openMessageFromNotification;
  final NotificationGrouping notificationGrouping;

  SystemBehaviorSettings copyWith({
    bool? minimizeToTray,
    bool? newMailNotifications,
    bool? openMessageFromNotification,
    NotificationGrouping? notificationGrouping,
  }) {
    return SystemBehaviorSettings(
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      newMailNotifications: newMailNotifications ?? this.newMailNotifications,
      openMessageFromNotification:
          openMessageFromNotification ?? this.openMessageFromNotification,
      notificationGrouping: notificationGrouping ?? this.notificationGrouping,
    );
  }
}

class SystemBehaviorSettingsStore {
  const SystemBehaviorSettingsStore();

  static const _minimizeToTrayKey = 'system.minimizeToTray';
  static const _newMailNotificationsKey = 'system.newMailNotifications';
  static const _openMessageFromNotificationKey =
      'system.openMessageFromNotification';
  static const _notificationGroupingKey = 'system.notificationGrouping';

  Future<SystemBehaviorSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SystemBehaviorSettings(
      minimizeToTray:
          prefs.getBool(_minimizeToTrayKey) ??
          SystemBehaviorSettings.defaults.minimizeToTray,
      newMailNotifications:
          prefs.getBool(_newMailNotificationsKey) ??
          SystemBehaviorSettings.defaults.newMailNotifications,
      openMessageFromNotification:
          prefs.getBool(_openMessageFromNotificationKey) ??
          SystemBehaviorSettings.defaults.openMessageFromNotification,
      notificationGrouping: notificationGroupingFromStorage(
        prefs.getString(_notificationGroupingKey),
      ),
    );
  }

  Future<void> save(SystemBehaviorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_minimizeToTrayKey, settings.minimizeToTray);
    await prefs.setBool(
      _newMailNotificationsKey,
      settings.newMailNotifications,
    );
    await prefs.setBool(
      _openMessageFromNotificationKey,
      settings.openMessageFromNotification,
    );
    await prefs.setString(
      _notificationGroupingKey,
      settings.notificationGrouping.storageValue,
    );
  }
}
