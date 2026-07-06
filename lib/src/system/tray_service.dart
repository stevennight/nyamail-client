import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

typedef AsyncVoidCallback = Future<void> Function();

class NyaMailTrayService with TrayListener, WindowListener {
  static const _trayIconPngAsset = 'assets/nyamail_tray.png';
  static const _trayIconIcoAsset = 'assets/nyamail_tray.ico';
  static const _showKey = 'show';
  static const _refreshKey = 'refresh';
  static const _updatesKey = 'updates';
  static const _quitKey = 'quit';

  bool _initialized = false;
  bool _enabled = false;
  bool _quitting = false;
  AsyncVoidCallback? _onShow;
  AsyncVoidCallback? _onRefresh;
  AsyncVoidCallback? _onCheckUpdates;

  static bool get isSupported {
    return !kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  static String get platformLabel {
    if (isSupported) {
      return 'Hide the window to the desktop tray instead of quitting.';
    }
    return 'Tray mode is available on Windows, macOS, and Linux.';
  }

  Future<void> configure({
    required bool enabled,
    required AsyncVoidCallback onShow,
    required AsyncVoidCallback onRefresh,
    required AsyncVoidCallback onCheckUpdates,
  }) async {
    _onShow = onShow;
    _onRefresh = onRefresh;
    _onCheckUpdates = onCheckUpdates;
    if (!isSupported) {
      _enabled = false;
      return;
    }
    await _ensureInitialized();
    _enabled = enabled;
    await windowManager.setPreventClose(enabled);
    if (enabled) {
      await _installTray();
    } else {
      await trayManager.destroy();
    }
  }

  Future<void> showWindow() async {
    if (!isSupported) return;
    await _ensureInitialized();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (!isSupported) return;
    await _ensureInitialized();
    _quitting = true;
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    if (_enabled && isSupported) {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
    }
    _initialized = false;
    _enabled = false;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await windowManager.ensureInitialized();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initialized = true;
  }

  Future<void> _installTray() async {
    await trayManager.setIcon(await _trayIconPath());
    await trayManager.setToolTip('NyaMail');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _showKey, label: 'Show NyaMail'),
          MenuItem(key: _refreshKey, label: 'Refresh mail'),
          MenuItem(key: _updatesKey, label: 'Check for updates'),
          MenuItem.separator(),
          MenuItem(key: _quitKey, label: 'Quit NyaMail'),
        ],
      ),
    );
  }

  Future<String> _trayIconPath() async {
    final asset = Platform.isWindows ? _trayIconIcoAsset : _trayIconPngAsset;
    final extension = Platform.isWindows ? '.ico' : '.png';
    final bytes = await rootBundle.load(asset);
    final directory = await getApplicationSupportDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}nyamail_tray$extension',
    );
    final payload = bytes.buffer.asUint8List();
    final existing =
        await file.exists() ? await file.readAsBytes() : const <int>[];
    if (!listEquals(existing, payload)) {
      await file.writeAsBytes(payload, flush: true);
    }
    return file.path;
  }

  @override
  void onWindowClose() {
    if (!_enabled || _quitting) return;
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited((_onShow ?? showWindow).call());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _showKey:
        unawaited((_onShow ?? showWindow).call());
      case _refreshKey:
        final onRefresh = _onRefresh;
        if (onRefresh != null) unawaited(onRefresh());
      case _updatesKey:
        final onCheckUpdates = _onCheckUpdates;
        if (onCheckUpdates != null) unawaited(onCheckUpdates());
      case _quitKey:
        unawaited(quit());
    }
  }
}
