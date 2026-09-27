import 'package:flutter/material.dart';

/// Central place for NyaMail's light and dark themes.
///
/// The look follows modern mail clients such as Spark: neutral white/graphite
/// surfaces, a single clear blue accent, flat filled inputs and soft rounded
/// shapes. Material 3's seed-tinted surfaces are replaced with neutral greys so
/// the chrome never competes with the mail itself.
const _seedColor = Color(0xFF2F6FEB);

/// Radius shared by list selections, inputs and buttons.
const kNyaRadius = 10.0;

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.light,
  ).copyWith(
    primary: _seedColor,
    surface: const Color(0xFFFFFFFF),
    onSurface: const Color(0xFF1B1C1F),
    onSurfaceVariant: const Color(0xFF63666E),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF6F7F9),
    surfaceContainer: const Color(0xFFF0F1F4),
    surfaceContainerHigh: const Color(0xFFEBECEF),
    surfaceContainerHighest: const Color(0xFFE4E5E9),
    outline: const Color(0xFFB9BCC4),
    outlineVariant: const Color(0xFFE3E4E8),
    primaryContainer: const Color(0xFFDDE8FD),
    onPrimaryContainer: const Color(0xFF0B3A8F),
    secondaryContainer: const Color(0xFFE6ECF8),
    onSecondaryContainer: const Color(0xFF1B2A45),
  );
  return _themeForScheme(scheme);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFF6FA0FF),
    onPrimary: const Color(0xFF002E73),
    surface: const Color(0xFF1B1C1F),
    onSurface: const Color(0xFFE6E7EA),
    onSurfaceVariant: const Color(0xFFA2A5AD),
    surfaceContainerLowest: const Color(0xFF141517),
    surfaceContainerLow: const Color(0xFF17181B),
    surfaceContainer: const Color(0xFF222326),
    surfaceContainerHigh: const Color(0xFF2A2B2F),
    surfaceContainerHighest: const Color(0xFF333439),
    outline: const Color(0xFF5B5E66),
    outlineVariant: const Color(0xFF2E3034),
    primaryContainer: const Color(0xFF203A6B),
    onPrimaryContainer: const Color(0xFFD9E4FF),
    secondaryContainer: const Color(0xFF262C38),
    onSecondaryContainer: const Color(0xFFDCE3F3),
  );
  return _themeForScheme(scheme);
}

ThemeData _themeForScheme(ColorScheme scheme) {
  const radius = BorderRadius.all(Radius.circular(kNyaRadius));
  const shape = RoundedRectangleBorder(borderRadius: radius);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
  );
  final textTheme = base.textTheme.copyWith(
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
  return base.copyWith(
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainer,
      border: const OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainer),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: const WidgetStatePropertyAll(shape),
      constraints: const BoxConstraints(minHeight: 40, maxHeight: 40),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10),
      ),
      hintStyle: WidgetStatePropertyAll(
        textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      textStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    listTileTheme: const ListTileThemeData(shape: shape),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 64,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      elevation: 6,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(shape)),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(shape)),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(shape)),
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        shape: WidgetStatePropertyAll(shape),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      highlightElevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
