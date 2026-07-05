import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeSetting { system, light, dark }

extension AppThemeSettingDetails on AppThemeSetting {
  String get storageValue {
    return switch (this) {
      AppThemeSetting.system => 'system',
      AppThemeSetting.light => 'light',
      AppThemeSetting.dark => 'dark',
    };
  }

  String get label {
    return switch (this) {
      AppThemeSetting.system => 'System',
      AppThemeSetting.light => 'Light',
      AppThemeSetting.dark => 'Dark',
    };
  }

  ThemeMode get themeMode {
    return switch (this) {
      AppThemeSetting.system => ThemeMode.system,
      AppThemeSetting.light => ThemeMode.light,
      AppThemeSetting.dark => ThemeMode.dark,
    };
  }
}

AppThemeSetting appThemeSettingFromStorage(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'light' => AppThemeSetting.light,
    'dark' => AppThemeSetting.dark,
    _ => AppThemeSetting.system,
  };
}

class AppThemeSettingsStore {
  const AppThemeSettingsStore();

  static const _themeKey = 'nyamail.app.theme';

  Future<AppThemeSetting> load() async {
    final prefs = await SharedPreferences.getInstance();
    return appThemeSettingFromStorage(prefs.getString(_themeKey));
  }

  Future<void> save(AppThemeSetting setting) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, setting.storageValue);
  }
}
