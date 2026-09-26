import 'package:shared_preferences/shared_preferences.dart';

import 'notification_grouping.dart';

class SystemBehaviorSettings {
  const SystemBehaviorSettings({
    required this.minimizeToTray,
    required this.newMailNotifications,
    required this.openMessageFromNotification,
    this.notificationGrouping = NotificationGrouping.stack,
    this.androidBackgroundSync = false,
  });

  static const defaults = SystemBehaviorSettings(
    minimizeToTray: false,
    newMailNotifications: false,
    openMessageFromNotification: true,
    notificationGrouping: NotificationGrouping.stack,
    androidBackgroundSync: false,
  );

  final bool minimizeToTray;
  final bool newMailNotifications;
  final bool openMessageFromNotification;
  final NotificationGrouping notificationGrouping;

  /// Android only: keep a foreground service running so new mail is still
  /// checked (and IMAP IDLE push stays connected) while the app is in the
  /// background.
  final bool androidBackgroundSync;

  SystemBehaviorSettings copyWith({
    bool? minimizeToTray,
    bool? newMailNotifications,
    bool? openMessageFromNotification,
    NotificationGrouping? notificationGrouping,
    bool? androidBackgroundSync,
  }) {
    return SystemBehaviorSettings(
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      newMailNotifications: newMailNotifications ?? this.newMailNotifications,
      openMessageFromNotification:
          openMessageFromNotification ?? this.openMessageFromNotification,
      notificationGrouping: notificationGrouping ?? this.notificationGrouping,
      androidBackgroundSync:
          androidBackgroundSync ?? this.androidBackgroundSync,
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
  static const _androidBackgroundSyncKey = 'system.androidBackgroundSync';

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
      androidBackgroundSync:
          prefs.getBool(_androidBackgroundSyncKey) ??
          SystemBehaviorSettings.defaults.androidBackgroundSync,
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
    await prefs.setBool(
      _androidBackgroundSyncKey,
      settings.androidBackgroundSync,
    );
  }
}
