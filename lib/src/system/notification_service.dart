import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_grouping.dart';

typedef NotificationSelectionCallback = Future<void> Function(String? payload);

class NewMailNotificationAccount {
  const NewMailNotificationAccount({required this.id, required this.label});

  final String id;
  final String label;
}

const _baseChannelId = 'nyamail_new_mail';
const _baseChannelName = 'New mail';
const _baseGroupKey = 'nyamail_new_mail';
const _burstKey = 'burst:nyamail_new_mail';

/// Payload of notifications that stand for several messages: selecting one
/// opens the incoming mail list instead of a single message.
const newMailInboxNotificationPayload = 'nyamail:inbox';

class NyaMailNotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _enabled = false;
  bool _launchDetailsHandled = false;
  NotificationSelectionCallback? _onNotificationSelected;
  final Set<String> _createdChannelIds = <String>{};

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

  /// Whether the OS lets NyaMail post notifications. Null when unknown
  /// (platforms without a query API).
  static Future<bool?> systemPermissionGranted() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Pre-creates a per-account notification channel for each account so the
  /// "one group per account" mode can route to it. Android only; a no-op
  /// elsewhere.
  Future<void> ensureAccountChannels(
    Iterable<NewMailNotificationAccount> accounts,
  ) async {
    if (!_enabled || !isSupported || !Platform.isAndroid) return;
    await _ensureInitialized();
    for (final account in accounts) {
      await _ensureAndroidChannel(
        id: _accountChannelId(account.id),
        name: 'New mail — ${account.label}',
      );
    }
  }

  Future<void> showNewMail({
    required String notificationKey,
    required String title,
    required String body,
    String? accountLabel,
    String? accountId,
    String? payload,
    NotificationGrouping grouping = NotificationGrouping.stack,
  }) async {
    if (!_enabled || !isSupported) return;
    await _ensureInitialized();
    await _plugin.show(
      id: notificationIdForKey(notificationKey),
      title: title,
      body: body,
      notificationDetails: _messageDetails(
        body: body,
        accountLabel: accountLabel,
        accountId: accountId,
        grouping: grouping,
      ),
      payload: payload,
    );
  }

  /// One notification standing in for a burst of new mail, so a large sync
  /// does not flood the notification center. It reuses a single id: a later
  /// burst replaces it instead of stacking up.
  Future<void> showNewMailBurst({
    required String title,
    required String body,
    required List<String> lines,
  }) async {
    if (!_enabled || !isSupported) return;
    await _ensureInitialized();
    await _plugin.show(
      id: notificationIdForKey(_burstKey),
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _baseChannelId,
          _baseChannelName,
          channelDescription: 'Unread incoming mail discovered by NyaMail.',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.email,
          styleInformation: InboxStyleInformation(lines, contentTitle: title),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          threadIdentifier: _baseGroupKey,
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          threadIdentifier: _baseGroupKey,
        ),
        linux: const LinuxNotificationDetails(),
      ),
      payload: newMailInboxNotificationPayload,
    );
  }

  /// Removes the notification for a message that has been read.
  Future<void> cancelNewMail(String notificationKey) async {
    if (!_initialized || !isSupported) return;
    try {
      await _plugin.cancel(id: notificationIdForKey(notificationKey));
    } catch (error) {
      debugPrint('[NyaMail notifications] cancel failed: $error');
    }
  }

  /// Removes stack summaries, e.g. once nothing they summarized is unread.
  Future<void> cancelSummaries(Iterable<String> accountIds) async {
    if (!_initialized || !isSupported) return;
    final keys = {
      'summary:$_baseGroupKey',
      _burstKey,
      for (final accountId in accountIds) 'summary:$_baseGroupKey:$accountId',
    };
    for (final key in keys) {
      await cancelNewMail(key);
    }
  }

  /// Posts (or refreshes) the summary notification that lets a stack of
  /// new-mail notifications collapse into one row. Android only; on Apple
  /// platforms the thread identifier already groups them, so this is a no-op.
  Future<void> showNewMailSummary({
    required int messageCount,
    required List<String> lines,
    String? accountLabel,
    String? accountId,
    NotificationGrouping grouping = NotificationGrouping.stack,
  }) async {
    if (!_enabled || !isSupported || !Platform.isAndroid) return;
    if (grouping == NotificationGrouping.individual) return;
    await _ensureInitialized();
    final groupKey = _groupKeyFor(grouping, accountId);
    final channelId = _channelIdFor(grouping, accountId);
    final channelName = _channelNameFor(grouping, accountLabel);
    await _ensureAndroidChannel(id: channelId, name: channelName);
    final summaryTitle =
        messageCount == 1 ? '1 new message' : '$messageCount new messages';
    await _plugin.show(
      id: notificationIdForKey('summary:$groupKey'),
      title: summaryTitle,
      body: accountLabel ?? 'NyaMail',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Unread incoming mail discovered by NyaMail.',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.email,
          groupKey: groupKey,
          setAsGroupSummary: true,
          onlyAlertOnce: true,
          styleInformation: InboxStyleInformation(
            lines,
            contentTitle: summaryTitle,
            summaryText: accountLabel,
          ),
        ),
      ),
    );
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_mail'),
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
    if (Platform.isAndroid) {
      await _ensureAndroidChannel(id: _baseChannelId, name: _baseChannelName);
    }
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

  Future<void> _ensureAndroidChannel({
    required String id,
    required String name,
  }) async {
    if (!Platform.isAndroid || !_createdChannelIds.add(id)) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          AndroidNotificationChannel(
            id,
            name,
            description: 'Unread incoming mail discovered by NyaMail.',
            importance: Importance.high,
          ),
        );
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

  NotificationDetails _messageDetails({
    required String body,
    required NotificationGrouping grouping,
    String? accountLabel,
    String? accountId,
  }) {
    final groupKey =
        grouping == NotificationGrouping.individual
            ? null
            : _groupKeyFor(grouping, accountId);
    final threadIdentifier =
        grouping == NotificationGrouping.individual
            ? null
            : _groupKeyFor(grouping, accountId);
    final channelId = _channelIdFor(grouping, accountId);
    final channelName = _channelNameFor(grouping, accountLabel);
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: 'Unread incoming mail discovered by NyaMail.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.email,
        groupKey: groupKey,
        subText: accountLabel,
        styleInformation: BigTextStyleInformation(body),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        subtitle: accountLabel,
        threadIdentifier: threadIdentifier,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        subtitle: accountLabel,
        threadIdentifier: threadIdentifier,
      ),
      linux: const LinuxNotificationDetails(),
    );
  }

  String _groupKeyFor(NotificationGrouping grouping, String? accountId) {
    if (grouping == NotificationGrouping.perAccount &&
        accountId != null &&
        accountId.isNotEmpty) {
      return '$_baseGroupKey:$accountId';
    }
    return _baseGroupKey;
  }

  String _channelIdFor(NotificationGrouping grouping, String? accountId) {
    if (grouping == NotificationGrouping.perAccount &&
        accountId != null &&
        accountId.isNotEmpty) {
      return _accountChannelId(accountId);
    }
    return _baseChannelId;
  }

  String _channelNameFor(NotificationGrouping grouping, String? accountLabel) {
    if (grouping == NotificationGrouping.perAccount &&
        accountLabel != null &&
        accountLabel.trim().isNotEmpty) {
      return 'New mail — ${accountLabel.trim()}';
    }
    return _baseChannelName;
  }

  String _accountChannelId(String accountId) => '$_baseChannelId:$accountId';
}

String? notificationMessageIdFromPayload(String? payload) {
  final value = payload?.trim();
  if (value == null ||
      value.isEmpty ||
      value == newMailInboxNotificationPayload) {
    return null;
  }
  return value;
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
