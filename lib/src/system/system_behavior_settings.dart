import 'package:shared_preferences/shared_preferences.dart';

class SystemBehaviorSettings {
  const SystemBehaviorSettings({
    required this.minimizeToTray,
    required this.newMailNotifications,
  });

  static const defaults = SystemBehaviorSettings(
    minimizeToTray: false,
    newMailNotifications: false,
  );

  final bool minimizeToTray;
  final bool newMailNotifications;

  SystemBehaviorSettings copyWith({
    bool? minimizeToTray,
    bool? newMailNotifications,
  }) {
    return SystemBehaviorSettings(
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      newMailNotifications: newMailNotifications ?? this.newMailNotifications,
    );
  }
}

class SystemBehaviorSettingsStore {
  const SystemBehaviorSettingsStore();

  static const _minimizeToTrayKey = 'system.minimizeToTray';
  static const _newMailNotificationsKey = 'system.newMailNotifications';

  Future<SystemBehaviorSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SystemBehaviorSettings(
      minimizeToTray:
          prefs.getBool(_minimizeToTrayKey) ??
          SystemBehaviorSettings.defaults.minimizeToTray,
      newMailNotifications:
          prefs.getBool(_newMailNotificationsKey) ??
          SystemBehaviorSettings.defaults.newMailNotifications,
    );
  }

  Future<void> save(SystemBehaviorSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_minimizeToTrayKey, settings.minimizeToTray);
    await prefs.setBool(
      _newMailNotificationsKey,
      settings.newMailNotifications,
    );
  }
}
