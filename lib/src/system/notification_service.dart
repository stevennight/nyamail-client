import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef NotificationSelectionCallback = Future<void> Function(String? payload);

class NyaMailNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _enabled = false;
  bool _launchDetailsHandled = false;
  NotificationSelectionCallback? _onNotificationSelected;

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
    NotificationSelectionCallback? onNotificationSelected,
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
    required String notificationKey,
    required String title,
    required String body,
    String? accountLabel,
    String? payload,
  }) async {
    if (!_enabled || !isSupported) return;
    await _ensureInitialized();
    await _plugin.show(
      id: notificationIdForKey(notificationKey),
      title: title,
      body: body,
      notificationDetails: _notificationDetails(
        body: body,
        accountLabel: accountLabel,
      ),
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
      onDidReceiveNotificationResponse: (response) {
        _dispatchNotificationSelection(response.payload);
      },
    );
    _initialized = true;
    await _dispatchLaunchNotificationIfNeeded();
  }

  Future<void> _dispatchLaunchNotificationIfNeeded() async {
    if (_launchDetailsHandled) return;
    _launchDetailsHandled = true;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        _dispatchNotificationSelection(details?.notificationResponse?.payload);
      }
    } catch (error) {
      debugPrint(
        '[NyaMail notifications] could not read launch notification: $error',
      );
    }
  }

  void _dispatchNotificationSelection(String? payload) {
    final callback = _onNotificationSelected;
    if (callback != null) unawaited(callback(payload));
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

  NotificationDetails _notificationDetails({
    required String body,
    String? accountLabel,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'nyamail_new_mail',
        'New mail',
        channelDescription: 'Unread incoming mail discovered by NyaMail.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.email,
        groupKey: 'nyamail_new_mail',
        subText: accountLabel,
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        subtitle: accountLabel,
        threadIdentifier: 'nyamail_new_mail',
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        subtitle: accountLabel,
        threadIdentifier: 'nyamail_new_mail',
      ),
      linux: const LinuxNotificationDetails(),
    );
  }
}

String? notificationMessageIdFromPayload(String? payload) {
  final value = payload?.trim();
  return value == null || value.isEmpty ? null : value;
}

int notificationIdForKey(String key) {
  var hash = 0x811c9dc5;
  for (final codeUnit in key.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  final positive = hash & 0x7fffffff;
  return positive == 0 ? 1 : positive;
}
