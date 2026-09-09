import 'package:flutter/material.dart';

/// Central place for NyaMail's light and dark themes.
///
/// The palette is a calm, near-neutral blue: it should read as an ordinary
/// productivity app rather than draw attention to itself. Material 3's surface
/// tint (which washes elevated surfaces with the seed hue) is turned off on the
/// chrome so panels stay neutral grey.
const _seedColor = Color(0xFF2F5AA8);

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.light,
  );
  return _themeForScheme(scheme);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.dark,
  );
  return _themeForScheme(scheme);
}

ThemeData _themeForScheme(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 2,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: const DialogThemeData(surfaceTintColor: Colors.transparent),
    cardTheme: const CardThemeData(surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(
      surfaceTintColor: Colors.transparent,
    ),
  );
}
