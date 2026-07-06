import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'tray_service.dart';

class NyaMailNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _enabled = false;
  int _nextNotificationId = 1;
  AsyncVoidCallback? _onNotificationSelected;

  static bool get isSupported {
    return !kIsWeb &&
        (Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isWindows ||
            Platform.isLinux);
  }

  static String get platformLabel {
    if (isSupported) {
      return 'Notify when NyaMail sees new unread incoming mail.';
    }
    return 'Notifications are not supported on this platform.';
  }

  Future<void> configure({
    required bool enabled,
    AsyncVoidCallback? onNotificationSelected,
  }) async {
    _onNotificationSelected = onNotificationSelected;
    if (!isSupported) {
      _enabled = false;
      return;
    }
    if (!enabled) {
      _enabled = false;
      return;
    }
    await _ensureInitialized();
    await _requestPermissions();
    _enabled = true;
  }

  Future<void> showNewMail({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_enabled || !isSupported) return;
    await _ensureInitialized();
    await _plugin.show(
      id: _nextNotificationId++,
      title: title,
      body: body,
      notificationDetails: _notificationDetails(),
      payload: payload,
    );
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Open NyaMail'),
        windows: WindowsInitializationSettings(
          appName: 'NyaMail',
          appUserModelId: 'app.nyamail',
          guid: '5f12e660-1bdb-4d76-9cdb-2c5574eac6e5',
        ),
      ),
      onDidReceiveNotificationResponse: (_) {
        final callback = _onNotificationSelected;
        if (callback != null) callback();
      },
    );
    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      return;
    }
    if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }
    if (Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  NotificationDetails _notificationDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'nyamail_new_mail',
        'New mail',
        channelDescription: 'Unread incoming mail discovered by NyaMail.',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      linux: LinuxNotificationDetails(),
    );
  }
}
