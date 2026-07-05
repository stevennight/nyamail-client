import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/app/app_theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('app theme setting defaults to system', () async {
    final setting = await const AppThemeSettingsStore().load();

    expect(setting, AppThemeSetting.system);
    expect(setting.themeMode, ThemeMode.system);
  });

  test('app theme setting persists dark mode', () async {
    const store = AppThemeSettingsStore();

    await store.save(AppThemeSetting.dark);
    final setting = await store.load();

    expect(setting, AppThemeSetting.dark);
    expect(setting.themeMode, ThemeMode.dark);
  });
}
