import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the Android `MailSyncService` foreground service.
///
/// The service only keeps the process alive; polling and IMAP IDLE keep
/// running in the (process-level cached) Flutter engine with the vault that
/// is already unlocked in memory, so no credentials are stored for it.
class AndroidBackgroundSync {
  AndroidBackgroundSync({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.nyatori.nyamail/background_sync');

  final MethodChannel _channel;
  bool _running = false;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static const platformLabel =
      'Keeps a quiet notification while checking mail in the background.';

  bool get isRunning => _running;

  /// Starts the service; returns false when Android refused (for example
  /// when asked from the background). Callers retry on the next foreground.
  Future<bool> start() async {
    if (!isSupported || _running) return _running;
    try {
      await _channel.invokeMethod<bool>('start');
      _running = true;
    } on PlatformException catch (error) {
      debugPrint('[NyaMail background] could not start service: $error');
    } on MissingPluginException {
      // Engine without the MainActivity channel (e.g. tests).
    }
    return _running;
  }

  Future<void> stop() async {
    if (!isSupported || !_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      debugPrint('[NyaMail background] could not stop service: $error');
    } on MissingPluginException {
      // Nothing to stop.
    }
  }

  /// Keeps the CPU awake for at most [timeout] so a background refresh can
  /// finish after an IDLE push woke the device.
  Future<void> acquireWakeLock(Duration timeout) async {
    if (!_running) return;
    try {
      await _channel.invokeMethod<void>('acquireWakeLock', {
        'timeoutMs': timeout.inMilliseconds,
      });
    } on PlatformException catch (error) {
      debugPrint('[NyaMail background] wake lock failed: $error');
    } on MissingPluginException {
      // Best effort.
    }
  }

  Future<void> releaseWakeLock() async {
    if (!_running) return;
    try {
      await _channel.invokeMethod<void>('releaseWakeLock');
    } on PlatformException {
      // The lock times out on its own.
    } on MissingPluginException {
      // Best effort.
    }
  }

  Future<bool?> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
  }

  /// App info page, where vendor ROMs keep auto-start and background limits.
  Future<void> openAppDetailsSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openAppDetailsSettings');
  }

  Future<void> openNotificationSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openNotificationSettings');
  }
}
