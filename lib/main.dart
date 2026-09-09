import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/nyamail_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    // Keep the window above the width where the layout collapses to a single
    // pane so it can never be dragged into a pathological size.
    await windowManager.setMinimumSize(const Size(480, 480));
  }
  runApp(const NyaMailApp());
}
