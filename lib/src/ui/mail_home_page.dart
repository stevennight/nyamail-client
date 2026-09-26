import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../api/nyamail_api.dart';
import '../app/app_theme_settings.dart';
import '../mail/mail_cache.dart';
import '../mail/mail_draft_cache.dart';
import '../mail/mail_appearance.dart';
import '../mail/mail_html_sanitizer.dart';
import '../mail/mail_interaction_settings.dart';
import '../mail/mail_notification_baseline.dart';
import '../mail/mail_notification_content.dart';
import '../mail/mailbox_diagnostics.dart';
import '../mail/mail_models.dart';
import '../mail/mail_render_settings.dart';
import '../mail/provider_presets.dart';
import '../mail/mail_repository.dart';
import '../mail/mail_transport.dart';
import '../oauth/google_android_oauth_client.dart';
import '../oauth/oauth_loopback_client.dart';
import '../oauth/oauth_mailbox_builder.dart';
import '../oauth/oauth_provider.dart';
import '../oauth/oauth_vault_refresher.dart';
import '../release/release_service.dart';
import '../security/device_approval_crypto.dart';
import '../security/device_pairing_code.dart';
import '../security/device_pairing_request.dart';
import '../security/local_cache_crypto.dart';
import '../security/local_vault_migration.dart';
import '../security/local_secure_store.dart';
import '../security/local_vault_auth.dart';
import '../security/local_vault_record_store.dart';
import '../security/local_vault_sync_state_store.dart';
import '../security/local_vault_store.dart';
import '../security/vault_crypto.dart';
import '../security/vault_document.dart';
import '../security/vault_export.dart';
import '../security/vault_record_crypto.dart';
import '../security/vault_record_sync_engine.dart';
import '../security/vault_records.dart';
import '../security/vault_share_crypto.dart';
import '../system/android_background_sync.dart';
import '../system/notification_grouping.dart';
import '../system/notification_service.dart';
import '../system/startup_service.dart';
import '../system/system_behavior_settings.dart';
import '../system/tray_service.dart';
import 'mail_html_view.dart';

part 'mail_home/account_dialogs.dart';
part 'mail_home/devices.dart';
part 'mail_home/helpers.dart';
part 'mail_home/mailbox_dialogs.dart';
part 'mail_home/message_list.dart';
part 'mail_home/reader_compose.dart';
part 'mail_home/settings_dialogs.dart';
part 'mail_home/settings_page.dart';
part 'mail_home/shell.dart';
part 'mail_home/sidebar.dart';
part 'mail_home/vault_dialogs.dart';

const _maxOutgoingAttachmentBytes = 25 * 1024 * 1024;
const _googleAndroidOAuthClient = GoogleAndroidOAuthClient();
const _mailRefreshTimeout = Duration(seconds: 45);
const _mailLoadMoreTimeout = Duration(seconds: 60);
const _oauthRefreshTimeout = Duration(seconds: 20);
const _folderDiscoveryTimeout = Duration(seconds: 45);
const _automaticMailRefreshInterval = Duration(minutes: 1);
const _pushBackedMailRefreshInterval = Duration(minutes: 5);
const _mailPushDebounceDelay = Duration(milliseconds: 1500);

/// Fixed amber for the "starred" affordance so it reads as a star regardless of
/// the accent colour.
const _starColor = Color(0xFFF5A623);

/// Below this width the folder list collapses into a drawer; at or above it the
/// sidebar is always visible, the way desktop mail clients keep it. Kept low
/// enough that a typical 1280–1440 laptop window shows the sidebar.
const _kSidebarBreakpoint = 1100.0;

/// Below this width the two-pane (list + reading) layout collapses to a single
/// pane that pushes the message onto its own route.
const _kSinglePaneBreakpoint = 820.0;

/// A stable, muted accent colour for an account, used as the thin bar down the
/// left edge of its messages so multi-account inboxes stay legible without a
/// bulky per-row chip.
Color _accountAccentColor(String accountId, ColorScheme scheme) {
  if (accountId.isEmpty) return scheme.outlineVariant;
  var hash = 0x811c9dc5;
  for (final unit in accountId.codeUnits) {
    hash = (hash ^ unit) * 0x01000193 & 0xffffffff;
  }
  final hue = (hash % 360).toDouble();
  final lightness = scheme.brightness == Brightness.dark ? 0.62 : 0.45;
  return HSLColor.fromAHSL(1, hue, 0.45, lightness).toColor();
}

/// Best-effort display name for a sender header: the quoted/display part when
/// present, otherwise the bare address.
String _displaySender(String from) {
  final value = from.trim();
  if (value.isEmpty) return 'Unknown sender';
  final angle = value.indexOf('<');
  if (angle > 0) {
    final name = value.substring(0, angle).trim().replaceAll('"', '').trim();
    if (name.isNotEmpty) return name;
  }
  return value.replaceAll('<', '').replaceAll('>', '').trim();
}

/// Bare address portion of a `Name <addr>` sender string, or '' when there is no
/// distinct address to show under the display name.
String _senderAddress(String from) {
  final value = from.trim();
  final open = value.indexOf('<');
  final close = value.indexOf('>', open + 1);
  if (open >= 0 && close > open) {
    return value.substring(open + 1, close).trim();
  }
  return value.contains('@') ? value : '';
}

/// First printable character for a sender avatar, upper-cased.
String _senderInitial(String label) {
  for (final rune in label.trim().runes) {
    final ch = String.fromCharCode(rune).trim();
    if (ch.isNotEmpty) return ch.toUpperCase();
  }
  return '?';
}

/// Stable, reasonably saturated fill colour for a sender avatar.
Color _senderAvatarColor(String key, ColorScheme scheme) {
  if (key.trim().isEmpty) return scheme.secondaryContainer;
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = (hash ^ unit) * 0x01000193 & 0xffffffff;
  }
  final hue = (hash % 360).toDouble();
  final lightness = scheme.brightness == Brightness.dark ? 0.55 : 0.5;
  return HSLColor.fromAHSL(1, hue, 0.5, lightness).toColor();
}

const _mailHomeShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyN, control: true): _ComposeMailIntent(),
  SingleActivator(LogicalKeyboardKey.keyN, meta: true): _ComposeMailIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, control: true): _FocusSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyF, meta: true): _FocusSearchIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, control: true):
      _SelectAllMessagesIntent(),
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      _SelectAllMessagesIntent(),
  SingleActivator(LogicalKeyboardKey.keyR, control: true): _RefreshMailIntent(),
  SingleActivator(LogicalKeyboardKey.keyR, meta: true): _RefreshMailIntent(),
  SingleActivator(LogicalKeyboardKey.f5): _RefreshMailIntent(),
  SingleActivator(LogicalKeyboardKey.delete): _DeleteMessagesIntent(),
  SingleActivator(LogicalKeyboardKey.backspace): _DeleteMessagesIntent(),
  SingleActivator(LogicalKeyboardKey.escape): _ClearMessageSelectionIntent(),
  SingleActivator(LogicalKeyboardKey.arrowDown): _MoveSelectionIntent(1),
  SingleActivator(LogicalKeyboardKey.arrowUp): _MoveSelectionIntent(-1),
};

class _ComposeMailIntent extends Intent {
  const _ComposeMailIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _SelectAllMessagesIntent extends Intent {
  const _SelectAllMessagesIntent();
}

class _RefreshMailIntent extends Intent {
  const _RefreshMailIntent();
}

class _DeleteMessagesIntent extends Intent {
  const _DeleteMessagesIntent();
}

class _ClearMessageSelectionIntent extends Intent {
  const _ClearMessageSelectionIntent();
}

class _MoveSelectionIntent extends Intent {
  const _MoveSelectionIntent(this.delta);

  final int delta;
}

bool _usesGoogleAndroidOAuth(String provider) {
  return !kIsWeb &&
      io.Platform.isAndroid &&
      normalizeOAuthProviderKey(provider) == 'gmail';
}

Future<OAuthTokenSet> _authorizeOAuthForCurrentPlatform({
  required OAuthLoopbackClient oauthClient,
  required OAuthProviderConfig provider,
  required String clientId,
  String? androidClientId,
  String? clientSecret,
  String? loginHint,
  Uri? mobileRedirectUri,
  bool forceAccountPicker = false,
  OAuthAuthorizationProgressCallback? onProgress,
}) {
  if (_usesGoogleAndroidOAuth(provider.provider)) {
    return _googleAndroidOAuthClient.authorize(
      provider: provider,
      androidClientId: androidClientId ?? '',
      serverClientId: clientId,
      serverClientSecret: clientSecret ?? '',
      exchangeServerAuthorizationCode:
          oauthClient.exchangeServerAuthorizationCode,
      loginHint: loginHint,
      forceAccountPicker: forceAccountPicker,
      onProgress: onProgress,
    );
  }
  return oauthClient.authorize(
    provider: provider,
    clientId: clientId,
    clientSecret: clientSecret,
    loginHint: loginHint,
    mobileRedirectUri: mobileRedirectUri,
    onProgress: onProgress,
  );
}

class MailHomePage extends StatefulWidget {
  const MailHomePage({
    required this.api,
    required this.apiBaseUrl,
    required this.defaultApiBaseUrl,
    required this.onApiBaseUrlChanged,
    required this.appThemeSetting,
    required this.onAppThemeSettingChanged,
    required this.releaseService,
    required this.secureStore,
    required this.localVaultStore,
    required this.localVaultRecordStore,
    required this.localVaultSyncStateStore,
    required this.vaultCrypto,
    required this.vaultRecordCrypto,
    required this.oauthClient,
    required this.gmailOAuthClientId,
    required this.gmailOAuthClientSecret,
    required this.gmailAndroidOAuthClientId,
    required this.gmailAndroidOAuthClientSecret,
    required this.gmailAndroidOAuthRedirectUri,
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
    required this.outlookAndroidOAuthClientId,
    required this.outlookAndroidOAuthClientSecret,
    required this.outlookAndroidOAuthRedirectUri,
    required this.mailRepository,
    super.key,
  });

  final NyaMailApi api;
  final String apiBaseUrl;
  final String defaultApiBaseUrl;
  final Future<void> Function(String apiBaseUrl) onApiBaseUrlChanged;
  final AppThemeSetting appThemeSetting;
  final Future<void> Function(AppThemeSetting setting) onAppThemeSettingChanged;
  final ReleaseService releaseService;
  final LocalSecureStore secureStore;
  final LocalVaultStore localVaultStore;
  final LocalVaultRecordStore localVaultRecordStore;
  final LocalVaultSyncStateStore localVaultSyncStateStore;
  final VaultCrypto vaultCrypto;
  final VaultRecordCrypto vaultRecordCrypto;
  final OAuthLoopbackClient oauthClient;
  final String gmailOAuthClientId;
  final String gmailOAuthClientSecret;
  final String gmailAndroidOAuthClientId;
  final String gmailAndroidOAuthClientSecret;
  final String gmailAndroidOAuthRedirectUri;
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;
  final String outlookAndroidOAuthClientId;
  final String outlookAndroidOAuthClientSecret;
  final String outlookAndroidOAuthRedirectUri;
  final MailRepository mailRepository;

  @override
  State<MailHomePage> createState() => _MailHomePageState();
}

class _MailHomePageState extends State<MailHomePage>
    with WidgetsBindingObserver {
  static const _messagePageSize = 30;
  static const _notificationMessageLookupLimit = 100;
  static const _mailActionUndoWindow = Duration(seconds: 5);

  LocalSession? _session;
  LocalProfile? _profile;
  List<MailAccount> _accounts = const [];
  List<MailFolder> _folders = const [];
  List<MailMessage> _messages = const [];
  late MailRepository _mailRepository;
  MailDraftCache? _draftCache;
  VaultDocument? _vaultDocument;
  int? _vaultRecordRevision;
  String? _unlockedVaultSecret;
  String? _unlockedVaultPassword;
  MailboxView _view = const MailboxView.smart(MailSmartFolder.allIncoming);
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _selectedAccountId;
  MailMessage? _selected;
  MailRenderSettings _renderSettings = MailRenderSettings.defaults;
  MailInteractionSettings _interactionSettings =
      MailInteractionSettings.defaults;
  Set<String> _pinnedMessageIds = const <String>{};
  Set<String> _selectedMessageIds = const <String>{};
  String? _keyboardNavigationMessageId;
  int _keyboardNavigationDirection = 1;
  bool _loading = true;
  bool _vaultUnlocking = false;
  bool _vaultUnlockCancelled = false;
  bool _loadingMore = false;
  Future<OAuthVaultRefreshResult?>? _oauthRefreshFuture;
  final Map<String, MailAccountSyncFailure> _accountSyncFailures =
      <String, MailAccountSyncFailure>{};
  bool _claimingVaultShare = false;
  String? _bannerValue;
  _NoticeKind _bannerKind = _NoticeKind.info;
  bool _captureSettingsNotices = false;
  _SettingsFeedback? _capturedSettingsFeedback;
  bool _checkingForUpdates = false;
  bool _refreshingMail = false;
  int? _refreshingMailRequestId;
  bool _mailUndoSnackBarVisible = false;
  int _mailUndoSnackBarGeneration = 0;
  int _nextPendingMailActionId = 0;
  int? _visiblePendingMailActionId;
  bool _flushingPendingMailActions = false;
  final _pendingMailActions = <int, _PendingMailAction>{};
  String? _pendingPairingPackage;
  final _mobileMessageNotifiers = <String, ValueNotifier<MailMessage>>{};
  final _messageBodyLoads = <String, Future<MailMessage?>>{};
  final _startupService = const StartupService();
  final _systemSettingsStore = const SystemBehaviorSettingsStore();
  final _trayService = NyaMailTrayService();
  final _notificationService = NyaMailNotificationService();
  final _androidBackgroundSync = AndroidBackgroundSync();
  final _search = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'Mail search');
  bool _hasMoreMessages = true;
  int _messageLoadGeneration = 0;
  SystemBehaviorSettings _systemSettings = SystemBehaviorSettings.defaults;
  Timer? _automaticMailRefreshTimer;
  Duration? _automaticMailRefreshTimerInterval;
  bool _automaticMailRefreshInProgress = false;
  final _mailPushWatchers = <String, ImapIdleWatcher>{};
  final _mailPushStates = <String, ImapIdleState>{};
  final _mailPushUnsupported = <String>{};
  Timer? _mailPushDebounce;
  bool _mailPushRefreshQueued = false;
  bool _appIsInForeground = true;
  int _pendingStartupMailboxWork = 0;
  bool _pollingNewMail = false;
  String? _pendingNotificationMessageId;
  bool _openingNotificationMessage = false;
  final _newMailNotificationBaseline = MailNotificationBaseline();
  late final LocalVaultAuthenticator _vaultAuthenticator =
      LocalVaultAuthenticator();

  String? get _banner => _bannerValue;

  set _banner(String? message) {
    _bannerValue = message;
    _bannerKind = _NoticeKind.info;
  }

  void _setPersistentNotice(
    String? message, {
    _NoticeKind kind = _NoticeKind.info,
  }) {
    if (_captureSettingsNotices) {
      if (message != null && kind != _NoticeKind.progress) {
        _capturedSettingsFeedback = _SettingsFeedback(
          message: message,
          kind: kind,
        );
      }
      return;
    }
    _bannerValue = message;
    _bannerKind = kind;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mailRepository = widget.mailRepository;
    unawaited(_loadSystemBehaviorSettings());
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _automaticMailRefreshTimer?.cancel();
    _mailPushDebounce?.cancel();
    _stopMailPush();
    unawaited(_androidBackgroundSync.stop());
    unawaited(_flushPendingMailActions());
    unawaited(SocketMailTransport.disposeConnections());
    unawaited(_trayService.dispose());
    _mobileMessageNotifiers.clear();
    _messageBodyLoads.clear();
    _searchFocusNode.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (!_appIsInForeground) break;
        _appIsInForeground = false;
        unawaited(_flushPendingMailActions());
        if (_mailSyncContinuesInBackground) {
          // Desktop windows hidden in the tray (or minimized) and Android with
          // the background service keep polling so notifications still fire.
          break;
        }
        _syncAutomaticMailRefresh();
        // Mobile platforms drop idle sockets in the background anyway; release
        // pooled IMAP connections so we reconnect cleanly on resume.
        unawaited(SocketMailTransport.disposeConnections());
        break;
      case AppLifecycleState.resumed:
        // Focus changes on desktop go inactive -> resumed; only a return from
        // the background needs a catch-up refresh.
        if (_appIsInForeground) break;
        final syncedWhileAway = _mailSyncContinuesInBackground;
        _appIsInForeground = true;
        _syncAutomaticMailRefresh();
        unawaited(
          _refreshMailboxAutomatically(forceFullRefresh: !syncedWhileAway),
        );
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _showTransientNotice(
    String message, {
    _NoticeKind kind = _NoticeKind.info,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!mounted) return;
    if (_captureSettingsNotices) {
      _capturedSettingsFeedback = _SettingsFeedback(
        message: message,
        kind: kind,
      );
      return;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isError = kind == _NoticeKind.error;
    final isWarning = kind == _NoticeKind.warning;
    final messenger = ScaffoldMessenger.of(context);
    if (!_mailUndoSnackBarVisible) {
      messenger.hideCurrentSnackBar();
    }
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: duration,
        backgroundColor:
            isError
                ? colorScheme.error
                : isWarning
                ? colorScheme.tertiaryContainer
                : null,
        content: Row(
          children: [
            Icon(
              switch (kind) {
                _NoticeKind.success => Icons.check_circle_outline,
                _NoticeKind.warning => Icons.warning_amber_outlined,
                _NoticeKind.error => Icons.error_outline,
                _NoticeKind.progress => Icons.sync,
                _NoticeKind.info => Icons.info_outline,
              },
              color:
                  isError
                      ? colorScheme.onError
                      : isWarning
                      ? colorScheme.onTertiaryContainer
                      : colorScheme.inversePrimary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style:
                    isError
                        ? TextStyle(color: colorScheme.onError)
                        : isWarning
                        ? TextStyle(color: colorScheme.onTertiaryContainer)
                        : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadSystemBehaviorSettings() async {
    try {
      final settings = await _systemSettingsStore.load();
      if (!mounted) return;
      setState(() => _systemSettings = settings);
      await _applySystemBehaviorSettings(settings);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _setPersistentNotice(
          'Could not load system settings: $error',
          kind: _NoticeKind.error,
        ),
      );
    }
  }

  Future<void> _setSystemBehaviorSettings(
    SystemBehaviorSettings settings,
  ) async {
    await _systemSettingsStore.save(settings);
    if (!mounted) return;
    setState(() => _systemSettings = settings);
    await _applySystemBehaviorSettings(settings);
  }

  Future<void> _applySystemBehaviorSettings(
    SystemBehaviorSettings settings,
  ) async {
    await _trayService.configure(
      enabled: settings.minimizeToTray,
      onShow: _showMainWindowFromSystemSurface,
      onRefresh: () => _loadMessages(resetLimit: true),
      onCheckUpdates: () => _checkUpdates(),
    );
    await _notificationService.configure(
      enabled: settings.newMailNotifications,
      onNotificationSelected: _handleNotificationSelected,
    );
    if (settings.newMailNotifications) {
      await _notificationService.ensureAccountChannels([
        for (final account in _accounts)
          NewMailNotificationAccount(
            id: account.id,
            label: _notificationAccountLabel(account.id) ?? account.address,
          ),
      ]);
    }
    if (!settings.openMessageFromNotification) {
      _pendingNotificationMessageId = null;
    }
    _syncAutomaticMailRefresh();
  }

  Future<void> _showMainWindowFromSystemSurface() async {
    await _trayService.showWindow();
  }

  Future<void> _handleNotificationSelected(String? payload) async {
    await _showMainWindowFromSystemSurface();
    if (!mounted || !_systemSettings.openMessageFromNotification) return;
    final messageId = notificationMessageIdFromPayload(payload);
    if (messageId == null) return;
    _pendingNotificationMessageId = messageId;
    await _openPendingNotificationMessageIfReady();
  }

  Future<void> _openPendingNotificationMessageIfReady() async {
    final messageId = _pendingNotificationMessageId;
    if (messageId == null ||
        _openingNotificationMessage ||
        !_hasUnlockedLocalVault ||
        _loading) {
      return;
    }

    _openingNotificationMessage = true;
    try {
      MailMessage? target = _messageForId(_messages, messageId);
      MailMessagePage? targetPage;
      const targetView = MailboxView.smart(MailSmartFolder.allIncoming);

      if (target == null) {
        targetPage = await _mailRepository.cachedViewPage(
          view: targetView,
          limit: _notificationMessageLookupLimit,
        );
        target = _messageForId(
          _visibleMessagesForDisplay(targetPage.messages),
          messageId,
        );
      }

      if (target == null) {
        targetPage = await _loadRemoteViewPage(
          view: targetView,
          limit: _notificationMessageLookupLimit,
        );
        target = _messageForId(
          _visibleMessagesForDisplay(targetPage.messages),
          messageId,
        );
      }

      if (!mounted || _pendingNotificationMessageId != messageId) return;
      if (target == null) {
        _pendingNotificationMessageId = null;
        _showTransientNotice(
          'The message from this notification is no longer available.',
          kind: _NoticeKind.warning,
        );
        return;
      }

      if (!_messages.any((message) => message.id == messageId)) {
        final messages = _visibleMessagesForDisplay(targetPage!.messages);
        setState(() {
          _search.clear();
          _view = targetView;
          _selectedAccountId = null;
          _messages = messages;
          _selectedMessageIds = const <String>{};
          _hasMoreMessages = targetPage!.hasMore;
        });
        target = _messageForId(messages, messageId)!;
      }

      _pendingNotificationMessageId = null;
      Navigator.of(context).popUntil((route) => route.isFirst);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      if (_readerPaneVisible) {
        _selectMessage(target);
      } else {
        unawaited(_openMobileMessage(target));
      }
    } catch (error) {
      if (!mounted || _pendingNotificationMessageId != messageId) return;
      _pendingNotificationMessageId = null;
      debugPrint('[NyaMail notifications] could not open message: $error');
      _showTransientNotice(
        'Could not open the message from this notification.',
        kind: _NoticeKind.warning,
      );
    } finally {
      _openingNotificationMessage = false;
      if (mounted && _pendingNotificationMessageId != null) {
        unawaited(_openPendingNotificationMessageIfReady());
      }
    }
  }

  Future<void> _bootstrap() async {
    try {
      await _bootstrapLocal();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _vaultUnlocking = false;
        _setPersistentNotice(
          'Could not start NyaMail: $error',
          kind: _NoticeKind.error,
        );
      });
    }
  }

  Future<void> _bootstrapLocal() async {
    final renderSettings = await const MailRenderSettingsStore().load();
    final interactionSettings =
        await const MailInteractionSettingsStore().load();
    var profile = await widget.secureStore.readLocalProfile();
    if (profile == null) {
      if (!mounted) return;
      setState(() {
        _renderSettings = renderSettings;
        _interactionSettings = interactionSettings;
        _pinnedMessageIds = interactionSettings.pinnedMessageIds.toSet();
        _loading = false;
        _vaultUnlocking = false;
        _setPersistentNotice(
          'Create a local encrypted vault before using NyaMail.',
          kind: _NoticeKind.warning,
        );
      });
      return;
    }

    _profile = profile;
    _draftCache = _draftCacheForProfile(profile);
    final unlocked = await _tryUnlockLocalVault(profile, promptIfNeeded: false);
    if (!unlocked) {
      if (!mounted) return;
      setState(() {
        _renderSettings = renderSettings;
        _interactionSettings = interactionSettings;
        _pinnedMessageIds = interactionSettings.pinnedMessageIds.toSet();
        _loading = false;
        _vaultUnlocking = false;
        if (_banner == null) {
          _setPersistentNotice(
            'Unlock the local vault before using NyaMail.',
            kind: _NoticeKind.warning,
          );
        }
      });
      return;
    }
    await _finishLocalBootstrap(
      renderSettings: renderSettings,
      interactionSettings: interactionSettings,
      profile: profile,
    );
  }

  Future<void> _finishLocalBootstrap({
    required MailRenderSettings renderSettings,
    required MailInteractionSettings interactionSettings,
    required LocalProfile profile,
    String? banner,
  }) async {
    _debugVault('finish bootstrap: start');
    final session = await widget.secureStore.readSession();
    if (session != null) {
      _session = session;
    }
    final document = _vaultDocument;
    final accounts = _localAccountsForDocument(document);
    final folders = _locallyAvailableFoldersForDocument(document);
    final activeView = _activeViewFor(folders);
    _debugVault('finish bootstrap: loading cached page');
    final page = await _mailRepository.cachedViewPage(
      view: activeView,
      limit: _messagePageSize,
    );
    final pinnedMessageIds = interactionSettings.pinnedMessageIds.toSet();
    final messages = _visibleMessagesForDisplay(
      page.messages,
      pinnedMessageIds: pinnedMessageIds,
    );
    _debugVault(
      'finish bootstrap: cached page ready (${page.messages.length} messages)',
    );
    if (!mounted) return;
    final activeProfile = _profile ?? profile;
    setState(() {
      _session = session;
      _profile = activeProfile;
      _accounts = accounts;
      _folders = folders;
      _view = activeView;
      _selectedAccountId = activeView.folder?.accountId;
      _messages = messages;
      _selected = _messageFor(messages, _selected?.id, fallbackToFirst: false);
      _renderSettings = renderSettings;
      _interactionSettings = interactionSettings;
      _pinnedMessageIds = pinnedMessageIds;
      _selectedMessageIds = const <String>{};
      _hasMoreMessages = page.hasMore;
      _loading = false;
      _vaultUnlocking = false;
      _banner = banner;
    });
    _debugVault('finish bootstrap: unlocked frame ready');
    _resetNewMailNotificationBaseline();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPendingNotificationMessageIfReady());
    });
    final requestId = _nextMessageLoadGeneration();
    _pendingStartupMailboxWork++;
    unawaited(
      _finishLocalBootstrapNetworkWork(requestId: requestId, session: session),
    );
  }

  Future<void> _finishLocalBootstrapNetworkWork({
    required int requestId,
    required LocalSession? session,
  }) async {
    try {
      // Keep the first unlocked frame local-only, then avoid competing IMAP work.
      await _refreshMessagesInBackground(
        requestId: requestId,
        suppressNewMailNotifications: true,
        completeStartupNotificationBaseline:
            _viewCanPrimeNewMailNotificationBaseline(),
      );
      if (!mounted) return;
      if (_systemSettings.newMailNotifications &&
          _newMailNotificationBaseline.startupPending) {
        await _pollNewMailForNotifications();
      }
      if (!mounted) return;
      await _discoverFoldersInBackground();
      if (!mounted) return;
      if (session != null) {
        await _tryUnlockStoredVault(session);
      }
      if (!mounted) return;
      await _checkUpdates(silent: true);
    } finally {
      _pendingStartupMailboxWork--;
      if (mounted && _pendingStartupMailboxWork == 0) {
        _syncAutomaticMailRefresh();
        if (_mailPushRefreshQueued) unawaited(_runQueuedMailPushRefresh());
      }
    }
  }

  /// Whether mail polling (and IDLE push) keeps running while the window is
  /// hidden. Desktop processes stay alive in the tray or when minimized; on
  /// Android only the opt-in foreground service keeps the process alive.
  bool get _mailSyncContinuesInBackground {
    if (kIsWeb) return false;
    if (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS) {
      return true;
    }
    return io.Platform.isAndroid && _androidBackgroundSyncWanted;
  }

  /// Background sync on Android only matters for notifications.
  bool get _androidBackgroundSyncWanted =>
      _systemSettings.androidBackgroundSync &&
      _systemSettings.newMailNotifications;

  void _syncAndroidBackgroundService() {
    if (!AndroidBackgroundSync.isSupported) return;
    final wanted =
        _androidBackgroundSyncWanted &&
        _hasUnlockedLocalVault &&
        _accounts.isNotEmpty;
    if (wanted && !_androidBackgroundSync.isRunning && _appIsInForeground) {
      // Android only allows starting it from the foreground; a refused start
      // is retried the next time the app comes back.
      unawaited(_androidBackgroundSync.start());
    } else if (!wanted && _androidBackgroundSync.isRunning) {
      unawaited(_androidBackgroundSync.stop());
    }
  }

  bool get _mailSyncAllowed =>
      _appIsInForeground || _mailSyncContinuesInBackground;

  void _syncAutomaticMailRefresh() {
    _syncAndroidBackgroundService();
    _syncMailPush();
    final active =
        _pendingStartupMailboxWork == 0 &&
        _mailSyncAllowed &&
        _hasUnlockedLocalVault &&
        _accounts.isNotEmpty;
    // With IDLE push up for every account, polling is only a safety net.
    final interval =
        _mailPushCoversAllAccounts
            ? _pushBackedMailRefreshInterval
            : _automaticMailRefreshInterval;
    if (active &&
        _automaticMailRefreshTimer != null &&
        _automaticMailRefreshTimerInterval == interval) {
      return;
    }
    _automaticMailRefreshTimer?.cancel();
    _automaticMailRefreshTimer = null;
    _automaticMailRefreshTimerInterval = null;
    if (!active) return;
    _automaticMailRefreshTimerInterval = interval;
    _automaticMailRefreshTimer = Timer.periodic(
      interval,
      (_) => unawaited(_refreshMailboxAutomatically()),
    );
  }

  bool get _mailPushCoversAllAccounts {
    if (_accounts.isEmpty) return false;
    return _accounts.every(
      (account) => _mailPushStates[account.id] == ImapIdleState.idling,
    );
  }

  void _syncMailPush() {
    final wanted =
        _mailSyncAllowed && _hasUnlockedLocalVault
            ? {for (final account in _accounts) account.id}
            : const <String>{};
    for (final accountId in _mailPushWatchers.keys.toList()) {
      if (wanted.contains(accountId)) continue;
      _mailPushWatchers.remove(accountId)?.stop();
      _mailPushStates.remove(accountId);
    }
    for (final accountId in wanted) {
      if (_mailPushWatchers.containsKey(accountId) ||
          _mailPushUnsupported.contains(accountId)) {
        continue;
      }
      final watcher = ImapIdleWatcher(
        accountId: accountId,
        credential: () => _pushCredentialFor(accountId),
        onMailboxChanged: _handleMailPush,
        onStateChanged: (state) {
          if (!mounted) return;
          _mailPushStates[accountId] = state;
          if (state == ImapIdleState.unsupported) {
            _mailPushUnsupported.add(accountId);
            _mailPushWatchers.remove(accountId);
          }
          _syncAutomaticMailRefresh();
        },
      );
      _mailPushWatchers[accountId] = watcher;
      watcher.start();
    }
  }

  void _stopMailPush() {
    for (final watcher in _mailPushWatchers.values) {
      watcher.stop();
    }
    _mailPushWatchers.clear();
    _mailPushStates.clear();
  }

  Future<MailboxCredential?> _pushCredentialFor(String accountId) async {
    try {
      await _refreshOAuthVaultIfNeeded();
    } catch (error) {
      debugPrint('[NyaMail push] OAuth refresh failed: $error');
    }
    if (!mounted) return null;
    final document = _vaultDocument;
    if (document == null) return null;
    for (final credential in document.toCredentials()) {
      if (credential.accountId == accountId) return credential;
    }
    return null;
  }

  void _handleMailPush() {
    if (!mounted) return;
    // Servers often send EXISTS and FETCH lines in quick bursts; coalesce them.
    _mailPushDebounce?.cancel();
    _mailPushDebounce = Timer(_mailPushDebounceDelay, () {
      _mailPushRefreshQueued = true;
      unawaited(_runQueuedMailPushRefresh());
    });
  }

  Future<void> _runQueuedMailPushRefresh() async {
    if (!mounted || !_mailPushRefreshQueued) return;
    if (_automaticMailRefreshInProgress || _refreshingMail) {
      // Picked up again when the running refresh finishes.
      return;
    }
    _mailPushRefreshQueued = false;
    await _refreshMailboxAutomatically();
  }

  Future<void> _refreshMailboxAutomatically({
    bool forceFullRefresh = false,
  }) async {
    if (!_mailSyncAllowed ||
        _automaticMailRefreshInProgress ||
        _refreshingMail ||
        _pendingStartupMailboxWork > 0 ||
        !_hasUnlockedLocalVault ||
        _accounts.isEmpty) {
      return;
    }
    _automaticMailRefreshInProgress = true;
    // An IDLE push can wake a dozing phone just long enough to deliver the
    // packet; hold the CPU until the refresh and its notifications are done.
    final holdsWakeLock =
        !_appIsInForeground && _androidBackgroundSync.isRunning;
    if (holdsWakeLock) {
      await _androidBackgroundSync.acquireWakeLock(const Duration(minutes: 1));
    }
    try {
      final requestId = _nextMessageLoadGeneration();
      final completesNotificationBaseline =
          _systemSettings.newMailNotifications &&
          _newMailNotificationBaseline.startupPending &&
          _viewCanPrimeNewMailNotificationBaseline();
      await _refreshMessagesInBackground(
        requestId: requestId,
        completeStartupNotificationBaseline: completesNotificationBaseline,
        showRefreshIndicator: false,
        forceFullRefresh: forceFullRefresh,
      );
      if (!mounted) return;
      if (_systemSettings.newMailNotifications &&
          (!_viewCanPrimeNewMailNotificationBaseline() ||
              _newMailNotificationBaseline.startupPending)) {
        await _pollNewMailForNotifications();
      }
    } finally {
      _automaticMailRefreshInProgress = false;
      if (holdsWakeLock) unawaited(_androidBackgroundSync.releaseWakeLock());
      if (_mailPushRefreshQueued) unawaited(_runQueuedMailPushRefresh());
    }
  }

  Future<void> _pollNewMailForNotifications() async {
    if (_pollingNewMail ||
        !_systemSettings.newMailNotifications ||
        !_hasUnlockedLocalVault ||
        _accounts.isEmpty) {
      return;
    }
    _pollingNewMail = true;
    try {
      final page = await _loadRemoteViewPage(
        view: const MailboxView.smart(MailSmartFolder.allIncoming),
        limit: _messagePageSize,
      );
      await _notifyForNewIncomingMail(
        page.messages,
        completeStartupBaseline: true,
      );
    } catch (error) {
      debugPrint('[NyaMail notifications] new mail poll failed: $error');
    } finally {
      _pollingNewMail = false;
    }
  }

  Future<MailMessagePage> _loadRemoteViewPage({
    required MailboxView view,
    String? query,
    required int limit,
    bool forceFullRefresh = false,
  }) async {
    Future<MailMessagePage> load() {
      final repository = _mailRepository;
      if (forceFullRefresh && repository is FullRefreshMailRepository) {
        return (repository as FullRefreshMailRepository).fullRefreshViewPage(
          view: view,
          query: query,
          limit: limit,
        );
      }
      return repository.viewPage(view: view, query: query, limit: limit);
    }

    await _refreshOAuthVaultIfNeeded();
    try {
      final page = await load().timeout(_mailRefreshTimeout);
      return _retryPageAfterTargetedOAuthRefresh(page, load);
    } catch (error) {
      if (!looksLikeMailAuthenticationFailure(error)) rethrow;
      await _refreshOAuthVaultIfNeeded(force: true);
      return load().timeout(_mailRefreshTimeout);
    }
  }

  Future<MailMessagePage> _loadOlderRemoteViewPage({
    required MailboxView view,
    String? query,
    required int visibleCount,
    required int limit,
  }) async {
    await _refreshOAuthVaultIfNeeded();
    try {
      Future<MailMessagePage> load() {
        return _mailRepository
            .loadOlderViewMessages(
              view: view,
              query: query,
              visibleCount: visibleCount,
              limit: limit,
            )
            .timeout(_mailLoadMoreTimeout);
      }

      final page = await load();
      return _retryPageAfterTargetedOAuthRefresh(page, load);
    } catch (error) {
      if (!looksLikeMailAuthenticationFailure(error)) rethrow;
      await _refreshOAuthVaultIfNeeded(force: true);
      return _mailRepository
          .loadOlderViewMessages(
            view: view,
            query: query,
            visibleCount: visibleCount,
            limit: limit,
          )
          .timeout(_mailLoadMoreTimeout);
    }
  }

  Future<MailMessagePage> _retryPageAfterTargetedOAuthRefresh(
    MailMessagePage page,
    Future<MailMessagePage> Function() load,
  ) async {
    final accountIds = {
      for (final failure in page.accountFailures)
        if (failure.authenticationRequired) failure.accountId,
    };
    if (accountIds.isEmpty) return page;
    final refresh = await _refreshOAuthVaultIfNeeded(
      force: true,
      accountIds: accountIds,
    );
    if (refresh == null ||
        refresh.refreshedItemIds.intersection(accountIds).isEmpty) {
      return page;
    }
    return load();
  }

  void _primeNewMailNotificationBaseline(
    Iterable<MailMessage> messages, {
    bool completeStartupBaseline = false,
  }) {
    final incomingUnread = messages.where(_isNotifiableIncomingUnread);
    if (completeStartupBaseline) {
      _newMailNotificationBaseline.freshMessages(
        incomingUnread,
        completeStartupBaseline: true,
      );
      return;
    }
    _newMailNotificationBaseline.prime(incomingUnread);
  }

  bool _viewCanPrimeNewMailNotificationBaseline() {
    return _search.text.trim().isEmpty &&
        _view.folder == null &&
        _view.smartFolder == MailSmartFolder.allIncoming;
  }

  void _resetNewMailNotificationBaseline() {
    _newMailNotificationBaseline.reset();
  }

  Future<void> _notifyForNewIncomingMail(
    List<MailMessage> messages, {
    bool completeStartupBaseline = false,
  }) async {
    final fresh = _newMailNotificationBaseline.freshMessages(
      messages.where(_isNotifiableIncomingUnread),
      completeStartupBaseline: completeStartupBaseline,
    );
    if (!_systemSettings.newMailNotifications || fresh.isEmpty) return;
    fresh.sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    final grouping = _systemSettings.notificationGrouping;

    final byAccount = <String, List<MailMessage>>{};
    for (final message in fresh) {
      byAccount.putIfAbsent(message.accountId, () => []).add(message);
    }

    for (final message in fresh) {
      final content = MailNotificationContent.fromMessage(message);
      await _notificationService.showNewMail(
        notificationKey: message.id,
        title: content.title,
        body: content.body,
        accountLabel: _notificationAccountLabel(message.accountId),
        accountId: message.accountId,
        payload: message.id,
        grouping: grouping,
      );
    }

    if (grouping == NotificationGrouping.individual) return;
    if (grouping == NotificationGrouping.perAccount) {
      for (final entry in byAccount.entries) {
        await _notificationService.showNewMailSummary(
          messageCount: entry.value.length,
          lines: _notificationSummaryLines(entry.value),
          accountLabel: _notificationAccountLabel(entry.key),
          accountId: entry.key,
          grouping: grouping,
        );
      }
      return;
    }
    // stack: one summary across every account.
    await _notificationService.showNewMailSummary(
      messageCount: fresh.length,
      lines: _notificationSummaryLines(fresh),
      accountLabel:
          byAccount.length == 1
              ? _notificationAccountLabel(fresh.first.accountId)
              : null,
      grouping: grouping,
    );
  }

  List<String> _notificationSummaryLines(List<MailMessage> messages) {
    final ordered = [...messages]
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return [
      for (final message in ordered.take(6))
        () {
          final content = MailNotificationContent.fromMessage(message);
          final firstBodyLine = content.body.split('\n').first.trim();
          return firstBodyLine.isEmpty
              ? content.title
              : '${content.title}: $firstBodyLine';
        }(),
    ];
  }

  bool _isNotifiableIncomingUnread(MailMessage message) {
    return !message.read &&
        mailMessageMatchesSmartFolder(message, MailSmartFolder.allIncoming);
  }

  String? _notificationAccountLabel(String accountId) {
    for (final account in _accounts) {
      if (account.id != accountId) continue;
      final displayName = account.displayName.trim();
      return displayName.isEmpty ? account.address : displayName;
    }
    return null;
  }

  Future<bool> _tryUnlockLocalVault(
    LocalProfile profile, {
    bool promptIfNeeded = false,
  }) async {
    try {
      _debugVault(
        'local unlock: start (${promptIfNeeded ? 'prompt' : 'silent'})',
      );
      if (promptIfNeeded) {
        _vaultUnlockCancelled = false;
      }
      final vaultSecret = await _unlockVaultSecretForProfile(
        profile,
        promptIfNeeded: promptIfNeeded,
      );
      if (vaultSecret == null || vaultSecret.trim().isEmpty) {
        if (_vaultUnlockCancelled) {
          _vaultUnlockCancelled = false;
          return false;
        }
        if (promptIfNeeded && mounted) {
          final currentBanner = _banner;
          if (currentBanner == null ||
              currentBanner == 'Preparing local vault...' ||
              currentBanner == 'Unlocking local vault...') {
            setState(
              () => _setPersistentNotice(
                'Local vault exists, but this device cannot unlock it.',
                kind: _NoticeKind.error,
              ),
            );
          }
        }
        return false;
      }
      _debugVault('local unlock: secret ready');
      final result = await loadOrMigrateLocalVaultDocument(
        profileId: profile.id,
        profileEmail: profile.email,
        vaultSecret: vaultSecret,
        recordStore: widget.localVaultRecordStore,
        legacyStore: widget.localVaultStore,
        recordCrypto: widget.vaultRecordCrypto,
        vaultCrypto: widget.vaultCrypto,
      );
      _vaultRecordRevision = result.recordRevision;
      await _applyVaultDocument(
        result.document,
        loadMessages: false,
        discoverFolders: false,
      );
      _debugVault(
        result.migratedLegacyVault
            ? 'local unlock: legacy vault migrated to records'
            : result.createdRecordVault
            ? 'local unlock: empty record vault created'
            : 'local unlock: record vault applied',
      );
      if (promptIfNeeded) {
        await _migrateLegacyVaultSecretIfNeeded(vaultSecret);
      }
      return true;
    } on VaultCryptoException catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(error.message, kind: _NoticeKind.error),
        );
      }
      return false;
    } on FormatException catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Local vault data is not readable. Clear local data or reconnect sync. (${error.message})',
            kind: _NoticeKind.error,
          ),
        );
      }
      return false;
    } catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not unlock local vault: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
      return false;
    }
  }

  Future<void> _tryUnlockStoredVault(LocalSession session) async {
    try {
      final vault = await widget.api.getVault(session.accessToken);
      if (vault == null) {
        await _syncVaultRecordsWithServer(silent: true);
        return;
      }
      final vaultSecret = await _readUnlockedVaultSecret();
      final loginPassword = await _LoginPasswordMemory.read();
      if (vaultSecret == null && loginPassword == null) return;
      final document = await widget.vaultCrypto.decryptDocument(
        blob: vault.blob,
        email: session.email,
        password: loginPassword ?? '',
        vaultSecret: vaultSecret,
      );
      final profile = _profile ?? await _ensureLocalProfile();
      if (profile != null) {
        await _saveLocalVaultDocument(profile: profile, document: document);
      }
      await _applyVaultDocument(
        document,
        loadMessages: false,
        discoverFolders: false,
      );
      await _syncVaultRecordsWithServer(silent: true);
      await _refreshOAuthVaultIfNeeded();
    } catch (error) {
      _debugVault('stored server vault unlock failed', error);
      if (!mounted) return;
      if (_hasUnlockedLocalVault) {
        setState(
          () => _setPersistentNotice(
            'Sync account connected. Server vault sync will retry later.',
            kind: _NoticeKind.warning,
          ),
        );
        return;
      }
      setState(
        () => _setPersistentNotice(
          'Signed in, but server vault could not be opened.',
          kind: _NoticeKind.error,
        ),
      );
    }
  }

  Future<String?> _readUnlockedVaultSecret({
    bool includeLegacySecret = true,
  }) async {
    final secret = _unlockedVaultSecret;
    if (secret != null && secret.trim().isNotEmpty) return secret;
    if (!includeLegacySecret) return null;
    final legacySecret = await widget.secureStore.readVaultSecret();
    if (legacySecret == null || legacySecret.trim().isEmpty) return null;
    _setUnlockedVaultSecret(legacySecret);
    return legacySecret;
  }

  void _setUnlockedVaultSecret(String vaultSecret, {String? password}) {
    _unlockedVaultSecret = vaultSecret;
    if (password != null && password.isNotEmpty) {
      _unlockedVaultPassword = password;
    }
  }

  Future<String?> _unlockVaultSecretForProfile(
    LocalProfile profile, {
    required bool promptIfNeeded,
  }) async {
    final inMemory = await _readUnlockedVaultSecret(includeLegacySecret: false);
    if (inMemory != null && inMemory.trim().isNotEmpty) return inMemory;

    final legacySecret = await _readUnlockedVaultSecret();
    if (legacySecret != null && legacySecret.trim().isNotEmpty) {
      return legacySecret;
    }
    if (!promptIfNeeded || !mounted) return null;

    final envelope = await widget.secureStore.readVaultSecretEnvelope();
    if (envelope == null) return null;
    final quickUnlockAvailable = await _vaultAuthenticator.isAvailable();
    final quickUnlockMethod =
        await widget.secureStore.readQuickUnlockMethod() ??
        _vaultAuthenticator.methodLabel;
    final quickUnlockEnabled = await _hasQuickUnlockMaterial();
    if (!mounted) return null;
    final input = await showDialog<_LocalVaultUnlockInput>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => _LocalVaultUnlockDialog(
            profile: profile,
            quickUnlockAvailable: quickUnlockAvailable && quickUnlockEnabled,
            quickUnlockMethod: quickUnlockMethod,
          ),
    );
    if (input == null) {
      _vaultUnlockCancelled = true;
      return null;
    }
    if (input.useQuickUnlock) {
      return _tryQuickUnlockVaultSecret(
        profile: profile,
        reason: 'Authenticate to unlock your NyaMail vault.',
      );
    }
    final password = input.password;
    if (password == null || password.isEmpty) return null;
    final unlocked = await widget.vaultCrypto.unwrapVaultSecret(
      blob: envelope,
      password: password,
    );
    _setUnlockedVaultSecret(unlocked, password: password);
    return unlocked;
  }

  Future<String?> _tryQuickUnlockVaultSecret({
    required LocalProfile profile,
    required String reason,
  }) async {
    final quickEnvelope = await widget.secureStore.readQuickUnlockEnvelope();
    final quickKey = await widget.secureStore.readQuickUnlockKey();
    final legacyQuickSecret = await widget.secureStore.readQuickUnlockSecret();
    final hasEnvelope =
        quickEnvelope != null && quickKey != null && quickKey.trim().isNotEmpty;
    final hasLegacy =
        legacyQuickSecret != null && legacyQuickSecret.trim().isNotEmpty;
    if (!hasEnvelope && !hasLegacy) return null;
    if (!await _vaultAuthenticator.isAvailable()) return null;
    final authenticated = await _vaultAuthenticator.authenticate(
      reason: reason,
    );
    if (!authenticated) {
      _vaultUnlockCancelled = true;
      if (mounted) {
        _showTransientNotice('System quick unlock was cancelled.');
      }
      return null;
    }
    if (hasEnvelope) {
      try {
        final vaultSecret = await widget.vaultCrypto
            .unwrapVaultSecretForQuickUnlock(
              blob: quickEnvelope,
              quickUnlockKey: quickKey,
              profileId: profile.id,
            );
        _setUnlockedVaultSecret(vaultSecret);
        return vaultSecret;
      } catch (error) {
        if (mounted) {
          setState(
            () => _setPersistentNotice(
              'System quick unlock failed. Use the vault password. ($error)',
              kind: _NoticeKind.error,
            ),
          );
        }
        return null;
      }
    }
    final legacyVaultSecret = legacyQuickSecret;
    if (legacyVaultSecret == null || legacyVaultSecret.trim().isEmpty) {
      return null;
    }
    _setUnlockedVaultSecret(legacyVaultSecret);
    try {
      await _saveQuickUnlockMaterial(
        profile: profile,
        vaultSecret: legacyVaultSecret,
        method:
            await widget.secureStore.readQuickUnlockMethod() ??
            _vaultAuthenticator.methodLabel,
      );
    } catch (_) {
      // Legacy quick unlock should still work even if migration is blocked.
    }
    return legacyQuickSecret;
  }

  Future<void> _saveWrappedVaultSecret({
    required String vaultSecret,
    required String password,
  }) async {
    final envelope = await widget.vaultCrypto.wrapVaultSecret(
      vaultSecret: vaultSecret,
      password: password,
    );
    await widget.secureStore.saveVaultSecretEnvelope(envelope);
    await widget.secureStore.clearVaultSecret();
  }

  Future<bool> _hasQuickUnlockMaterial() async {
    final quickEnvelope = await widget.secureStore.readQuickUnlockEnvelope();
    final quickKey = await widget.secureStore.readQuickUnlockKey();
    if (quickEnvelope != null &&
        quickKey != null &&
        quickKey.trim().isNotEmpty) {
      return true;
    }
    final legacyQuickSecret = await widget.secureStore.readQuickUnlockSecret();
    return legacyQuickSecret != null && legacyQuickSecret.trim().isNotEmpty;
  }

  Future<void> _saveQuickUnlockMaterial({
    required LocalProfile profile,
    required String vaultSecret,
    String? method,
  }) async {
    final quickKey = widget.vaultCrypto.newQuickUnlockKey();
    final envelope = await widget.vaultCrypto.wrapVaultSecretForQuickUnlock(
      vaultSecret: vaultSecret,
      quickUnlockKey: quickKey,
      profileId: profile.id,
    );
    await widget.secureStore.saveQuickUnlockMaterial(
      quickUnlockKey: quickKey,
      envelope: envelope,
      method: method ?? _vaultAuthenticator.methodLabel,
    );
  }

  Future<void> _refreshQuickUnlockSecretIfEnabled({
    required LocalProfile profile,
    required String vaultSecret,
  }) async {
    if (!await _hasQuickUnlockMaterial()) return;
    await _saveQuickUnlockMaterial(
      profile: profile,
      vaultSecret: vaultSecret,
      method:
          await widget.secureStore.readQuickUnlockMethod() ??
          _vaultAuthenticator.methodLabel,
    );
  }

  Future<void> _migrateLegacyVaultSecretIfNeeded(String vaultSecret) async {
    final legacySecret = await widget.secureStore.readVaultSecret();
    if (legacySecret == null ||
        legacySecret.trim().isEmpty ||
        legacySecret != vaultSecret) {
      return;
    }
    final existingEnvelope = await widget.secureStore.readVaultSecretEnvelope();
    if (existingEnvelope != null || !mounted) return;
    final input = await showDialog<_VaultPasswordInput>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => const _VaultPasswordDialog(
            title: 'Set vault password',
            message: 'Protect this existing local vault with a password.',
            confirmPassword: true,
          ),
    );
    if (input == null) return;
    await _saveWrappedVaultSecret(
      vaultSecret: vaultSecret,
      password: input.password,
    );
    _setUnlockedVaultSecret(vaultSecret, password: input.password);
  }

  Future<bool> _enableQuickUnlockForSecret({
    required LocalProfile profile,
    required String vaultSecret,
  }) async {
    if (!await _vaultAuthenticator.isAvailable()) return false;
    final authenticated = await _vaultAuthenticator.authenticate(
      reason: 'Authenticate to enable quick unlock for your NyaMail vault.',
    );
    if (!authenticated) return false;
    await _saveQuickUnlockMaterial(
      profile: profile,
      vaultSecret: vaultSecret,
      method: _vaultAuthenticator.methodLabel,
    );
    return true;
  }

  Future<LocalProfile?> _createLocalVault() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return null;
    final quickUnlockAvailable = await _vaultAuthenticator.isAvailable();
    if (!mounted) return null;
    final input = await showDialog<_LocalVaultCreationInput>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => _LocalVaultCreationDialog(
            quickUnlockAvailable: quickUnlockAvailable,
            quickUnlockMethod: _vaultAuthenticator.methodLabel,
          ),
    );
    if (input == null) return null;

    final vaultSecret = widget.vaultCrypto.newVaultSecret();
    final profile = LocalProfile(
      id: _newLocalProfileId(),
      displayName:
          input.displayName.trim().isEmpty
              ? 'Personal vault'
              : input.displayName.trim(),
    );
    await _saveWrappedVaultSecret(
      vaultSecret: vaultSecret,
      password: input.password,
    );
    await widget.secureStore.clearQuickUnlockMaterial();
    await widget.secureStore.saveLocalProfile(profile);
    _setUnlockedVaultSecret(vaultSecret, password: input.password);
    _profile = profile;
    _draftCache = _draftCacheForProfile(profile, localCacheSecret: vaultSecret);

    final document = VaultDocument.empty();
    await _saveLocalVaultRecords(
      profile: profile,
      document: document,
      vaultSecret: vaultSecret,
    );
    _vaultDocument = document;

    final quickUnlockEnabled =
        input.enableQuickUnlock &&
        await _enableQuickUnlockForSecret(
          profile: profile,
          vaultSecret: vaultSecret,
        );
    await _applyVaultDocument(
      document,
      loadMessages: false,
      discoverFolders: false,
    );
    if (mounted) {
      setState(() => _banner = null);
      _showTransientNotice(
        quickUnlockEnabled
            ? 'Local encrypted vault is ready. Quick unlock is enabled.'
            : 'Local encrypted vault is ready.',
        kind: _NoticeKind.success,
      );
    }
    return profile;
  }

  Future<bool> _ensureVaultSecretWrapped({required String vaultSecret}) async {
    final profile = _profile ?? await _ensureLocalProfile();
    if (profile == null) return false;
    final currentPassword = _unlockedVaultPassword;
    if (currentPassword != null && currentPassword.length >= 12) {
      await _saveWrappedVaultSecret(
        vaultSecret: vaultSecret,
        password: currentPassword,
      );
      await _refreshQuickUnlockSecretIfEnabled(
        profile: profile,
        vaultSecret: vaultSecret,
      );
      return true;
    }
    if (!mounted) return false;
    final existingEnvelope = await widget.secureStore.readVaultSecretEnvelope();
    if (!mounted) return false;
    final input = await showDialog<_VaultPasswordInput>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => _VaultPasswordDialog(
            title:
                existingEnvelope == null
                    ? 'Set vault password'
                    : 'Confirm vault password',
            message:
                existingEnvelope == null
                    ? 'Set a vault password to protect this device.'
                    : 'Enter your vault password to store this vault access on this device.',
            confirmPassword: existingEnvelope == null,
          ),
    );
    if (input == null) return false;
    if (existingEnvelope != null) {
      await widget.vaultCrypto.unwrapVaultSecret(
        blob: existingEnvelope,
        password: input.password,
      );
    }
    await _saveWrappedVaultSecret(
      vaultSecret: vaultSecret,
      password: input.password,
    );
    await _refreshQuickUnlockSecretIfEnabled(
      profile: profile,
      vaultSecret: vaultSecret,
    );
    _setUnlockedVaultSecret(vaultSecret, password: input.password);
    return true;
  }

  Future<void> _checkUpdates({bool silent = false}) async {
    if (_checkingForUpdates) return;
    _checkingForUpdates = true;
    const checkingMessage = 'Checking for updates...';
    if (!silent && mounted) {
      setState(
        () => _setPersistentNotice(checkingMessage, kind: _NoticeKind.progress),
      );
    }
    try {
      final result = await widget.releaseService.check();
      if (!mounted) return;
      if (!silent && _banner == checkingMessage) {
        setState(() => _banner = null);
      }
      if (!result.updateAvailable || result.latest == null) {
        if (!silent) {
          _showTransientNotice('NyaMail is up to date.');
        }
        return;
      }
      final artifact = result.latest!;
      if (!await widget.releaseService.verifyManifestSignature(artifact)) {
        if (!mounted) return;
        setState(
          () => _setPersistentNotice(
            'Update manifest signature could not be verified.',
            kind: _NoticeKind.error,
          ),
        );
        return;
      }
      final label = _releaseLabel(artifact);
      if (silent) {
        setState(() => _banner = 'Update $label is available.');
        return;
      }
      final shouldInstall = await _confirmUpdateInstall(artifact);
      if (!mounted) return;
      if (!shouldInstall) {
        setState(() => _banner = 'Update $label is available.');
        return;
      }
      setState(
        () => _setPersistentNotice(
          'Downloading update $label...',
          kind: _NoticeKind.progress,
        ),
      );
      final file = await widget.releaseService.downloadAndVerify(artifact);
      await widget.releaseService.openDownloadedFile(file);
      if (!mounted) return;
      setState(() => _banner = null);
      _showTransientNotice(
        'Update downloaded, verified, and opened.',
        kind: _NoticeKind.success,
      );
    } catch (error) {
      if (!silent && mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not check for updates: ${_updateErrorMessage(error)}',
            kind: _NoticeKind.error,
          ),
        );
      }
    } finally {
      _checkingForUpdates = false;
    }
  }

  String _updateErrorMessage(Object error) {
    if (error is TimeoutException) {
      return 'GitHub did not respond within 15 seconds.';
    }
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return message.isEmpty ? 'the request timed out or failed.' : message;
  }

  Future<bool> _confirmUpdateInstall(ReleaseArtifact artifact) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: !artifact.force,
          builder:
              (dialogContext) => AlertDialog(
                title: Text(
                  artifact.force ? 'Required update' : 'Update available',
                ),
                content: _DialogContent(
                  width: 460,
                  maxHeight: 520,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'A new version is available. Review the release information, then download and install the matching platform package.',
                      ),
                      const SizedBox(height: 16),
                      _UpdateDetailRow(
                        label: 'Version',
                        value: _releaseLabel(artifact),
                      ),
                      _UpdateDetailRow(
                        label: 'Target',
                        value: '${artifact.platform}/${artifact.arch}',
                      ),
                      _UpdateDetailRow(
                        label: 'Channel',
                        value: artifact.channel,
                      ),
                      _UpdateDetailRow(
                        label: 'SHA-256',
                        value: _shortSha256(artifact.sha256),
                      ),
                      if (artifact.requiredVersion != null)
                        _UpdateDetailRow(
                          label: 'Requires',
                          value: artifact.requiredVersion!,
                        ),
                      if (artifact.notes.trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('Release notes'),
                        const SizedBox(height: 4),
                        Text(
                          artifact.notes.trim(),
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  if (!artifact.force)
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Later'),
                    ),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    icon: const Icon(Icons.download),
                    label: const Text('Download and install'),
                  ),
                ],
              ),
        ) ??
        false;
  }

  String _releaseLabel(ReleaseArtifact artifact) {
    return '${artifact.version}+${artifact.build}';
  }

  String _shortSha256(String value) {
    final hash = value.trim();
    if (hash.isEmpty) return 'not provided';
    if (hash.length <= 24) return hash;
    return '${hash.substring(0, 12)}...${hash.substring(hash.length - 8)}';
  }

  Future<void> _loadMessages({
    bool resetLimit = false,
    bool loadMore = false,
  }) async {
    if (loadMore) {
      await _loadMoreMessages();
      return;
    }
    // A user refresh supersedes any startup or automatic result. Repository
    // request sharing still coalesces repeated full refreshes.
    final requestId = _nextMessageLoadGeneration();
    if (resetLimit) {
      _hasMoreMessages = true;
    }
    _beginMailRefresh(requestId);
    try {
      await _showCachedMessages(
        requestId: requestId,
        resetSelection: resetLimit,
      );
      await _refreshMessagesInBackground(
        requestId: requestId,
        showErrors: true,
        preserveSelection: !resetLimit,
        showRefreshIndicator: false,
        forceFullRefresh: true,
      );
    } finally {
      _endMailRefresh(requestId);
    }
  }

  int _nextMessageLoadGeneration() => ++_messageLoadGeneration;

  bool _isCurrentMessageLoad(int requestId) =>
      mounted && requestId == _messageLoadGeneration;

  Future<void> _showCachedMessages({
    required int requestId,
    bool resetSelection = false,
  }) async {
    try {
      final page = await _mailRepository.cachedViewPage(
        view: _view,
        query: _search.text,
        limit: _messagePageSize,
      );
      if (!_isCurrentMessageLoad(requestId)) return;
      final messages = _visibleMessagesForDisplay(page.messages);
      setState(() {
        _messages = messages;
        _selected = _messageFor(
          messages,
          resetSelection ? null : _selected?.id,
          fallbackToFirst: false,
        );
        _selectedMessageIds = _selectedMessageIds.intersection(
          messages.map((message) => message.id).toSet(),
        );
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _loadingMore = false;
        _setPersistentNotice(
          'Could not load cached mail: $error',
          kind: _NoticeKind.error,
        );
      });
    }
  }

  Future<void> _refreshMessagesInBackground({
    required int requestId,
    bool showErrors = false,
    bool preserveSelection = true,
    bool suppressNewMailNotifications = false,
    bool completeStartupNotificationBaseline = false,
    bool showRefreshIndicator = true,
    bool forceFullRefresh = false,
  }) async {
    if (showRefreshIndicator) {
      _beginMailRefresh(requestId);
    }
    try {
      final page = await _loadRemoteViewPage(
        view: _view,
        query: _search.text,
        limit: _messagePageSize,
        forceFullRefresh: forceFullRefresh,
      );
      if (!_isCurrentMessageLoad(requestId)) return;
      if (suppressNewMailNotifications) {
        _primeNewMailNotificationBaseline(
          page.messages,
          completeStartupBaseline: completeStartupNotificationBaseline,
        );
      } else {
        unawaited(
          _notifyForNewIncomingMail(
            page.messages,
            completeStartupBaseline: completeStartupNotificationBaseline,
          ),
        );
      }
      final messages = _visibleMessagesForDisplay(page.messages);
      setState(() {
        _mergeAccountSyncStatus(page);
        _messages = messages;
        _selected = _messageFor(
          messages,
          preserveSelection ? _selected?.id : null,
          fallbackToFirst: false,
        );
        _selectedMessageIds = _selectedMessageIds.intersection(
          messages.map((message) => message.id).toSet(),
        );
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
      });
      if (preserveSelection) {
        _ensureSelectedMessageBody();
      }
    } catch (error) {
      if (!showErrors || !_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _loadingMore = false;
        _setPersistentNotice(
          'Could not refresh mail: $error',
          kind: _NoticeKind.error,
        );
      });
    } finally {
      if (showRefreshIndicator) {
        _endMailRefresh(requestId);
      }
    }
  }

  void _beginMailRefresh(int requestId) {
    if (!mounted) return;
    setState(() {
      _refreshingMail = true;
      _refreshingMailRequestId = requestId;
    });
  }

  void _mergeAccountSyncStatus(MailMessagePage page) {
    for (final accountId in page.syncedAccountIds) {
      _accountSyncFailures.remove(accountId);
    }
    for (final failure in page.accountFailures) {
      _accountSyncFailures[failure.accountId] = failure;
    }
  }

  void _endMailRefresh(int requestId) {
    if (!mounted || _refreshingMailRequestId != requestId) return;
    setState(() {
      _refreshingMail = false;
      _refreshingMailRequestId = null;
    });
    if (_mailPushRefreshQueued) unawaited(_runQueuedMailPushRefresh());
  }

  Future<void> _reloadMessages() async {
    final requestId = _nextMessageLoadGeneration();
    _hasMoreMessages = true;
    await _showCachedMessages(requestId: requestId, resetSelection: true);
    unawaited(
      _refreshMessagesInBackground(
        requestId: requestId,
        preserveSelection: false,
      ),
    );
  }

  Future<void> _loadMoreMessages() async {
    if (_loadingMore || !_hasMoreMessages) return;
    final requestId = _messageLoadGeneration;
    setState(() => _loadingMore = true);
    try {
      final page = await _loadOlderRemoteViewPage(
        view: _view,
        query: _search.text,
        visibleCount: _messages.length,
        limit: _messagePageSize,
      );
      if (!_isCurrentMessageLoad(requestId)) return;
      final messages = _visibleMessagesForDisplay(page.messages);
      setState(() {
        _mergeAccountSyncStatus(page);
        _messages = messages;
        _selected = _messageFor(
          messages,
          _selected?.id,
          fallbackToFirst: false,
        );
        _selectedMessageIds = _selectedMessageIds.intersection(
          messages.map((message) => message.id).toSet(),
        );
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
      });
      _ensureSelectedMessageBody();
    } catch (error) {
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _loadingMore = false;
        _setPersistentNotice(
          'Could not load more mail: $error',
          kind: _NoticeKind.error,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final vaultUnlocked =
        _profile != null &&
        (_unlockedVaultSecret != null &&
            _unlockedVaultSecret!.trim().isNotEmpty);
    if (!vaultUnlocked) {
      return Scaffold(
        body: SafeArea(
          child: _VaultGatePage(
            profile: _profile,
            banner: _banner,
            unlocking: _vaultUnlocking,
            onUnlock: _unlockOrCreateLocalVault,
            onClearLocalData: _clearLocalData,
            onCheckUpdates: () => _checkUpdates(),
          ),
        ),
      );
    }
    final shellWidth = MediaQuery.sizeOf(context).width;
    final useFolderDrawer = shellWidth < _kSidebarBreakpoint;
    final isMobile = shellWidth < _kSinglePaneBreakpoint;
    final scaffold = Scaffold(
      drawer:
          useFolderDrawer
              ? Drawer(
                child: SafeArea(
                  child: Builder(
                    builder:
                        (drawerContext) => _Sidebar(
                          accounts: _accounts,
                          folders: _folders,
                          accountFailures: _accountSyncFailures,
                          view: _view,
                          onViewChanged: (nextView) {
                            Navigator.of(drawerContext).pop();
                            _changeView(nextView);
                          },
                          onAccountSettings:
                              (account) =>
                                  unawaited(_showMailboxSettings(account)),
                          onAddMailbox: _showAddMailbox,
                          onDeleteAccount: _deleteMailbox,
                          onResolveAccountFailure: _resolveAccountSyncFailure,
                        ),
                  ),
                ),
              )
              : null,
      appBar: _MailHomeAppBar(
        title: _labelForMailboxView(_view, _accounts),
        onCompose: _accounts.isEmpty ? null : _showCompose,
        onRefresh: _refreshingMail ? null : _loadMessages,
        refreshing: _refreshingMail,
        onSettings: _showSettings,
      ),
      floatingActionButton:
          isMobile && _accounts.isNotEmpty
              ? FloatingActionButton(
                onPressed: _showCompose,
                tooltip: 'New message',
                child: const Icon(Icons.edit_outlined),
              )
              : null,
      bottomNavigationBar:
          isMobile
              ? _MailBottomNav(
                currentIndex: _mobileNavIndex(),
                onSelectView: (smart) => _changeView(MailboxView.smart(smart)),
                onOpenFolders: () => _scaffoldKey.currentState?.openDrawer(),
              )
              : null,
      key: _scaffoldKey,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_banner != null)
              _InlineNoticeBanner(
                message: _banner!,
                kind: _bannerKind,
                actionIcon:
                    _pendingPairingPackage == null ? null : Icons.qr_code_2,
                actionTooltip: 'Show pairing QR',
                onAction:
                    _pendingPairingPackage == null
                        ? null
                        : () => _showPairingQr(_pendingPairingPackage!),
                onDismiss: () => setState(() => _banner = null),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < _kSinglePaneBreakpoint) {
                    return _MobileInbox(
                      messages: _messages,
                      selected: _selected,
                      search: _search,
                      searchFocusNode: _searchFocusNode,
                      accounts: _accounts,
                      view: _view,
                      onSearch: _reloadMessages,
                      onAddMailbox: _showAddMailbox,
                      onRefresh: _refreshingMail ? null : _loadMessages,
                      onSelect: _openMobileMessage,
                      canLoadMore: _canLoadMore,
                      loadingMore: _loadingMore,
                      refreshing: _refreshingMail,
                      onLoadMore: _loadMoreMessages,
                      interactionSettings: _interactionSettings,
                      pinnedMessageIds: _pinnedMessageIds,
                      selectedMessageIds: _selectedMessageIds,
                      keyboardNavigationMessageId: _keyboardNavigationMessageId,
                      keyboardNavigationDirection: _keyboardNavigationDirection,
                      onMessageAction: _runMessageAction,
                      onBatchAction: _runBatchMessageAction,
                      onMoveSelectedToMailbox: _moveSelectedMessagesToMailbox,
                      onMessageSelected: _setMessageSelected,
                      onClearSelection: _clearMessageSelection,
                      onSelectAll: _selectAllVisibleMessages,
                      supportsMobileSwipe: _supportsMobileSwipe,
                      supportsDesktopContextMenu: _supportsDesktopContextMenu,
                    );
                  }
                  final collapseSidebar =
                      constraints.maxWidth < _kSidebarBreakpoint;
                  return Row(
                    children: [
                      if (!collapseSidebar) ...[
                        _Sidebar(
                          accounts: _accounts,
                          folders: _folders,
                          accountFailures: _accountSyncFailures,
                          view: _view,
                          onViewChanged: _changeView,
                          onAccountSettings:
                              (account) =>
                                  unawaited(_showMailboxSettings(account)),
                          onAddMailbox: _showAddMailbox,
                          onDeleteAccount: _deleteMailbox,
                          onResolveAccountFailure: _resolveAccountSyncFailure,
                        ),
                        const VerticalDivider(width: 1),
                      ],
                      SizedBox(
                        width: collapseSidebar ? 430 : 390,
                        child: _MessageList(
                          key: ValueKey('desktop-${_view.key}-${_search.text}'),
                          messages: _messages,
                          selected: _selected,
                          search: _search,
                          searchFocusNode: _searchFocusNode,
                          accounts: _accounts,
                          interactionSettings: _interactionSettings,
                          pinnedMessageIds: _pinnedMessageIds,
                          selectedMessageIds: _selectedMessageIds,
                          keyboardNavigationMessageId:
                              _keyboardNavigationMessageId,
                          keyboardNavigationDirection:
                              _keyboardNavigationDirection,
                          onSearch: _reloadMessages,
                          onAddMailbox: _showAddMailbox,
                          onRefresh: _refreshingMail ? null : _loadMessages,
                          onSelect: _selectMessage,
                          onMessageAction: _runMessageAction,
                          onBatchAction: _runBatchMessageAction,
                          onMoveSelectedToMailbox:
                              _moveSelectedMessagesToMailbox,
                          onMessageSelected: _setMessageSelected,
                          onClearSelection: _clearMessageSelection,
                          onSelectAll: _selectAllVisibleMessages,
                          canLoadMore: _canLoadMore,
                          loadingMore: _loadingMore,
                          refreshing: _refreshingMail,
                          onLoadMore: _loadMoreMessages,
                          supportsMobileSwipe: _supportsMobileSwipe,
                          supportsDesktopContextMenu:
                              _supportsDesktopContextMenu,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _Reader(
                          message: _selected,
                          bodyLoading:
                              _selected != null &&
                              _messageBodyLoads.containsKey(_selected!.id),
                          mailboxContextLabel: _mailboxContextLabelForMessage(
                            _selected,
                            _accounts,
                          ),
                          onSendReply: _sendReply,
                          onSendReplyAll: _sendReplyAll,
                          onForward: _showForward,
                          onSetRead: _setRead,
                          onSetStarred: _setStarred,
                          onArchive: _archiveMessage,
                          onDelete: _deleteMessage,
                          onMoveToInbox: _moveToInboxMessage,
                          onMoveToMailbox: _moveMessageToMailbox,
                          onDownloadAttachment: _downloadAttachment,
                          renderSettings: _renderSettings,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    return _withMailHomeShortcuts(scaffold);
  }

  Widget _withMailHomeShortcuts(Widget child) {
    return Shortcuts(
      shortcuts: _mailHomeShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ComposeMailIntent: CallbackAction<_ComposeMailIntent>(
            onInvoke: (_) => _handleComposeShortcut(),
          ),
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) => _handleFocusSearchShortcut(),
          ),
          _SelectAllMessagesIntent: CallbackAction<_SelectAllMessagesIntent>(
            onInvoke: (_) => _handleSelectAllShortcut(),
          ),
          _RefreshMailIntent: CallbackAction<_RefreshMailIntent>(
            onInvoke: (_) => _handleRefreshShortcut(),
          ),
          _DeleteMessagesIntent: CallbackAction<_DeleteMessagesIntent>(
            onInvoke: (_) => _handleDeleteShortcut(),
          ),
          _ClearMessageSelectionIntent:
              CallbackAction<_ClearMessageSelectionIntent>(
                onInvoke: (_) => _handleClearSelectionShortcut(),
              ),
          _MoveSelectionIntent: CallbackAction<_MoveSelectionIntent>(
            onInvoke: (intent) => _handleMoveSelectionShortcut(intent.delta),
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }

  bool get _canLoadMore => _hasMoreMessages;

  Object? _handleComposeShortcut() {
    if (_shortcutShouldYieldToTextInput()) return null;
    if (_accounts.isEmpty) {
      _showTransientNotice('Add a mailbox before composing.');
      return null;
    }
    unawaited(_showCompose());
    return null;
  }

  Object? _handleFocusSearchShortcut() {
    if (_shortcutShouldYieldToTextInput()) return null;
    _searchFocusNode.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return null;
  }

  Object? _handleSelectAllShortcut() {
    if (_shortcutShouldYieldToTextInput() || _messages.isEmpty) return null;
    _selectAllVisibleMessages();
    return null;
  }

  Object? _handleRefreshShortcut() {
    if (_shortcutShouldYieldToTextInput() || _refreshingMail) return null;
    unawaited(_loadMessages());
    return null;
  }

  Object? _handleDeleteShortcut() {
    if (_shortcutShouldYieldToTextInput()) return null;
    if (_selectedMessageIds.isNotEmpty) {
      unawaited(_runBatchMessageAction(MailListActionPreference.delete));
      return null;
    }
    final selected = _selected;
    if (selected != null) {
      unawaited(_runMessageAction(selected, MailListActionPreference.delete));
    }
    return null;
  }

  Object? _handleClearSelectionShortcut() {
    if (_shortcutShouldYieldToTextInput()) return null;
    if (_selectedMessageIds.isNotEmpty) {
      _clearMessageSelection();
    }
    return null;
  }

  Object? _handleMoveSelectionShortcut(int delta) {
    if (_shortcutShouldYieldToTextInput() ||
        !_readerPaneVisible ||
        _selectedMessageIds.isNotEmpty ||
        _messages.isEmpty) {
      return null;
    }
    final currentId = _selected?.id;
    final currentIndex = _messages.indexWhere(
      (message) => message.id == currentId,
    );
    final targetIndex =
        currentIndex == -1
            ? (delta > 0 ? 0 : _messages.length - 1)
            : (currentIndex + delta).clamp(0, _messages.length - 1).toInt();
    if (targetIndex == currentIndex) return null;
    _selectMessage(_messages[targetIndex], keyboardNavigationDirection: delta);
    return null;
  }

  bool _shortcutShouldYieldToTextInput() {
    final focusContext = primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _readerPaneVisible {
    final mediaQuery = MediaQuery.maybeOf(context);
    return mediaQuery != null && mediaQuery.size.width >= 860;
  }

  bool get _hasUnlockedLocalVault =>
      _profile != null &&
      _unlockedVaultSecret != null &&
      _unlockedVaultSecret!.trim().isNotEmpty;

  void _debugVault(String message, [Object? error]) {
    final suffix = error == null ? '' : ': $error';
    debugPrint('[NyaMail vault] $message$suffix');
  }

  Future<void> _unlockOrCreateLocalVault() async {
    if (_vaultUnlocking) return;
    if (mounted) {
      setState(() {
        _vaultUnlocking = true;
        _setPersistentNotice(
          'Preparing local vault...',
          kind: _NoticeKind.progress,
        );
      });
    }
    try {
      final profile = _profile ?? await widget.secureStore.readLocalProfile();
      if (profile == null) {
        if (mounted) {
          setState(
            () => _setPersistentNotice(
              'Creating local vault...',
              kind: _NoticeKind.progress,
            ),
          );
        }
        final created = await _createLocalVault();
        if (!mounted) return;
        if (created == null) {
          setState(() => _vaultUnlocking = false);
          return;
        }
        await _finishLocalBootstrap(
          renderSettings: _renderSettings,
          interactionSettings: _interactionSettings,
          profile: created,
        );
        return;
      }
      _profile = profile;
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Unlocking local vault...',
            kind: _NoticeKind.progress,
          ),
        );
      }
      final unlocked = await _tryUnlockLocalVault(
        profile,
        promptIfNeeded: true,
      );
      if (!mounted) return;
      if (!unlocked) {
        setState(() => _vaultUnlocking = false);
        return;
      }
      await _finishLocalBootstrap(
        renderSettings: _renderSettings,
        interactionSettings: _interactionSettings,
        profile: profile,
      );
      if (mounted) {
        _showTransientNotice(
          'Local vault unlocked.',
          kind: _NoticeKind.success,
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _vaultUnlocking = false;
        _setPersistentNotice(
          'Could not unlock the local vault: $error',
          kind: _NoticeKind.error,
        );
      });
    }
  }

  /// Index into [_MailBottomNav]'s destinations for the active view.
  /// 0 = All incoming, 1 = Unread, 2 = Inbox, 3 = a specific folder ("Folders").
  int _mobileNavIndex() {
    return switch (_view.smartFolder) {
      MailSmartFolder.allIncoming => 0,
      MailSmartFolder.unread => 1,
      MailSmartFolder.inbox => 2,
      _ => _view.folder != null ? 3 : 0,
    };
  }

  void _changeView(MailboxView view) {
    if (_view.key == view.key) return;
    setState(() {
      _view = view;
      _selectedAccountId = view.folder?.accountId;
      _messages = const [];
      _selected = null;
    });
    _reloadMessages();
  }

  MailboxView _activeViewFor(List<MailFolder> folders) {
    final folder = _view.folder;
    if (folder == null) return _view;
    return folders.any((item) => item.key == folder.key)
        ? _view
        : const MailboxView.smart(MailSmartFolder.allIncoming);
  }

  List<MailAccount> _localAccountsForDocument(VaultDocument? document) {
    final credentials = document?.toCredentials() ?? const [];
    return [
      for (final credential in credentials)
        MailAccount(
          id: credential.accountId,
          address: credential.address,
          displayName: credential.displayName,
          provider:
              credential.authType == MailboxAuthType.oauth2 ? 'oauth2' : 'imap',
        ),
    ];
  }

  List<MailFolder> _localFoldersForDocument(VaultDocument? document) {
    final credentials = document?.toCredentials() ?? const [];
    return [
      for (final credential in credentials)
        for (final mailbox in standardMailboxKinds)
          MailFolder(
            accountId: credential.accountId,
            path: _localFolderPathFor(mailbox),
            displayName: _localFolderPathFor(mailbox),
            kind: mailbox,
          ),
    ];
  }

  List<MailFolder> _locallyAvailableFoldersForDocument(
    VaultDocument? document,
  ) {
    final fallbackFolders = _localFoldersForDocument(document);
    if (document == null || _folders.isEmpty) return fallbackFolders;
    final accountIds =
        document
            .toCredentials()
            .map((credential) => credential.accountId)
            .toSet();
    final existingFolders =
        _folders
            .where((folder) => accountIds.contains(folder.accountId))
            .toList();
    if (existingFolders.isEmpty) return fallbackFolders;
    final existingMailboxKeys = {
      for (final folder in existingFolders)
        if (folder.kind != MailboxKind.custom)
          '${folder.accountId}:${folder.kind.name}',
    };
    final missingFallbackFolders =
        fallbackFolders
            .where(
              (folder) =>
                  !existingMailboxKeys.contains(
                    '${folder.accountId}:${folder.kind.name}',
                  ),
            )
            .toList();
    return [...existingFolders, ...missingFallbackFolders];
  }

  Future<void> _discoverFoldersInBackground() async {
    final document = _vaultDocument;
    if (document == null || document.toCredentials().isEmpty) return;
    try {
      _debugVault('folder discovery: start');
      final folders = await _mailRepository.folders();
      if (!mounted || !identical(document, _vaultDocument)) return;
      final nextFolders =
          folders.isEmpty ? _localFoldersForDocument(document) : folders;
      final activeView = _activeViewFor(nextFolders);
      setState(() {
        _accounts = _localAccountsForDocument(document);
        _folders = nextFolders;
        _view = activeView;
        _selectedAccountId = activeView.folder?.accountId;
      });
      _debugVault('folder discovery: ready (${nextFolders.length} folders)');
    } catch (error) {
      _debugVault('folder discovery failed', error);
    }
  }

  Future<void> _showSettings() async {
    if (!mounted) return;
    final smallScreen = MediaQuery.sizeOf(context).width < 720;
    final onAction = _runSettingsAction;
    if (smallScreen) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder:
              (context) => _SettingsPage(
                session: _session,
                profile: _profile,
                accountCount: _accounts.length,
                claimingVaultShare: _claimingVaultShare,
                hasPendingPairingQr: _pendingPairingPackage != null,
                onAction: onAction,
              ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder:
            (context) => _SettingsDialog(
              session: _session,
              profile: _profile,
              accountCount: _accounts.length,
              claimingVaultShare: _claimingVaultShare,
              hasPendingPairingQr: _pendingPairingPackage != null,
              onAction: onAction,
            ),
      );
    }
  }

  Future<_SettingsActionResult> _runSettingsAction(
    _SettingsAction action,
  ) async {
    if (!mounted) {
      return const _SettingsActionResult(keepOpen: false);
    }
    if (action == _SettingsAction.addMailbox) {
      final feedback = await _showAddMailbox(showResultNotice: false);
      return _SettingsActionResult(keepOpen: true, feedback: feedback);
    }
    _capturedSettingsFeedback = null;
    _captureSettingsNotices = true;
    try {
      final keepOpen = await _handleSettingsAction(action);
      return _SettingsActionResult(
        keepOpen: keepOpen,
        feedback: _capturedSettingsFeedback,
      );
    } finally {
      _captureSettingsNotices = false;
      _capturedSettingsFeedback = null;
    }
  }

  Future<bool> _handleSettingsAction(_SettingsAction action) async {
    switch (action) {
      case _SettingsAction.syncAccount:
        await _showLogin();
        return false;
      case _SettingsAction.checkUpdates:
        await _checkUpdates();
        return false;
      case _SettingsAction.addMailbox:
        await _showAddMailbox();
        return true;
      case _SettingsAction.mailboxes:
        await _showMailboxSettings();
        return true;
      case _SettingsAction.clearMailCache:
        return !await _clearMailCacheAndRebuild();
      case _SettingsAction.appThemeSettings:
        await _showAppThemeSettings();
        return true;
      case _SettingsAction.localVaultSettings:
        await _showLocalVaultSettings();
        return true;
      case _SettingsAction.mailSettings:
        await _showMailSettings();
        return true;
      case _SettingsAction.mailInteractionSettings:
        await _showMailInteractionSettings();
        return true;
      case _SettingsAction.oauthProviderSettings:
        await _showOAuthProviderSettings();
        return true;
      case _SettingsAction.systemSettings:
        await _showSystemSettings();
        return true;
      case _SettingsAction.about:
        await _showAbout();
        return true;
      case _SettingsAction.clearLocalData:
        await _clearLocalData();
        return false;
      case _SettingsAction.exportVault:
        await _exportVault();
        return true;
      case _SettingsAction.importVault:
        await _importVault();
        return true;
      case _SettingsAction.devices:
        if (_session != null) await _showDevices();
        return true;
      case _SettingsAction.receiveVaultShare:
        if (_session != null && !_claimingVaultShare) await _claimVaultShare();
        return true;
      case _SettingsAction.showPairingQr:
        final pairingPackage = _pendingPairingPackage;
        if (pairingPackage != null) await _showPairingQr(pairingPackage);
        return true;
    }
  }

  Future<void> _exportVault() async {
    final profile = await _ensureLocalProfile();
    final document = _vaultDocument;
    if (profile == null || document == null || !mounted) return;
    final input = await showDialog<_VaultPasswordInput>(
      context: context,
      builder:
          (context) => const _VaultPasswordDialog(
            title: 'Export vault configuration',
            message:
                'This exports mailbox credentials and OAuth settings only. Mail, drafts, attachments, and cache are not included.',
            confirmPassword: true,
            passwordLabel: 'Export password',
            actionLabel: 'Export',
          ),
    );
    if (input == null || !mounted) return;
    try {
      final encoded = await const VaultExportService().exportDocument(
        document: document,
        password: input.password,
      );
      final filename =
          'nyamail-vault-${DateTime.now().toIso8601String().substring(0, 10)}.${VaultExportService.extension}';
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export vault configuration',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [VaultExportService.extension],
        bytes: Uint8List.fromList(utf8.encode(encoded)),
      );
      if (path == null) return;
      if (!mounted) return;
      _showTransientNotice(
        'Vault configuration exported successfully.',
        kind: _NoticeKind.success,
      );
    } catch (error) {
      if (!mounted) return;
      _showTransientNotice(
        'Could not export vault configuration: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  Future<void> _importVault() async {
    final profile = await _ensureLocalProfile();
    if (profile == null || !mounted) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import vault configuration',
        type: FileType.custom,
        allowedExtensions: [VaultExportService.extension],
        withData: true,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final selected = result.files.single;
      final bytes =
          selected.bytes ??
          (selected.path == null
              ? null
              : await io.File(selected.path!).readAsBytes());
      if (bytes == null) {
        throw const VaultExportException('could not read the selected file');
      }
      if (!mounted) return;
      final input = await showDialog<_VaultPasswordInput>(
        context: context,
        builder:
            (context) => const _VaultPasswordDialog(
              title: 'Import vault configuration',
              message:
                  'Enter the export password. Mail, drafts, attachments, and cache will remain on this device.',
              confirmPassword: false,
              passwordLabel: 'Export password',
              actionLabel: 'Continue',
            ),
      );
      if (input == null || !mounted) return;
      final incoming = await const VaultExportService().importDocument(
        encoded: utf8.decode(bytes),
        password: input.password,
      );
      if (!mounted) return;
      final plan = VaultImportPlan.create(
        current: _vaultDocument ?? VaultDocument.empty(),
        incoming: incoming,
      );
      final policy =
          plan.hasConflicts
              ? await showDialog<VaultImportConflictPolicy>(
                context: context,
                builder: (context) => _VaultImportConflictDialog(plan: plan),
              )
              : VaultImportConflictPolicy.keepLocal;
      if (policy == null || !mounted) return;
      final merged = plan.merge(policy);
      await _saveLocalVaultDocument(profile: profile, document: merged);
      await _applyVaultDocument(merged);
      if (!mounted) return;
      final conflictCount =
          plan.mailboxConflicts.length + plan.oauthProviderConflicts.length;
      final conflictText =
          conflictCount == 0 ? '' : ', $conflictCount conflicts';
      _showTransientNotice(
        'Vault configuration imported$conflictText.',
        kind: _NoticeKind.success,
      );
    } catch (error) {
      if (!mounted) return;
      _showTransientNotice(
        'Could not import vault configuration: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  Future<void> _showAppThemeSettings() async {
    final next = await showDialog<AppThemeSetting>(
      context: context,
      builder:
          (context) => _AppThemeSettingsDialog(setting: widget.appThemeSetting),
    );
    if (next == null || next == widget.appThemeSetting) return;
    await widget.onAppThemeSettingChanged(next);
  }

  Future<void> _showSystemSettings() async {
    await showDialog<void>(
      context: context,
      builder:
          (context) => _SystemSettingsDialog(
            service: _startupService,
            settings: _systemSettings,
            onSettingsChanged: _setSystemBehaviorSettings,
          ),
    );
  }

  Future<void> _showAbout() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'NyaMail',
      applicationVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      applicationIcon: const Icon(Icons.mail_lock_outlined, size: 42),
      applicationLegalese: 'Local-first encrypted mail client',
      children: const [
        SizedBox(height: 16),
        Text(
          'NyaMail connects directly to your mail providers and keeps vault configuration encrypted on your device.',
        ),
      ],
    );
  }

  Future<void> _showServerSettings() async {
    final nextApiBaseUrl = await showDialog<String>(
      context: context,
      builder:
          (context) => _ServerSettingsDialog(
            apiBaseUrl: widget.apiBaseUrl,
            defaultApiBaseUrl: widget.defaultApiBaseUrl,
          ),
    );
    if (nextApiBaseUrl == null || nextApiBaseUrl == widget.apiBaseUrl) {
      return;
    }
    if (!mounted) return;

    if (_session != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Switch NyaMail server?'),
              content: const Text(
                'This device will sign out before connecting to the new server.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Switch'),
                ),
              ],
            ),
      );
      if (confirmed != true) return;
      await _signOut();
    } else {
      await widget.secureStore.clearSession();
    }

    try {
      await widget.onApiBaseUrlChanged(nextApiBaseUrl);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _setPersistentNotice(error.toString(), kind: _NoticeKind.error),
      );
    }
  }

  Future<void> _showMailSettings() async {
    final next = await showDialog<MailRenderSettings>(
      context: context,
      builder: (context) => _MailSettingsDialog(settings: _renderSettings),
    );
    if (next == null) return;
    await const MailRenderSettingsStore().save(next);
    if (!mounted) return;
    setState(() => _renderSettings = next);
  }

  Future<void> _showLocalVaultSettings() async {
    final profile = _profile;
    if (profile == null) return;
    final quickUnlockAvailable = await _vaultAuthenticator.isAvailable();
    final quickUnlockEnabled = await _hasQuickUnlockMaterial();
    final quickUnlockMethod =
        await widget.secureStore.readQuickUnlockMethod() ??
        _vaultAuthenticator.methodLabel;
    if (!mounted) return;
    final action = await showDialog<_LocalVaultSettingsAction>(
      context: context,
      builder:
          (context) => _LocalVaultSettingsDialog(
            profile: profile,
            quickUnlockAvailable: quickUnlockAvailable,
            quickUnlockEnabled: quickUnlockEnabled,
            quickUnlockMethod: quickUnlockMethod,
          ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _LocalVaultSettingsAction.enableQuickUnlock:
        final vaultSecret = await _readUnlockedVaultSecret(
          includeLegacySecret: false,
        );
        if (vaultSecret == null || vaultSecret.trim().isEmpty) {
          _showTransientNotice(
            'Unlock the local vault first.',
            kind: _NoticeKind.warning,
          );
          return;
        }
        final enabled = await _enableQuickUnlockForSecret(
          profile: profile,
          vaultSecret: vaultSecret,
        );
        if (!mounted) return;
        _showTransientNotice(
          enabled
              ? 'System quick unlock is enabled for this device.'
              : 'System quick unlock could not be enabled.',
          kind: enabled ? _NoticeKind.success : _NoticeKind.error,
        );
      case _LocalVaultSettingsAction.disableQuickUnlock:
        await widget.secureStore.clearQuickUnlockMaterial();
        if (!mounted) return;
        _showTransientNotice(
          'System quick unlock is disabled.',
          kind: _NoticeKind.success,
        );
    }
  }

  Future<void> _showOAuthProviderSettings() async {
    final profile = await _ensureLocalProfile();
    if (profile == null || !mounted) return;
    final document = _vaultDocument ?? VaultDocument.empty();
    final nextProviders = await showDialog<List<VaultOAuthProviderConfig>>(
      context: context,
      builder:
          (context) => _OAuthProviderSettingsDialog(
            providers: document.oauthProviders,
            gmailBuildClientId: widget.gmailOAuthClientId,
            gmailBuildClientSecret: widget.gmailOAuthClientSecret,
            gmailAndroidBuildClientId: widget.gmailAndroidOAuthClientId,
            gmailAndroidBuildClientSecret: widget.gmailAndroidOAuthClientSecret,
            gmailAndroidBuildRedirectUri: widget.gmailAndroidOAuthRedirectUri,
            outlookBuildClientId: widget.outlookOAuthClientId,
            outlookBuildClientSecret: widget.outlookOAuthClientSecret,
            outlookAndroidBuildClientId: widget.outlookAndroidOAuthClientId,
            outlookAndroidBuildClientSecret:
                widget.outlookAndroidOAuthClientSecret,
            outlookAndroidBuildRedirectUri:
                widget.outlookAndroidOAuthRedirectUri,
          ),
    );
    if (nextProviders == null || !mounted) return;

    final updatedDocument = document.copyWith(oauthProviders: nextProviders);
    try {
      await _saveLocalVaultDocument(
        profile: profile,
        document: updatedDocument,
      );
      await _applyVaultDocument(
        updatedDocument,
        loadMessages: false,
        discoverFolders: false,
      );
      final synced = await _syncVaultRecordsWithServer(silent: true);
      if (!mounted) return;
      if (synced || _session == null) {
        _showTransientNotice(
          'OAuth provider settings saved to the local encrypted vault.',
          kind: _NoticeKind.success,
        );
      } else {
        setState(
          () => _setPersistentNotice(
            'OAuth provider settings saved locally. Sync will retry later.',
            kind: _NoticeKind.warning,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _setPersistentNotice(
          'Could not save OAuth provider settings: $error',
          kind: _NoticeKind.error,
        ),
      );
    }
  }

  Future<void> _showMailboxSettings([MailAccount? account]) async {
    final document = _vaultDocument;
    if (document == null) {
      setState(
        () => _setPersistentNotice(
          'Mailbox account data is not loaded yet.',
          kind: _NoticeKind.warning,
        ),
      );
      return;
    }
    final items =
        account == null
            ? document.items
            : document.items.where((item) => item.id == account.id).toList();
    if (items.isEmpty) {
      setState(
        () => _setPersistentNotice(
          'Mailbox account data is not available.',
          kind: _NoticeKind.warning,
        ),
      );
      return;
    }
    final action = await showDialog<_MailboxSettingsAction>(
      context: context,
      builder:
          (context) => _MailboxSettingsDialog(
            items: items,
            selectedMailboxId: account?.id,
          ),
    );
    if (!mounted || action == null) return;
    switch (action.kind) {
      case _MailboxSettingsActionKind.edit:
        await _editMailboxItem(action.item);
      case _MailboxSettingsActionKind.reauthorize:
        await _reauthorizeMailboxItem(action.item);
      case _MailboxSettingsActionKind.remove:
        await _deleteMailbox(
          MailAccount(
            id: action.item.id,
            address: action.item.address,
            displayName:
                action.item.displayName.trim().isEmpty
                    ? action.item.address
                    : action.item.displayName,
            provider:
                action.item.kind == VaultItemKind.oauth ? 'oauth2' : 'imap',
          ),
        );
    }
  }

  Future<void> _resolveAccountSyncFailure(MailAccount account) async {
    final failure = _accountSyncFailures[account.id];
    if (failure == null) return;
    if (!failure.authenticationRequired) {
      await _loadMessages();
      return;
    }
    final item =
        _vaultDocument?.items
            .where((candidate) => candidate.id == account.id)
            .firstOrNull;
    if (item == null || item.kind != VaultItemKind.oauth) {
      await _showMailboxSettings(account);
      return;
    }
    await _reauthorizeMailboxItem(item);
  }

  Future<void> _editMailboxItem(VaultMailboxItem item) async {
    final updated = await showDialog<VaultMailboxItem>(
      context: context,
      builder: (context) => _MailboxEditDialog(item: item),
    );
    if (updated == null || !mounted) return;
    await _saveUpdatedMailboxItem(
      updated,
      '${updated.address} settings saved to the local encrypted vault.',
    );
  }

  Future<void> _reauthorizeMailboxItem(VaultMailboxItem item) async {
    try {
      final provider = oauthProviderConfig(item.provider);
      final clientId = _oauthClientIdForProvider(item.provider);
      if (clientId.isEmpty) {
        throw StateError(
          'OAuth client id is not configured for ${item.provider}.',
        );
      }
      setState(
        () => _setPersistentNotice(
          _oauthProgressMessage(
            OAuthAuthorizationProgress.waitingForAuthorization,
            provider.provider,
          ),
          kind: _NoticeKind.progress,
        ),
      );
      final clientSecret = _oauthClientSecretForProvider(item.provider);
      final tokenSet = await _authorizeOAuthForCurrentPlatform(
        oauthClient: widget.oauthClient,
        provider: provider,
        clientId: clientId,
        androidClientId: _oauthAndroidClientIdForProvider(item.provider),
        clientSecret: clientSecret,
        loginHint: item.address,
        mobileRedirectUri: _oauthMobileRedirectUriForProvider(item.provider),
        forceAccountPicker: true,
        onProgress: (progress) {
          if (!mounted) return;
          setState(
            () => _setPersistentNotice(
              _oauthProgressMessage(progress, provider.provider),
              kind: _NoticeKind.progress,
            ),
          );
        },
      );
      final updated = VaultMailboxItem(
        id: item.id,
        kind: VaultItemKind.oauth,
        address: item.address,
        displayName:
            item.displayName.trim().isEmpty ? item.address : item.displayName,
        provider: provider.provider,
        username: item.username.trim().isEmpty ? item.address : item.username,
        secret: tokenSet.accessToken,
        refreshToken:
            tokenSet.refreshToken?.isNotEmpty == true
                ? tokenSet.refreshToken!
                : _usesGoogleAndroidOAuth(provider.provider)
                ? ''
                : item.refreshToken,
        tokenExpiresAt:
            tokenSet.expiresIn == null
                ? item.tokenExpiresAt
                : DateTime.now().toUtc().add(
                  Duration(seconds: tokenSet.expiresIn!),
                ),
        tokenScope: tokenSet.scope ?? item.tokenScope,
        oauthClientId: clientId,
        oauthClientSecret: clientSecret,
        imapHost:
            item.imapHost.trim().isEmpty ? provider.imapHost : item.imapHost,
        imapPort: item.imapPort,
        smtpHost:
            item.smtpHost.trim().isEmpty ? provider.smtpHost : item.smtpHost,
        smtpPort: item.smtpPort,
        useTls: item.useTls,
      );
      await _saveUpdatedMailboxItem(
        updated,
        '${item.address} OAuth authorization refreshed.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _setPersistentNotice(
          'Could not reauthorize mailbox: $error',
          kind: _NoticeKind.error,
        ),
      );
    }
  }

  Future<void> _saveUpdatedMailboxItem(
    VaultMailboxItem item,
    String successBanner,
  ) async {
    final profile = await _ensureLocalProfile();
    final document = _vaultDocument;
    if (profile == null || document == null) return;
    final updatedDocument = document.upsertMailbox(item);
    await _saveLocalVaultDocument(profile: profile, document: updatedDocument);
    await _applyVaultDocument(updatedDocument);
    final synced = await _syncVaultRecordsWithServer(silent: true);
    if (!mounted) return;
    setState(() => _accountSyncFailures.remove(item.id));
    if (synced || _session == null) {
      _showTransientNotice(successBanner, kind: _NoticeKind.success);
    } else {
      setState(
        () => _setPersistentNotice(
          '$successBanner Sync will retry later.',
          kind: _NoticeKind.warning,
        ),
      );
    }
  }

  Uri? _oauthMobileRedirectUriForProvider(String provider) {
    if (kIsWeb || !io.Platform.isAndroid) return null;
    if (_usesGoogleAndroidOAuth(provider)) return null;
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    final redirect = vaultConfig?.androidRedirectUri.trim() ?? '';
    final value =
        redirect.isNotEmpty
            ? redirect
            : switch (normalizeOAuthProviderKey(provider)) {
              'gmail' => widget.gmailAndroidOAuthRedirectUri.trim(),
              'outlook' => widget.outlookAndroidOAuthRedirectUri.trim(),
              _ => '',
            };
    return value.isEmpty ? null : Uri.parse(value);
  }

  Future<bool> _confirmClearLocalData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Clear local data?'),
            content: const Text(
              'This removes the local encrypted vault, mailbox settings, sync session, local mail cache, drafts, and downloaded attachments from this device. Other devices and the sync server are not cleared.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Clear local data'),
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<void> _clearLocalData() async {
    if (!await _confirmClearLocalData()) return;
    await _flushPendingMailActions();
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _setPersistentNotice(
          'Clearing local data...',
          kind: _NoticeKind.progress,
        );
      });
    }

    final profile = _profile;
    final session = _session;
    final profileIds = {
      if (profile != null) profile.id,
      if (session != null) session.userId,
    };
    for (final profileId in profileIds) {
      await widget.localVaultStore.clear(profileId);
      await widget.localVaultRecordStore.clear(profileId);
      await widget.localVaultSyncStateStore.clear(profileId);
      await _clearLocalMailDataForNamespace(
        mailCacheNamespaceForUser(profileId),
      );
    }
    await _clearLocalMailDataForNamespace(null);
    await widget.secureStore.clearSession();
    await widget.secureStore.clearLocalProfile();
    await widget.secureStore.clearVaultUnlockMaterial();
    await _LoginPasswordMemory.clear();

    _mailRepository = widget.mailRepository;
    final accounts = await _mailRepository.accounts();
    final folders = await _mailRepository.folders();
    const view = MailboxView.smart(MailSmartFolder.allIncoming);
    final page = await _mailRepository.cachedViewPage(
      view: view,
      limit: _messagePageSize,
    );
    final messages = _visibleMessagesForDisplay(page.messages);
    if (!mounted) return;
    setState(() {
      _session = null;
      _profile = null;
      _draftCache = null;
      _vaultDocument = null;
      _vaultRecordRevision = null;
      _unlockedVaultSecret = null;
      _unlockedVaultPassword = null;
      _pendingPairingPackage = null;
      _view = view;
      _selectedAccountId = null;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = messages;
      _selected = _messageFor(messages, null);
      _selectedMessageIds = const <String>{};
      _banner = null;
    });
    _mailPushUnsupported.clear();
    _syncAutomaticMailRefresh();
    _showTransientNotice(
      'Local data cleared on this device.',
      kind: _NoticeKind.success,
    );
    _ensureSelectedMessageBody();
  }

  Future<bool> _confirmClearMailCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Clear mail cache?'),
            content: const Text(
              'This removes cached messages, the local mail index, and downloaded attachments from this device only. Your local vault, mailbox accounts, settings, sync session, and drafts will be kept. Mail will be fetched again from the configured mailboxes.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Clear cache'),
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<bool> _clearMailCacheAndRebuild() async {
    if (!await _confirmClearMailCache()) return false;
    await _flushPendingMailActions();
    final requestId = _nextMessageLoadGeneration();
    _resetNewMailNotificationBaseline();
    if (mounted) {
      setState(() {
        _messages = const [];
        _selected = null;
        _selectedMessageIds = const <String>{};
        _hasMoreMessages = true;
        _loadingMore = false;
        _setPersistentNotice(
          'Clearing mail cache...',
          kind: _NoticeKind.progress,
        );
      });
    }

    try {
      await _mailRepository.clearLocalCache();
      if (!_isCurrentMessageLoad(requestId)) return true;
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Mail cache cleared. Rebuilding index...',
            kind: _NoticeKind.progress,
          ),
        );
      }
      final page = await _loadRemoteViewPage(
        view: _view,
        query: _search.text,
        limit: _messagePageSize,
      );
      if (!_isCurrentMessageLoad(requestId)) return true;
      _primeNewMailNotificationBaseline(page.messages);
      final messages = _visibleMessagesForDisplay(page.messages);
      setState(() {
        _messages = messages;
        _selected = _messageFor(messages, null, fallbackToFirst: false);
        _selectedMessageIds = const <String>{};
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
        _banner = null;
      });
      _showTransientNotice(
        'Mail cache cleared. Rebuilding from mail servers.',
        kind: _NoticeKind.success,
      );
      return true;
    } catch (error) {
      if (_isCurrentMessageLoad(requestId)) {
        setState(() {
          _loadingMore = false;
          _setPersistentNotice(
            'Could not clear mail cache: $error',
            kind: _NoticeKind.error,
          );
        });
      }
      return true;
    }
  }

  Future<void> _showLogin() async {
    final currentSession = _session;
    if (currentSession != null) {
      final syncStatus = await _loadSyncAccountStatus(currentSession);
      if (!mounted) return;
      final action = await showDialog<_SyncAccountAction>(
        context: context,
        builder:
            (context) => _SyncAccountDialog(
              session: currentSession,
              apiBaseUrl: widget.apiBaseUrl,
              status: syncStatus,
            ),
      );
      if (!mounted || action == null) return;
      switch (action) {
        case _SyncAccountAction.serverSettings:
          await _showServerSettings();
        case _SyncAccountAction.syncNow:
          await _syncVaultRecordsWithServer(loadMessages: true);
        case _SyncAccountAction.leaveSync:
          if (await _confirmLeaveSync()) {
            await _leaveSync();
          }
        case _SyncAccountAction.signOut:
          if (await _confirmSignOut()) {
            await _signOut();
          }
      }
      return;
    }

    final result = await showDialog<Object>(
      context: context,
      builder:
          (context) => _LoginDialog(
            api: widget.api,
            apiBaseUrl: widget.apiBaseUrl,
            secureStore: widget.secureStore,
          ),
    );
    if (result == _LoginDialogAction.serverSettings) {
      if (mounted) await _showServerSettings();
      return;
    }
    if (result is! AuthSession) return;
    await widget.secureStore.saveSession(
      accessToken: result.accessToken,
      userId: result.user.id,
      email: result.email,
      deviceId: result.deviceId,
      deviceName: result.device.name,
      devicePlatform: result.device.platform,
      devicePublicKey: result.device.publicKey,
      deviceKeyAgreementPublicKey: result.device.keyAgreementPublicKey,
    );
    String? pairingPackage;
    if (result.requiresApproval) {
      pairingPackage =
          DevicePairingRequest.forDevice(
            userId: result.user.id,
            device: result.device,
          ).encode();
      await Clipboard.setData(ClipboardData(text: pairingPackage));
    }
    setState(() {
      final pairingCode = const DevicePairingCode().codeFor(
        userId: result.user.id,
        device: result.device,
      );
      _session = LocalSession(
        accessToken: result.accessToken,
        userId: result.user.id,
        email: result.email,
        deviceId: result.deviceId,
        deviceName: result.device.name,
        devicePlatform: result.device.platform,
        devicePublicKey: result.device.publicKey,
        deviceKeyAgreementPublicKey: result.device.keyAgreementPublicKey,
      );
      _draftCache =
          _profile == null
              ? _draftCacheForSession(_session!)
              : _draftCacheForProfile(_profile!);
      _pendingPairingPackage = pairingPackage;
      if (result.requiresApproval) {
        _setPersistentNotice(
          'This device needs approval. Pair $pairingCode. Pairing package copied.',
          kind: _NoticeKind.warning,
        );
      } else if (result.recoveryCodes.isNotEmpty) {
        _setPersistentNotice(
          'Recovery codes created. Store them before closing this build.',
          kind: _NoticeKind.warning,
        );
      } else {
        _banner = null;
      }
    });
    if (!result.requiresApproval && result.recoveryCodes.isEmpty && mounted) {
      _showTransientNotice(
        'Sync connected as ${result.email}.',
        kind: _NoticeKind.success,
      );
    }
    if (result.recoveryCodes.isNotEmpty) {
      await _showRecoveryCodes(result.recoveryCodes);
      if (!mounted) return;
    }
    if (_profile != null && _vaultDocument != null) {
      final recordSynced =
          result.requiresApproval
              ? false
              : await _syncVaultRecordsWithServer(silent: true);
      if (mounted && !result.requiresApproval && !recordSynced) {
        setState(
          () => _setPersistentNotice(
            'Sync connected, but record sync will retry later.',
            kind: _NoticeKind.warning,
          ),
        );
      }
      await _loadMessages();
    } else {
      await _tryUnlockVaultAfterLogin(result);
      if (!result.requiresApproval && mounted) {
        await _syncVaultRecordsWithServer(silent: true);
      }
    }
  }

  Future<_SyncAccountStatus> _loadSyncAccountStatus(
    LocalSession session,
  ) async {
    final profileId = _profile?.id ?? session.userId;
    try {
      final state = await widget.localVaultSyncStateStore.read(profileId);
      final snapshot = await widget.localVaultRecordStore.read(profileId);
      final records = snapshot?.records.records ?? const [];
      return _SyncAccountStatus(
        profileId: profileId,
        cursor: state?.cursor ?? 0,
        lastSyncedAt: state?.lastSyncedAt,
        recordCount: records.length,
        dirtyRecordCount: records.where((record) => record.syncDirty).length,
        tombstoneCount: records.where((record) => record.deleted).length,
        hasRecordVault: snapshot != null,
      );
    } catch (error) {
      return _SyncAccountStatus(profileId: profileId, error: error.toString());
    }
  }

  Future<void> _showRecoveryCodes(List<String> recoveryCodes) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RecoveryCodesDialog(codes: recoveryCodes),
    );
  }

  Future<bool> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Sign out?'),
            content: const Text(
              'This disconnects the sync server on this device. Your local encrypted vault, mailbox settings, and local mail cache stay available.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<bool> _confirmLeaveSync() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Leave sync on this device?'),
            content: const Text(
              'This removes this device from the sync server and clears local sync state. Your local encrypted vault, mailbox settings, and mail cache stay available on this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.link_off_outlined),
                label: const Text('Leave sync'),
              ),
            ],
          ),
    );
    return confirmed == true;
  }

  Future<void> _leaveSync() async {
    final session = _session;
    if (session == null) return;
    await _flushPendingMailActions();
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _setPersistentNotice('Leaving sync...', kind: _NoticeKind.progress);
      });
    }
    try {
      await widget.api.leaveSyncDevice(token: session.accessToken);
    } catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not leave sync: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
      return;
    }
    final profileId = _profile?.id ?? session.userId;
    await widget.localVaultSyncStateStore.clear(profileId);
    await widget.secureStore.clearSession();
    final accounts = await _mailRepository.accounts();
    final folders = await _mailRepository.folders();
    final activeView = _activeViewFor(folders);
    final page = await _mailRepository.cachedViewPage(
      view: activeView,
      limit: _messagePageSize,
    );
    final messages = _visibleMessagesForDisplay(page.messages);
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingPairingPackage = null;
      _view = activeView;
      _selectedAccountId = activeView.folder?.accountId;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = messages;
      _selected = _messageFor(messages, _selected?.id);
      _selectedMessageIds = const <String>{};
      _banner = null;
    });
    _showTransientNotice(
      'This device left sync. Local vault remains available.',
      kind: _NoticeKind.success,
    );
    _ensureSelectedMessageBody();
  }

  Future<void> _signOut() async {
    await _flushPendingMailActions();
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _setPersistentNotice('Signing out...', kind: _NoticeKind.progress);
      });
    }
    await widget.secureStore.clearSession();
    final accounts = await _mailRepository.accounts();
    final folders = await _mailRepository.folders();
    const view = MailboxView.smart(MailSmartFolder.allIncoming);
    final page = await _mailRepository.cachedViewPage(
      view: view,
      limit: _messagePageSize,
    );
    final messages = _visibleMessagesForDisplay(page.messages);
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingPairingPackage = null;
      _view = view;
      _selectedAccountId = null;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = messages;
      _selected = _messageFor(messages, null);
      _selectedMessageIds = const <String>{};
      _banner = null;
    });
    _showTransientNotice(
      'Sync server disconnected. Local vault remains available.',
      kind: _NoticeKind.success,
    );
    _ensureSelectedMessageBody();
  }

  Future<void> _clearLocalMailDataForNamespace(String? cacheNamespace) async {
    await MailCache(namespace: cacheNamespace).clear();
    await MailDraftCache(namespace: cacheNamespace).clear();
    if (cacheNamespace == null) {
      await clearLegacyMailAttachmentCache();
    } else {
      await clearMailAttachmentCache(cacheNamespace: cacheNamespace);
    }
  }

  MailDraftCache _draftCacheForSession(
    LocalSession session, {
    String? localCacheSecret,
  }) {
    return MailDraftCache(
      namespace: mailCacheNamespaceForUser(session.userId),
      localCacheSecret: localCacheSecret,
    );
  }

  MailDraftCache _draftCacheForProfile(
    LocalProfile profile, {
    String? localCacheSecret,
  }) {
    return MailDraftCache(
      namespace: mailCacheNamespaceForUser(profile.id),
      localCacheSecret: localCacheSecret,
    );
  }

  Future<void> _tryUnlockVaultAfterLogin(AuthSession result) async {
    var vault = result.vault;
    var vaultSecret = await _readUnlockedVaultSecret();
    final loginPassword = await _LoginPasswordMemory.read();

    if (vault == null) {
      try {
        final session = LocalSession(
          accessToken: result.accessToken,
          userId: result.user.id,
          email: result.email,
          deviceId: result.deviceId,
          deviceName: result.device.name,
          devicePlatform: result.device.platform,
          devicePublicKey: result.device.publicKey,
          deviceKeyAgreementPublicKey: result.device.keyAgreementPublicKey,
        );
        if (await _consumeVaultShare(session)) {
          vaultSecret = await _readUnlockedVaultSecret();
          vault = await widget.api.getVault(result.accessToken);
        }
      } catch (_) {
        if (mounted) {
          setState(
            () => _setPersistentNotice(
              'Signed in, but this device could not consume its vault share.',
              kind: _NoticeKind.error,
            ),
          );
        }
        return;
      }
    }

    if (vault == null || (loginPassword == null && vaultSecret == null)) {
      return;
    }
    try {
      final document = await widget.vaultCrypto.decryptDocument(
        blob: vault.blob,
        email: result.email,
        password: loginPassword ?? '',
        vaultSecret: vaultSecret,
      );
      final profile = _profile ?? await _ensureLocalProfile();
      if (profile != null) {
        await _saveLocalVaultDocument(profile: profile, document: document);
      }
      await _applyVaultDocument(
        document,
        loadMessages: false,
        discoverFolders: false,
      );
      await _loadMessages();
    } catch (error) {
      _debugVault('login server vault unlock failed', error);
      if (!mounted) return;
      if (_hasUnlockedLocalVault) {
        setState(
          () => _setPersistentNotice(
            'Signed in. Server vault sync will retry later.',
            kind: _NoticeKind.warning,
          ),
        );
        return;
      }
      setState(
        () => _setPersistentNotice(
          'Signed in, but server vault could not be opened.',
          kind: _NoticeKind.error,
        ),
      );
    }
  }

  Future<void> _claimVaultShare() async {
    final session = _session;
    if (session == null || _claimingVaultShare) return;
    setState(() {
      _claimingVaultShare = true;
      _setPersistentNotice(
        'Checking for shared vault access...',
        kind: _NoticeKind.progress,
      );
    });
    try {
      final unlocked = await _consumeVaultShare(session);
      final synced =
          unlocked
              ? await _syncVaultRecordsWithServer(
                loadMessages: true,
                silent: true,
              )
              : false;
      if (!mounted) return;
      if (unlocked) {
        setState(() => _pendingPairingPackage = null);
        if (synced) {
          setState(() => _banner = null);
          _showTransientNotice(
            'Vault access received. Mailboxes are ready on this device.',
            kind: _NoticeKind.success,
          );
        } else {
          setState(
            () => _setPersistentNotice(
              'Vault access received. Vault sync will retry later.',
              kind: _NoticeKind.warning,
            ),
          );
        }
      } else {
        setState(() => _banner = null);
        _showTransientNotice(
          'No vault share is available for this device yet.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not receive vault share: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _claimingVaultShare = false);
      }
    }
  }

  Future<bool> _consumeVaultShare(LocalSession session) async {
    final share = await widget.api.getVaultShare(session.accessToken);
    if (share == null) return false;
    final boxKeyPair = await widget.secureStore.readOrCreateDeviceBoxKeyPair();
    final vaultSecret = await const VaultShareCrypto().decryptFromShare(
      share: share,
      privateKey: boxKeyPair.privateKey,
    );
    _setUnlockedVaultSecret(vaultSecret);
    if (!await _ensureVaultSecretWrapped(vaultSecret: vaultSecret)) {
      throw StateError('Vault password is required to store shared access.');
    }
    await widget.api.consumeVaultShare(
      token: session.accessToken,
      shareId: share.id,
    );
    final vault = await widget.api.getVault(session.accessToken);
    if (vault == null) return true;
    final loginPassword = await _LoginPasswordMemory.read();
    final document = await widget.vaultCrypto.decryptDocument(
      blob: vault.blob,
      email: session.email,
      password: loginPassword ?? '',
      vaultSecret: vaultSecret,
    );
    final profile = _profile ?? await _ensureLocalProfile();
    if (profile != null) {
      await _saveLocalVaultDocument(profile: profile, document: document);
    }
    await _applyVaultDocument(
      document,
      loadMessages: false,
      discoverFolders: false,
    );
    await _loadMessages();
    return true;
  }

  Future<LocalProfile?> _ensureLocalProfile() async {
    final existing = _profile;
    if (existing != null) {
      final secret = await _readUnlockedVaultSecret();
      if (secret != null && secret.trim().isNotEmpty) return existing;
      final unlocked = await _tryUnlockLocalVault(
        existing,
        promptIfNeeded: true,
      );
      return unlocked ? existing : null;
    }

    final stored = await widget.secureStore.readLocalProfile();
    if (stored != null) {
      _profile = stored;
      _draftCache = _draftCacheForProfile(stored);
      final unlocked = await _tryUnlockLocalVault(stored, promptIfNeeded: true);
      return unlocked ? stored : null;
    }

    return _createLocalVault();
  }

  Future<int> _saveLocalVaultRecords({
    required LocalProfile profile,
    required VaultDocument document,
    String? vaultSecret,
  }) async {
    final secret = vaultSecret ?? await _readUnlockedVaultSecret();
    final current = await widget.localVaultRecordStore.read(profile.id);
    if (secret == null || secret.trim().isEmpty) {
      throw StateError('Local vault record unlock material is not available.');
    }
    final now = DateTime.now().toUtc();
    final fresh = VaultRecordSet.fromVaultDocument(document, updatedAt: now);
    var merged = fresh;
    var dirtyRecordIds = fresh.records.map((record) => record.id).toSet();
    final previousEncryptedById = {
      for (final record in current?.records.records ?? const [])
        record.id: record,
    };
    if (current != null) {
      final existing = await widget.vaultRecordCrypto.decryptRecordSet(
        records: current.records,
        vaultSecret: secret,
      );
      final existingById = {
        for (final record in existing.records) record.id: record,
      };
      final freshIds = fresh.records.map((record) => record.id).toSet();
      dirtyRecordIds = {};
      merged = VaultRecordSet(
        version: fresh.version,
        records: [
          for (final record in fresh.records)
            _mergeVaultRecord(
              previous: existingById[record.id],
              next: record,
              updatedAt: now,
              dirtyRecordIds: dirtyRecordIds,
            ),
          for (final record in existing.records)
            if (!freshIds.contains(record.id))
              _deletedVaultRecord(
                record: record,
                deletedAt: now,
                dirtyRecordIds: dirtyRecordIds,
              ),
        ],
      );
    }
    final encrypted = await widget.vaultRecordCrypto.encryptRecordSet(
      records: merged,
      vaultSecret: secret,
    );
    final writerId = _localVaultRecordWriterId(profile);
    final expectedRevision = _vaultRecordRevision ?? current?.revision ?? 0;
    final snapshot = await widget.localVaultRecordStore.write(
      profileId: profile.id,
      expectedRevision: expectedRevision,
      records: EncryptedVaultRecordSet(
        version: encrypted.version,
        records: [
          for (final record in encrypted.records)
            _applyLocalVaultRecordSyncMetadata(
              record: record,
              previous: previousEncryptedById[record.id],
              dirty: dirtyRecordIds.contains(record.id),
              writerId: writerId,
            ),
        ],
      ),
    );
    _vaultRecordRevision = snapshot.revision;
    return snapshot.revision;
  }

  VaultRecord _mergeVaultRecord({
    required VaultRecord? previous,
    required VaultRecord next,
    required DateTime updatedAt,
    required Set<String> dirtyRecordIds,
  }) {
    if (previous == null || previous.deleted) {
      dirtyRecordIds.add(next.id);
      return next;
    }
    final unchanged =
        previous.type == next.type &&
        previous.entityId == next.entityId &&
        jsonEncode(previous.payload) == jsonEncode(next.payload);
    if (unchanged) {
      return next.copyWith(
        version: previous.version,
        updatedAt: previous.updatedAt,
      );
    }
    dirtyRecordIds.add(next.id);
    return next.copyWith(version: previous.version + 1, updatedAt: updatedAt);
  }

  VaultRecord _deletedVaultRecord({
    required VaultRecord record,
    required DateTime deletedAt,
    required Set<String> dirtyRecordIds,
  }) {
    if (record.deleted) return record;
    dirtyRecordIds.add(record.id);
    return record.copyWith(
      version: record.version + 1,
      updatedAt: deletedAt.toUtc(),
      payload: const {},
      deleted: true,
    );
  }

  EncryptedVaultRecord _applyLocalVaultRecordSyncMetadata({
    required EncryptedVaultRecord record,
    required EncryptedVaultRecord? previous,
    required bool dirty,
    required String writerId,
  }) {
    if (!dirty && previous != null) {
      return previous;
    }
    final vector = Map<String, int>.from(previous?.versionVector ?? const {});
    if (dirty && writerId.trim().isNotEmpty) {
      vector[writerId] = record.version;
    }
    return record.copyWith(
      versionVector: vector,
      syncDirty: dirty || (previous?.syncDirty ?? true),
      lastSyncedLogicalTime: previous?.lastSyncedLogicalTime,
      lastSyncedContentHash: previous?.lastSyncedContentHash,
    );
  }

  String _localVaultRecordWriterId(LocalProfile profile) {
    final deviceId = _session?.deviceId.trim() ?? '';
    if (deviceId.isNotEmpty) return deviceId;
    return profile.id;
  }

  Future<void> _saveLocalVaultDocument({
    required LocalProfile profile,
    required VaultDocument document,
  }) async {
    final vaultSecret = await _readUnlockedVaultSecret();
    if (vaultSecret == null || vaultSecret.trim().isEmpty) {
      throw StateError('Local vault unlock material is not available.');
    }
    await _saveLocalVaultRecords(
      profile: profile,
      document: document,
      vaultSecret: vaultSecret,
    );
  }

  Future<bool> _syncVaultRecordsWithServer({
    bool loadMessages = false,
    bool silent = false,
  }) async {
    final session = _session;
    if (session == null) return false;
    final document = _vaultDocument;
    final vaultSecret = await _readUnlockedVaultSecret();
    if (_profile == null &&
        document == null &&
        (vaultSecret == null || vaultSecret.trim().isEmpty)) {
      return false;
    }
    final profile = _profile ?? await _ensureLocalProfile();
    if (profile == null) return false;
    try {
      if (vaultSecret == null || vaultSecret.trim().isEmpty) {
        return false;
      }
      var current = await widget.localVaultRecordStore.read(profile.id);
      if (current == null && document != null) {
        await _saveLocalVaultRecords(
          profile: profile,
          document: document,
          vaultSecret: vaultSecret,
        );
      }
      final result = await VaultRecordSyncEngine(
        recordStore: widget.localVaultRecordStore,
        stateStore: widget.localVaultSyncStateStore,
      ).sync(
        profileId: profile.id,
        deviceId: session.deviceId,
        pushRecords:
            (records) => widget.api.pushSyncRecords(
              token: session.accessToken,
              records: records,
            ),
        pullRecords:
            ({required after, required limit}) => widget.api.pullSyncRecords(
              token: session.accessToken,
              after: after,
              limit: limit,
            ),
      );
      final snapshot = await widget.localVaultRecordStore.read(profile.id);
      if (snapshot != null) {
        _vaultRecordRevision = snapshot.revision;
        final records = await widget.vaultRecordCrypto.decryptRecordSet(
          records: snapshot.records,
          vaultSecret: vaultSecret,
        );
        await _applyVaultDocument(
          records.toVaultDocument(),
          loadMessages: loadMessages,
        );
      }
      if (mounted && !silent) {
        final conflictText =
            result.conflicts == 0 ? '' : ', conflicts ${result.conflicts}';
        _showTransientNotice(
          'Vault sync complete. Pushed ${result.pushed}, pulled ${result.pulled}$conflictText.',
          kind: _NoticeKind.success,
        );
      }
      return true;
    } catch (error) {
      if (mounted && !silent) {
        setState(
          () => _setPersistentNotice(
            'Vault sync could not complete: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
      return false;
    }
  }

  Future<_SettingsFeedback?> _showAddMailbox({
    bool showResultNotice = true,
  }) async {
    final profile = await _ensureLocalProfile();
    if (profile == null) return null;
    if (!mounted) return null;
    final added = await showDialog<_AddMailboxResult>(
      context: context,
      builder:
          (context) => _AddMailboxDialog(
            document: _vaultDocument ?? VaultDocument.empty(),
            vaultCrypto: widget.vaultCrypto,
            oauthClient: widget.oauthClient,
            gmailOAuthClientId: widget.gmailOAuthClientId,
            gmailOAuthClientSecret: widget.gmailOAuthClientSecret,
            gmailAndroidOAuthClientId: widget.gmailAndroidOAuthClientId,
            gmailAndroidOAuthClientSecret: widget.gmailAndroidOAuthClientSecret,
            gmailAndroidOAuthRedirectUri: widget.gmailAndroidOAuthRedirectUri,
            outlookOAuthClientId: widget.outlookOAuthClientId,
            outlookOAuthClientSecret: widget.outlookOAuthClientSecret,
            outlookAndroidOAuthClientId: widget.outlookAndroidOAuthClientId,
            outlookAndroidOAuthClientSecret:
                widget.outlookAndroidOAuthClientSecret,
            outlookAndroidOAuthRedirectUri:
                widget.outlookAndroidOAuthRedirectUri,
          ),
    );
    if (added == null) return null;
    try {
      await _saveLocalVaultDocument(profile: profile, document: added.document);
      await _applyVaultDocument(added.document);
      final synced = await _syncVaultRecordsWithServer(silent: true);
      if (!mounted) return null;
      final feedback =
          synced || _session == null
              ? _SettingsFeedback(
                message:
                    '${added.mailbox.address} was added to the local encrypted vault.',
              )
              : _SettingsFeedback(
                message:
                    '${added.mailbox.address} was added locally. Sync will retry later.',
                kind: _NoticeKind.warning,
              );
      if (showResultNotice) {
        _showTransientNotice(feedback.message, kind: feedback.kind);
      }
      return feedback;
    } catch (error) {
      if (!mounted) return null;
      final feedback = _SettingsFeedback(
        message: 'Could not add ${added.mailbox.address}: $error',
        kind: _NoticeKind.error,
      );
      if (showResultNotice) {
        _showTransientNotice(feedback.message, kind: _NoticeKind.error);
      }
      return feedback;
    }
  }

  Future<void> _deleteMailbox(MailAccount account) async {
    final profile = _profile;
    final session = _session;
    final document = _vaultDocument;
    if (account.id == 'all') {
      _showTransientNotice(
        'Select a mailbox account before removing it.',
        kind: _NoticeKind.warning,
      );
      return;
    }
    if (document == null) {
      _showTransientNotice(
        'Mailbox account data is not loaded yet.',
        kind: _NoticeKind.warning,
      );
      return;
    }
    if (profile == null && session == null) {
      _showTransientNotice(
        'Unlock the local vault before removing a mailbox.',
        kind: _NoticeKind.warning,
      );
      return;
    }
    final localProfile = profile ?? await _ensureLocalProfile();
    if (localProfile == null) {
      if (mounted) {
        _showTransientNotice(
          'Unlock the local vault before removing a mailbox.',
          kind: _NoticeKind.warning,
        );
      }
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Remove ${account.displayName}?'),
            content: const Text(
              'This removes the mailbox credentials from the encrypted vault on this account. Mail stays with the provider.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      final updatedDocument = document.removeMailbox(account.id);
      await _saveLocalVaultDocument(
        profile: localProfile,
        document: updatedDocument,
      );
      await _applyVaultDocument(updatedDocument);
      final synced = await _syncVaultRecordsWithServer(silent: true);
      if (!mounted) return;
      if (synced || session == null) {
        setState(() => _banner = null);
      } else {
        setState(
          () => _setPersistentNotice(
            '${account.address} was removed locally. Sync will retry later.',
            kind: _NoticeKind.warning,
          ),
        );
      }
      if (synced || session == null) {
        _showTransientNotice(
          '${account.address} was removed from the local encrypted vault.',
          kind: _NoticeKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not remove mailbox: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
    }
  }

  Future<void> _applyVaultDocument(
    VaultDocument document, {
    bool loadMessages = true,
    bool discoverFolders = true,
  }) async {
    _debugVault(
      'apply vault: start (loadMessages=$loadMessages, discoverFolders=$discoverFolders)',
    );
    final previousAccountIds = _accounts.map((account) => account.id).toSet();
    _vaultDocument = document;
    final localCacheSecret = await _localCacheSecretForActiveVault();
    _configureMailRepository(document, localCacheSecret: localCacheSecret);
    final profile = _profile;
    final session = _session;
    if (profile != null) {
      _draftCache = _draftCacheForProfile(
        profile,
        localCacheSecret: localCacheSecret,
      );
    } else if (session != null) {
      _draftCache = _draftCacheForSession(
        session,
        localCacheSecret: localCacheSecret,
      );
    }
    final accounts = _localAccountsForDocument(document);
    final List<MailFolder> folders;
    if (discoverFolders && document.toCredentials().isNotEmpty) {
      _debugVault('apply vault: discovering folders');
      final discoveredFolders = await _mailRepository.folders().timeout(
        _folderDiscoveryTimeout,
        onTimeout: () => const <MailFolder>[],
      );
      folders =
          discoveredFolders.isEmpty
              ? _localFoldersForDocument(document)
              : discoveredFolders;
      _debugVault('apply vault: folders ready (${folders.length})');
    } else {
      folders = _locallyAvailableFoldersForDocument(document);
      _debugVault('apply vault: using local folders (${folders.length})');
    }
    final activeView = _activeViewFor(folders);
    final requestId = loadMessages ? _nextMessageLoadGeneration() : null;
    final page =
        loadMessages
            ? await _mailRepository.cachedViewPage(
              view: activeView,
              query: _search.text,
              limit: _messagePageSize,
            )
            : MailMessagePage(messages: _messages, hasMore: _hasMoreMessages);
    final messages = _visibleMessagesForDisplay(page.messages);
    if (!mounted) return;
    final nextAccountIds = accounts.map((account) => account.id).toSet();
    setState(() {
      _accountSyncFailures.removeWhere(
        (accountId, _) => !nextAccountIds.contains(accountId),
      );
      _accounts = accounts;
      _folders = folders;
      _view = activeView;
      _selectedAccountId = activeView.folder?.accountId;
      if (loadMessages) {
        _messages = messages;
        _selected = _messageFor(
          messages,
          _selected?.id,
          fallbackToFirst: false,
        );
        _selectedMessageIds = const <String>{};
        _hasMoreMessages = page.hasMore;
      }
    });
    final accountsChanged = !setEquals(previousAccountIds, nextAccountIds);
    if (accountsChanged) {
      _resetNewMailNotificationBaseline();
      _syncAutomaticMailRefresh();
    }
    _debugVault('apply vault: state updated');
    if (requestId != null) {
      unawaited(
        _refreshMessagesInBackground(
          requestId: requestId,
          preserveSelection: false,
          suppressNewMailNotifications: accountsChanged,
        ),
      );
    }
  }

  Future<String?> _localCacheSecretForActiveVault() async {
    final profile = _profile;
    final session = _session;
    final vaultSecret = await _readUnlockedVaultSecret();
    if (vaultSecret != null && vaultSecret.trim().isNotEmpty) {
      return vaultSecret;
    }
    final loginPassword = await _LoginPasswordMemory.read();
    final email = profile?.email ?? session?.email;
    if (email == null ||
        loginPassword == null ||
        loginPassword.trim().isEmpty) {
      return null;
    }
    return localCacheSecretFromPassword(email: email, password: loginPassword);
  }

  void _configureMailRepository(
    VaultDocument document, {
    String? localCacheSecret,
  }) {
    final cacheNamespace = _activeCacheNamespace();
    _mailRepository = CachedTransportMailRepository(
      cache: MailCache(
        namespace: cacheNamespace,
        localCacheSecret: localCacheSecret,
      ),
      transport: const SocketMailTransport(),
      credentials: document.toCredentials(),
      cacheNamespace: cacheNamespace,
      localCacheSecret: localCacheSecret,
      backgroundIndexing: false,
    );
  }

  String? _activeCacheNamespace() {
    final profile = _profile;
    if (profile != null) return mailCacheNamespaceForUser(profile.id);
    final session = _session;
    if (session != null) return mailCacheNamespaceForUser(session.userId);
    return null;
  }

  Future<OAuthVaultRefreshResult?> _refreshOAuthVaultIfNeeded({
    bool force = false,
    Set<String>? accountIds,
  }) {
    if (force || accountIds != null) {
      return _refreshOAuthVaultIfNeededUnshared(
        force: force,
        accountIds: accountIds,
      ).timeout(_oauthRefreshTimeout);
    }
    final current = _oauthRefreshFuture;
    if (current != null) return current;
    late final Future<OAuthVaultRefreshResult?> refresh;
    refresh = _refreshOAuthVaultIfNeededUnshared()
        .timeout(_oauthRefreshTimeout)
        .whenComplete(() {
          if (identical(_oauthRefreshFuture, refresh)) {
            _oauthRefreshFuture = null;
          }
        });
    _oauthRefreshFuture = refresh;
    return refresh;
  }

  Future<OAuthVaultRefreshResult?> _refreshOAuthVaultIfNeededUnshared({
    bool force = false,
    Set<String>? accountIds,
  }) async {
    final profile = _profile;
    final session = _session;
    final document = _vaultDocument;
    final contextUserId = profile?.id ?? session?.userId;
    final contextSessionToken = session?.accessToken;
    bool isCurrentVaultContext() {
      final currentUserId = _profile?.id ?? _session?.userId;
      return mounted &&
          currentUserId == contextUserId &&
          _session?.accessToken == contextSessionToken &&
          identical(_vaultDocument, document);
    }

    if (document == null) {
      _debugVault('oauth refresh: skipped, vault document is not loaded');
      return null;
    }
    if (profile == null && session == null) {
      _debugVault('oauth refresh: skipped, no local or sync account context');
      return null;
    }
    try {
      final result = await OAuthVaultRefresher(
        refreshTokens: widget.oauthClient.refresh,
        reauthorizeAccessToken: ({
          required OAuthProviderConfig provider,
          required String clientId,
          String? clientSecret,
          required String loginHint,
        }) {
          if (!_usesGoogleAndroidOAuth(provider.provider)) {
            throw StateError(
              'OAuth refresh token is not available for ${provider.provider}.',
            );
          }
          return _authorizeOAuthForCurrentPlatform(
            oauthClient: widget.oauthClient,
            provider: provider,
            clientId: clientId,
            androidClientId: _oauthAndroidClientIdForProvider(
              provider.provider,
            ),
            clientSecret: clientSecret,
            loginHint: loginHint,
            mobileRedirectUri: _oauthMobileRedirectUriForProvider(
              provider.provider,
            ),
          );
        },
      ).refreshExpiring(
        document: document,
        clientIdForProvider: _oauthClientIdForProvider,
        clientSecretForProvider: _oauthClientSecretForProvider,
        force: force,
        itemIds: accountIds,
      );
      if (!isCurrentVaultContext()) return result;
      setState(() {
        for (final accountId in result.refreshedItemIds) {
          _accountSyncFailures.remove(accountId);
        }
        for (final failure in result.failures) {
          _accountSyncFailures[failure.itemId] = MailAccountSyncFailure(
            accountId: failure.itemId,
            message: failure.message,
            authenticationRequired: looksLikeMailAuthenticationFailure(
              failure.message,
            ),
          );
        }
        if (result.failures.isNotEmpty) {
          final first = result.failures.first;
          _setPersistentNotice(
            'OAuth token refresh failed for ${first.address}.',
            kind: _NoticeKind.error,
          );
        }
      });
      if (result.changed) {
        _debugVault(
          'oauth refresh: refreshed ${result.refreshedCount} token(s)',
        );
        final localProfile = profile ?? await _ensureLocalProfile();
        if (!isCurrentVaultContext()) return result;
        if (localProfile != null) {
          await _saveLocalVaultDocument(
            profile: localProfile,
            document: result.document,
          );
        } else {
          _debugVault('oauth refresh: refreshed token kept in memory only');
        }
        if (!isCurrentVaultContext()) return result;
        await _applyVaultDocument(
          result.document,
          loadMessages: false,
          discoverFolders: false,
        );
        await _syncVaultRecordsWithServer(silent: true);
      }
      return result;
    } catch (error) {
      if (isCurrentVaultContext()) {
        setState(
          () => _setPersistentNotice(
            'OAuth token refresh failed: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
      return null;
    }
  }

  String _oauthClientIdForProvider(String provider) {
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    if (io.Platform.isAndroid && normalizedProvider != 'gmail') {
      final vaultAndroidClientId = vaultConfig?.androidClientId.trim() ?? '';
      if (vaultAndroidClientId.isNotEmpty) return vaultAndroidClientId;
      return switch (normalizedProvider) {
        'outlook' => widget.outlookAndroidOAuthClientId.trim(),
        _ => '',
      };
    }
    final vaultClientId = vaultConfig?.clientId.trim() ?? '';
    if (vaultClientId.isNotEmpty) return vaultClientId;
    return switch (normalizedProvider) {
      'gmail' => widget.gmailOAuthClientId.trim(),
      'outlook' => widget.outlookOAuthClientId.trim(),
      _ => '',
    };
  }

  String _oauthClientSecretForProvider(String provider) {
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    if (io.Platform.isAndroid && normalizedProvider != 'gmail') {
      if (vaultConfig?.androidClientId.trim().isNotEmpty == true) {
        return vaultConfig!.androidClientSecret.trim();
      }
      return switch (normalizedProvider) {
        'outlook' => widget.outlookAndroidOAuthClientSecret.trim(),
        _ => '',
      };
    }
    if (vaultConfig?.clientId.trim().isNotEmpty == true) {
      return vaultConfig!.clientSecret.trim();
    }
    return switch (normalizedProvider) {
      'gmail' => widget.gmailOAuthClientSecret.trim(),
      'outlook' => widget.outlookOAuthClientSecret.trim(),
      _ => '',
    };
  }

  String _oauthAndroidClientIdForProvider(String provider) {
    if (!_usesGoogleAndroidOAuth(provider)) return '';
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    final clientId = vaultConfig?.androidClientId.trim() ?? '';
    if (clientId.isNotEmpty) return clientId;
    return widget.gmailAndroidOAuthClientId.trim();
  }

  Future<void> _sendReply(
    MailMessage message,
    String textBody, {
    String htmlBody = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.sendReply(
      original: message,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: attachments,
    );
    if (!mounted) return;
    _showTransientNotice('Reply sent.', kind: _NoticeKind.success);
  }

  Future<void> _sendReplyAll(
    MailMessage message,
    String textBody, {
    String htmlBody = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.sendReplyAll(
      original: message,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: attachments,
    );
    if (!mounted) return;
    _showTransientNotice('Reply all sent.', kind: _NoticeKind.success);
  }

  Future<void> _showCompose() async {
    if (_accounts.isEmpty) return;
    final draft = await _draftCache?.loadComposeDraft();
    if (!mounted) return;
    if (draft != null) {
      _showTransientNotice('Local draft restored.');
    }
    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => _ComposeDialog(
            accounts: _accounts,
            initialAccountId:
                draft?.accountId ?? _selectedAccountIdFor(_accounts),
            initialTo: draft?.to ?? '',
            initialCc: draft?.cc ?? '',
            initialBcc: draft?.bcc ?? '',
            initialSubject: draft?.subject ?? '',
            initialBody: draft?.body ?? '',
            initialHtmlBody: draft?.htmlBody ?? '',
            initialAttachments: [
              for (final attachment
                  in draft?.attachments ?? const <MailDraftAttachment>[])
                OutgoingAttachment(
                  filename: attachment.filename,
                  contentType: attachment.contentType,
                  bytes: attachment.bytes,
                ),
            ],
            onDraftChanged: _saveComposeDraft,
            onSend: _sendMessage,
          ),
    );
    if (sent == true) {
      await _draftCache?.deleteComposeDraft();
      if (!mounted) return;
      _showTransientNotice('Message sent.', kind: _NoticeKind.success);
    }
  }

  Future<void> _showForward(MailMessage message) async {
    if (_accounts.isEmpty) return;
    final fullMessage = await _ensureMessageBody(message) ?? message;
    if (!mounted) return;
    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => _ComposeDialog(
            title: 'Forward message',
            accounts: _accounts,
            initialAccountId: fullMessage.accountId,
            initialSubject: forwardSubjectFor(fullMessage.subject),
            initialBody: forwardBodyFor(fullMessage),
            onSend: _sendMessage,
          ),
    );
    if (sent == true && mounted) {
      _showTransientNotice('Message forwarded.', kind: _NoticeKind.success);
    }
  }

  Future<void> _showDevices() async {
    final session = _session;
    if (session == null) return;
    final vaultSecret = await _readUnlockedVaultSecret();
    if (!mounted) return;
    if (vaultSecret == null || vaultSecret.trim().isEmpty) {
      if (mounted) {
        _showTransientNotice(
          'Unlock the local vault before sharing it.',
          kind: _NoticeKind.warning,
        );
      }
      return;
    }
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => _DevicesDialog(
            api: widget.api,
            token: session.accessToken,
            userId: session.userId,
            currentDevice: session.toDeviceSummary(),
            secureStore: widget.secureStore,
            vaultSecret: vaultSecret,
          ),
    );
    if (result != null && mounted) {
      _showTransientNotice(result);
    }
  }

  Future<void> _showPairingQr(String pairingPackage) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _PairingQrDialog(pairingPackage: pairingPackage),
    );
  }

  Future<void> _saveComposeDraft(MailDraft draft) async {
    await _draftCache?.saveComposeDraft(draft);
  }

  Future<void> _sendMessage({
    required String accountId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String textBody,
    String htmlBody = '',
    required List<OutgoingAttachment> attachments,
  }) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.sendMessage(
      accountId: accountId,
      to: to,
      cc: cc,
      bcc: bcc,
      subject: subject,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: attachments,
    );
  }

  void _selectMessage(MailMessage message, {int? keyboardNavigationDirection}) {
    setState(() {
      _selected = message;
      if (keyboardNavigationDirection != null) {
        _keyboardNavigationMessageId = message.id;
        _keyboardNavigationDirection = keyboardNavigationDirection;
      }
    });
    _markReadWhenOpened(message);
    unawaited(_ensureMessageBody(message));
  }

  void _ensureSelectedMessageBody() {
    final selected = _selected;
    if (selected != null) {
      unawaited(_ensureMessageBody(selected));
    }
  }

  Future<MailMessage?> _ensureMessageBody(MailMessage message) {
    if (message.bodyLoaded &&
        (message.body.isNotEmpty || message.htmlBody.isNotEmpty)) {
      return Future.value(message);
    }
    final current = _messageBodyLoads[message.id];
    if (current != null) return current;

    late final Future<MailMessage?> load;
    load = _loadMessageBody(message).whenComplete(() {
      if (identical(_messageBodyLoads[message.id], load)) {
        _messageBodyLoads.remove(message.id);
      }
    });
    _messageBodyLoads[message.id] = load;
    return load;
  }

  Future<MailMessage?> _loadMessageBody(MailMessage message) async {
    try {
      await _refreshOAuthVaultIfNeeded();
      final loaded = await _mailRepository.loadMessageBody(message);
      if (!mounted) return loaded;
      final updated = _preserveLocalReadState(loaded);
      _replaceMessage(updated);
      return updated;
    } catch (error) {
      if (mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not load message body: $error',
            kind: _NoticeKind.error,
          ),
        );
      }
      return null;
    }
  }

  Future<void> _openMobileMessage(MailMessage message) async {
    setState(() => _selected = message);
    _markReadWhenOpened(message);
    final notifier = ValueNotifier<MailMessage>(_selected ?? message);
    _mobileMessageNotifiers[message.id] = notifier;
    var disposed = false;
    unawaited(
      _ensureMessageBody(message).then((loaded) {
        if (loaded != null && !disposed) notifier.value = loaded;
      }),
    );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder:
              (context) => Scaffold(
                body: SafeArea(
                  child: ValueListenableBuilder<MailMessage>(
                    valueListenable: notifier,
                    builder:
                        (context, current, _) => _Reader(
                          message: current,
                          bodyLoading: _messageBodyLoads.containsKey(
                            current.id,
                          ),
                          mailboxContextLabel: _mailboxContextLabelForMessage(
                            current,
                            _accounts,
                          ),
                          onSendReply: _sendReply,
                          onSendReplyAll: _sendReplyAll,
                          onForward: _showForward,
                          onSetRead: _setRead,
                          onSetStarred: _setStarred,
                          onArchive: _archiveMessage,
                          onDelete: _deleteMessage,
                          onMoveToInbox: _moveToInboxMessage,
                          onMoveToMailbox: _moveMessageToMailbox,
                          onDownloadAttachment: _downloadAttachment,
                          renderSettings: _renderSettings,
                          mobileFullScreen: true,
                          onClose: () => Navigator.of(context).pop(),
                        ),
                  ),
                ),
              ),
        ),
      );
    } finally {
      disposed = true;
      if (_mobileMessageNotifiers[message.id] == notifier) {
        _mobileMessageNotifiers.remove(message.id);
      }
      notifier.dispose();
    }
  }

  Future<void> _setRead(MailMessage message, bool read) async {
    _scheduleSetReadMessages([message], read);
  }

  void _markReadWhenOpened(MailMessage message) {
    if (message.read) return;
    final optimistic = message.copyWith(read: true);
    _replaceMessage(optimistic);
    unawaited(_setReadRemoteAfterOpen(message));
  }

  Future<void> _setReadRemoteAfterOpen(MailMessage message) async {
    try {
      await _refreshOAuthVaultIfNeeded();
      final updated = await _mailRepository.setRead(
        message: message,
        read: true,
      );
      if (!mounted) return;
      _replaceMessage(_preserveLocalReadState(updated));
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _setPersistentNotice(
          'Marked read locally. Could not sync read state to the mailbox: $error',
          kind: _NoticeKind.warning,
        ),
      );
    }
  }

  MailMessage _preserveLocalReadState(MailMessage message) {
    final selected = _selected;
    if (selected?.id == message.id && selected!.read && !message.read) {
      return message.copyWith(read: true);
    }
    for (final cached in _messages) {
      if (cached.id == message.id && cached.read && !message.read) {
        return message.copyWith(read: true);
      }
    }
    return message;
  }

  Future<void> _setStarred(MailMessage message, bool starred) async {
    _scheduleSetStarredMessages([message], starred);
  }

  Future<void> _archiveMessage(MailMessage message) async {
    _scheduleArchiveMessages([message]);
  }

  Future<void> _deleteMessage(MailMessage message) async {
    _scheduleDeleteMessages([message]);
  }

  Future<void> _moveToInboxMessage(MailMessage message) async {
    _scheduleMoveToInboxMessages([message]);
  }

  Future<void> _moveMessageToMailbox(
    MailMessage message,
    MailboxKind destination,
  ) async {
    _scheduleMoveToMailboxMessages([message], destination);
  }

  Future<void> _downloadAttachment(
    MailMessage message,
    MailAttachment attachment,
  ) async {
    await _refreshOAuthVaultIfNeeded();
    final file = await _mailRepository.downloadAttachment(
      message: message,
      attachment: attachment,
    );
    if (!await launchUrl(file.uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open ${file.path}');
    }
    if (!mounted) return;
    _showTransientNotice(
      'Attachment downloaded: ${file.path}',
      kind: _NoticeKind.success,
    );
  }

  bool get _supportsMobileSwipe {
    return !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);
  }

  bool get _supportsDesktopContextMenu {
    return !kIsWeb &&
        (io.Platform.isWindows || io.Platform.isLinux || io.Platform.isMacOS);
  }

  List<MailMessage> _sortMessagesForDisplay(
    List<MailMessage> messages, {
    Set<String>? pinnedMessageIds,
  }) {
    final pinned = pinnedMessageIds ?? _pinnedMessageIds;
    if (pinned.isEmpty || messages.length < 2) return messages;
    final top = <MailMessage>[];
    final rest = <MailMessage>[];
    for (final message in messages) {
      if (pinned.contains(message.id)) {
        top.add(message);
      } else {
        rest.add(message);
      }
    }
    return [...top, ...rest];
  }

  List<MailMessage> _visibleMessagesForDisplay(
    List<MailMessage> messages, {
    Set<String>? pinnedMessageIds,
  }) {
    final hidden = _pendingRemovedMessageIds;
    final visible =
        hidden.isEmpty
            ? messages
            : messages
                .where((message) => !hidden.contains(message.id))
                .toList(growable: false);
    return _sortMessagesForDisplay(visible, pinnedMessageIds: pinnedMessageIds);
  }

  Set<String> get _pendingRemovedMessageIds {
    if (_pendingMailActions.isEmpty) return const <String>{};
    return {
      for (final action in _pendingMailActions.values)
        if (!action.undone) ...action.messageIds,
    };
  }

  Future<void> _saveInteractionSettings(
    MailInteractionSettings settings,
  ) async {
    await const MailInteractionSettingsStore().save(settings);
    if (!mounted) return;
    setState(() => _interactionSettings = settings);
  }

  Future<void> _showMailInteractionSettings() async {
    final next = await showDialog<MailInteractionSettings>(
      context: context,
      builder:
          (context) => _MailInteractionSettingsDialog(
            settings: _interactionSettings,
            supportsMobileSwipe: _supportsMobileSwipe,
            supportsDesktopContextMenu: _supportsDesktopContextMenu,
          ),
    );
    if (next == null) return;
    final settings = next.copyWith(
      pinnedMessageIds: _pinnedMessageIds.toList()..sort(),
    );
    await _saveInteractionSettings(settings);
  }

  void _setMessageSelected(String messageId, bool selected) {
    setState(() {
      final next = {..._selectedMessageIds};
      if (selected) {
        next.add(messageId);
      } else {
        next.remove(messageId);
      }
      _selectedMessageIds = next;
    });
  }

  void _clearMessageSelection() {
    setState(() => _selectedMessageIds = const <String>{});
  }

  void _selectAllVisibleMessages() {
    setState(
      () =>
          _selectedMessageIds = _messages.map((message) => message.id).toSet(),
    );
  }

  List<MailMessage> get _selectedMessages {
    if (_selectedMessageIds.isEmpty) return const [];
    return [
      for (final message in _messages)
        if (_selectedMessageIds.contains(message.id)) message,
    ];
  }

  _MailUndoSnapshot _captureMailUndoSnapshot() {
    return _MailUndoSnapshot(
      messages: List.unmodifiable(_messages),
      selected: _selected,
      selectedMessageIds: Set.unmodifiable(_selectedMessageIds),
      pinnedMessageIds: Set.unmodifiable(_pinnedMessageIds),
      interactionSettings: _interactionSettings,
    );
  }

  void _restoreMailUndoSnapshot(
    _MailUndoSnapshot snapshot, {
    String? notice = 'Mail action undone.',
  }) {
    if (!mounted) return;
    setState(() {
      _messages = snapshot.messages;
      _selected = snapshot.selected;
      _selectedMessageIds = snapshot.selectedMessageIds;
      _pinnedMessageIds = snapshot.pinnedMessageIds;
      _interactionSettings = snapshot.interactionSettings;
    });
    if (notice != null) {
      _showTransientNotice(notice);
    }
    _updateMobileMessageNotifiers(snapshot.messages);
    _ensureSelectedMessageBody();
  }

  void _scheduleUndoableMailAction({
    required String description,
    required _MailUndoSnapshot snapshot,
    required VoidCallback applyLocal,
    required Future<void> Function() commitRemote,
  }) {
    applyLocal();
    var undone = false;
    var committing = false;
    final messenger = ScaffoldMessenger.of(context);
    final snackBarGeneration = ++_mailUndoSnackBarGeneration;
    _mailUndoSnackBarVisible = true;
    messenger.hideCurrentSnackBar();
    late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
    snackBarController;
    late final Timer timer;

    void markUndoSnackBarClosed() {
      if (_mailUndoSnackBarGeneration == snackBarGeneration) {
        _mailUndoSnackBarVisible = false;
      }
    }

    timer = Timer(_mailActionUndoWindow, () async {
      if (undone || !mounted) return;
      committing = true;
      markUndoSnackBarClosed();
      snackBarController.close();
      try {
        await _refreshOAuthVaultIfNeeded();
        if (undone || !mounted) return;
        await commitRemote();
      } catch (error) {
        if (!mounted) return;
        _restoreMailUndoSnapshot(snapshot, notice: null);
        _showTransientNotice(
          'Could not sync mail action: $error',
          kind: _NoticeKind.error,
        );
      }
    });

    snackBarController = messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(child: Text(description)),
            const SizedBox(width: 12),
            _UndoCountdownIndicator(duration: _mailActionUndoWindow),
          ],
        ),
        duration: _mailActionUndoWindow,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (committing) return;
            undone = true;
            timer.cancel();
            _restoreMailUndoSnapshot(snapshot);
          },
        ),
      ),
    );
    snackBarController.closed.whenComplete(() {
      markUndoSnackBarClosed();
    });
  }

  void _dismissMailUndoPrompt() {
    if (!_mailUndoSnackBarVisible) return;
    _mailUndoSnackBarVisible = false;
    _visiblePendingMailActionId = null;
    _mailUndoSnackBarGeneration++;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  void _schedulePendingMailAction({
    required String description,
    required List<MailMessage> messages,
    required Future<Set<String>> Function(List<MailMessage> messages)
    commitRemote,
  }) {
    final alreadyPending = _pendingRemovedMessageIds;
    final actionable = messages
        .where((message) => !alreadyPending.contains(message.id))
        .toList(growable: false);
    if (actionable.isEmpty) return;
    final action = _PendingMailAction(
      id: ++_nextPendingMailActionId,
      description: description,
      messages: List.unmodifiable(actionable),
      messageIds: Set.unmodifiable(actionable.map((message) => message.id)),
      displayOrder: Map.unmodifiable({
        for (var index = 0; index < _messages.length; index++)
          _messages[index].id: index,
      }),
      commitRemote: () => commitRemote(actionable),
    );
    _pendingMailActions[action.id] = action;
    _removeMessages(action.messageIds);
    _showPendingMailUndoPrompt(action);
    action.timer = Timer(
      _mailActionUndoWindow,
      () => unawaited(_commitPendingMailAction(action.id)),
    );
  }

  void _showPendingMailUndoPrompt(_PendingMailAction action) {
    final messenger = ScaffoldMessenger.of(context);
    final snackBarGeneration = ++_mailUndoSnackBarGeneration;
    _mailUndoSnackBarVisible = true;
    _visiblePendingMailActionId = action.id;
    messenger.hideCurrentSnackBar();
    late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
    snackBarController;

    void markUndoSnackBarClosed() {
      if (_mailUndoSnackBarGeneration == snackBarGeneration) {
        _mailUndoSnackBarVisible = false;
        _visiblePendingMailActionId = null;
      }
    }

    action.closePrompt = () {
      if (_visiblePendingMailActionId != action.id) return;
      markUndoSnackBarClosed();
      snackBarController.close();
    };

    snackBarController = messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(child: Text(action.description)),
            const SizedBox(width: 12),
            _UndoCountdownIndicator(duration: _mailActionUndoWindow),
          ],
        ),
        duration: _mailActionUndoWindow + const Duration(milliseconds: 250),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _undoPendingMailAction(action.id),
        ),
      ),
    );
    snackBarController.closed.whenComplete(markUndoSnackBarClosed);
  }

  void _undoPendingMailAction(int actionId) {
    final action = _pendingMailActions[actionId];
    if (action == null || action.committing) return;
    _pendingMailActions.remove(actionId);
    action.undone = true;
    action.timer?.cancel();
    action.closePrompt?.call();
    _restorePendingMessages(action.messages, displayOrder: action.displayOrder);
    _showTransientNotice('Mail action undone.', kind: _NoticeKind.success);
  }

  Future<void> _commitPendingMailAction(int actionId) async {
    final action = _pendingMailActions[actionId];
    if (action == null || action.undone || action.committing) return;
    action.committing = true;
    action.timer?.cancel();
    action.closePrompt?.call();
    try {
      if (mounted) {
        await _refreshOAuthVaultIfNeeded();
      }
      if (action.undone) return;
      await action.commitRemote();
      _pendingMailActions.remove(actionId);
    } catch (error) {
      final committedIds =
          error is _PendingMailCommitFailure
              ? error.committedMessageIds
              : const <String>{};
      final cause = error is _PendingMailCommitFailure ? error.cause : error;
      _pendingMailActions.remove(actionId);
      if (!mounted) return;
      _restorePendingMessages(
        action.messages
            .where((message) => !committedIds.contains(message.id))
            .toList(growable: false),
        displayOrder: action.displayOrder,
      );
      _showTransientNotice(
        'Could not sync mail action: $cause',
        kind: _NoticeKind.error,
      );
    }
  }

  Future<void> _flushPendingMailActions() async {
    if (_flushingPendingMailActions || _pendingMailActions.isEmpty) return;
    _flushingPendingMailActions = true;
    try {
      final actionIds = _pendingMailActions.keys.toList(growable: false);
      for (final actionId in actionIds) {
        await _commitPendingMailAction(actionId);
      }
    } finally {
      _flushingPendingMailActions = false;
    }
  }

  void _restorePendingMessages(
    List<MailMessage> messages, {
    Map<String, int> displayOrder = const {},
  }) {
    if (!mounted || messages.isEmpty) return;
    final hidden = _pendingRemovedMessageIds;
    final restorable = messages
        .where(
          (message) =>
              !hidden.contains(message.id) &&
              _messageBelongsToCurrentView(message),
        )
        .toList(growable: false);
    if (restorable.isEmpty) {
      _ensureSelectedMessageBody();
      return;
    }
    setState(() {
      final byId = {for (final message in restorable) message.id: message};
      final merged = <MailMessage>[];
      final seen = <String>{};
      for (final message in _messages) {
        final restored = byId[message.id];
        merged.add(restored ?? message);
        seen.add(message.id);
      }
      final missing = [
        for (final message in restorable)
          if (!seen.contains(message.id)) message,
      ]..sort(
        (a, b) => (displayOrder[a.id] ?? _messages.length).compareTo(
          displayOrder[b.id] ?? _messages.length,
        ),
      );
      for (final message in missing) {
        if (!seen.add(message.id)) continue;
        final preferredIndex = displayOrder[message.id];
        if (preferredIndex == null) {
          merged.add(message);
          continue;
        }
        final insertIndex = preferredIndex.clamp(0, merged.length).toInt();
        merged.insert(insertIndex, message);
      }
      _messages = _sortMessagesForDisplay(merged);
      _selected = _messageFor(_messages, _selected?.id, fallbackToFirst: false);
      _selectedMessageIds = _selectedMessageIds.intersection(
        _messages.map((message) => message.id).toSet(),
      );
    });
    _updateMobileMessageNotifiers(restorable);
    _ensureSelectedMessageBody();
  }

  Future<Set<String>> _commitPendingMessages(
    List<MailMessage> messages,
    Future<void> Function(MailMessage message) commitMessage,
  ) async {
    final committed = <String>{};
    try {
      for (final message in messages) {
        await commitMessage(message);
        committed.add(message.id);
      }
      return committed;
    } catch (error) {
      throw _PendingMailCommitFailure(
        cause: error,
        committedMessageIds: Set.unmodifiable(committed),
      );
    }
  }

  void _runImmediateMailAction({
    required String description,
    required _MailUndoSnapshot snapshot,
    required VoidCallback applyLocal,
    required Future<void> Function() commitRemote,
    bool restoreSnapshotOnFailure = true,
  }) {
    applyLocal();
    if (_visiblePendingMailActionId == null) {
      _dismissMailUndoPrompt();
      _showTransientNotice(description);
    }
    unawaited(
      _commitImmediateMailAction(
        snapshot: snapshot,
        commitRemote: commitRemote,
        restoreSnapshotOnFailure: restoreSnapshotOnFailure,
      ),
    );
  }

  Future<void> _commitImmediateMailAction({
    required _MailUndoSnapshot snapshot,
    required Future<void> Function() commitRemote,
    required bool restoreSnapshotOnFailure,
  }) async {
    try {
      await _refreshOAuthVaultIfNeeded();
      if (!mounted) return;
      await commitRemote();
    } catch (error) {
      if (!mounted) return;
      if (restoreSnapshotOnFailure) {
        _restoreMailUndoSnapshot(snapshot, notice: null);
      } else {
        await _reloadMessages();
      }
      _showTransientNotice(
        'Could not sync mail action: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  void _scheduleTogglePinnedMessages(List<MailMessage> messages) {
    if (messages.isEmpty) return;
    final selectedIds = messages.map((message) => message.id).toSet();
    final allPinned = selectedIds.every(_pinnedMessageIds.contains);
    final next = {..._pinnedMessageIds};
    if (allPinned) {
      next.removeAll(selectedIds);
    } else {
      next.addAll(selectedIds);
    }
    final snapshot = _captureMailUndoSnapshot();
    _scheduleUndoableMailAction(
      description:
          allPinned
              ? _messageCountLabel(
                messages.length,
                'Message unpinned.',
                pluralNoun: 'messages unpinned.',
              )
              : _messageCountLabel(
                messages.length,
                'Message pinned.',
                pluralNoun: 'messages pinned.',
              ),
      snapshot: snapshot,
      applyLocal: () => _applyPinnedMessageIdsLocal(next),
      commitRemote: () => _persistPinnedMessageIds(next),
    );
  }

  void _scheduleSetReadMessages(List<MailMessage> messages, bool read) {
    if (messages.isEmpty) return;
    final snapshot = _captureMailUndoSnapshot();
    final updated = [
      for (final message in messages) message.copyWith(read: read),
    ];
    _runImmediateMailAction(
      description:
          read
              ? _messageCountLabel(
                messages.length,
                'Message marked read.',
                pluralNoun: 'messages marked read.',
              )
              : _messageCountLabel(
                messages.length,
                'Message marked unread.',
                pluralNoun: 'messages marked unread.',
              ),
      snapshot: snapshot,
      applyLocal: () => _replaceMessages(updated),
      commitRemote: () async {
        for (final message in messages) {
          final remote = await _mailRepository.setRead(
            message: message,
            read: read,
          );
          if (!mounted) return;
          _replaceMessages([remote]);
        }
      },
    );
  }

  void _scheduleSetStarredMessages(List<MailMessage> messages, bool starred) {
    if (messages.isEmpty) return;
    final snapshot = _captureMailUndoSnapshot();
    final updated = [
      for (final message in messages) message.copyWith(starred: starred),
    ];
    _runImmediateMailAction(
      description:
          starred
              ? _messageCountLabel(
                messages.length,
                'Message starred.',
                pluralNoun: 'messages starred.',
              )
              : _messageCountLabel(
                messages.length,
                'Message unstarred.',
                pluralNoun: 'messages unstarred.',
              ),
      snapshot: snapshot,
      applyLocal: () => _replaceMessages(updated),
      commitRemote: () async {
        for (final message in messages) {
          final remote = await _mailRepository.setStarred(
            message: message,
            starred: starred,
          );
          if (!mounted) return;
          _replaceMessages([remote]);
        }
      },
    );
  }

  void _scheduleArchiveMessages(List<MailMessage> messages) {
    final archiveable = messages
        .where(
          (message) => _mailListActionAppliesToMessage(
            MailListActionPreference.archive,
            message,
          ),
        )
        .toList(growable: false);
    if (archiveable.isEmpty) {
      if (mounted) {
        _showTransientNotice('Selected messages are already archived.');
      }
      return;
    }
    _schedulePendingMailAction(
      description: _messageCountLabel(
        archiveable.length,
        'Message archived.',
        pluralNoun: 'messages archived.',
      ),
      messages: archiveable,
      commitRemote:
          (pendingMessages) =>
              _commitPendingMessages(pendingMessages, _mailRepository.archive),
    );
  }

  void _scheduleDeleteMessages(List<MailMessage> messages) {
    final deletable = messages
        .where(
          (message) => _mailListActionAppliesToMessage(
            MailListActionPreference.delete,
            message,
          ),
        )
        .toList(growable: false);
    if (deletable.isEmpty) {
      if (mounted) {
        _showTransientNotice('Selected messages are already in Trash.');
      }
      return;
    }
    _schedulePendingMailAction(
      description: _messageCountLabel(
        deletable.length,
        'Message moved to trash.',
        pluralNoun: 'messages moved to trash.',
      ),
      messages: deletable,
      commitRemote:
          (pendingMessages) =>
              _commitPendingMessages(pendingMessages, _mailRepository.delete),
    );
  }

  void _scheduleMoveToInboxMessages(List<MailMessage> messages) {
    final movableMessages = messages
        .where((message) => _canMoveToInbox(message.effectiveMailbox))
        .toList(growable: false);
    if (movableMessages.isEmpty) {
      if (!mounted) return;
      _showTransientNotice('No selected messages can move to inbox.');
      return;
    }
    _schedulePendingMailAction(
      description: _messageCountLabel(
        movableMessages.length,
        'Message moved to inbox.',
        pluralNoun: 'messages moved to inbox.',
      ),
      messages: movableMessages,
      commitRemote:
          (pendingMessages) => _commitPendingMessages(
            pendingMessages,
            _mailRepository.moveToInbox,
          ),
    );
  }

  void _scheduleMoveToMailboxMessages(
    List<MailMessage> messages,
    MailboxKind destination,
  ) {
    final movable = messages
        .where((message) => message.effectiveMailbox != destination)
        .toList(growable: false);
    if (movable.isEmpty) {
      if (mounted) {
        _showTransientNotice(
          'Selected messages are already in ${_labelForMailbox(destination)}.',
        );
      }
      return;
    }
    _schedulePendingMailAction(
      description: _messageCountLabel(
        movable.length,
        'Message moved to ${_labelForMailbox(destination)}.',
        pluralNoun: 'messages moved to ${_labelForMailbox(destination)}.',
      ),
      messages: movable,
      commitRemote:
          (pendingMessages) => _commitPendingMessages(
            pendingMessages,
            (message) => _mailRepository.moveToMailbox(
              message: message,
              destination: destination,
            ),
          ),
    );
  }

  void _applyPinnedMessageIdsLocal(Set<String> pinnedMessageIds) {
    final sorted = pinnedMessageIds.toList()..sort();
    final settings = _interactionSettings.copyWith(pinnedMessageIds: sorted);
    setState(() {
      _interactionSettings = settings;
      _pinnedMessageIds = pinnedMessageIds;
      _messages = _sortMessagesForDisplay(
        _messages,
        pinnedMessageIds: pinnedMessageIds,
      );
    });
  }

  Future<void> _persistPinnedMessageIds(Set<String> pinnedMessageIds) async {
    final sorted = pinnedMessageIds.toList()..sort();
    final settings = _interactionSettings.copyWith(pinnedMessageIds: sorted);
    await const MailInteractionSettingsStore().save(settings);
  }

  String _messageCountLabel(int count, String singular, {String? pluralNoun}) {
    if (count == 1) return singular;
    return '$count ${pluralNoun ?? 'messages updated.'}';
  }

  Future<void> _runMessageAction(
    MailMessage message,
    MailListActionPreference action,
  ) async {
    try {
      switch (action) {
        case MailListActionPreference.pin:
          _scheduleTogglePinnedMessages([message]);
        case MailListActionPreference.delete:
          _scheduleDeleteMessages([message]);
        case MailListActionPreference.toggleRead:
          _scheduleSetReadMessages([message], !message.read);
        case MailListActionPreference.toggleStar:
          _scheduleSetStarredMessages([message], !message.starred);
        case MailListActionPreference.archive:
          _scheduleArchiveMessages([message]);
        case MailListActionPreference.moveToInbox:
          _scheduleMoveToInboxMessages([message]);
      }
    } catch (error) {
      if (!mounted) return;
      _showTransientNotice(
        'Mail action failed: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  Future<void> _runBatchMessageAction(MailListActionPreference action) async {
    final messages = _selectedMessages;
    if (messages.isEmpty) return;
    try {
      switch (action) {
        case MailListActionPreference.pin:
          _scheduleTogglePinnedMessages(messages);
        case MailListActionPreference.delete:
          _scheduleDeleteMessages(messages);
        case MailListActionPreference.toggleRead:
          final read = messages.any((message) => !message.read);
          _scheduleSetReadMessages(messages, read);
        case MailListActionPreference.toggleStar:
          final starred = messages.any((message) => !message.starred);
          _scheduleSetStarredMessages(messages, starred);
        case MailListActionPreference.archive:
          _scheduleArchiveMessages(messages);
        case MailListActionPreference.moveToInbox:
          _scheduleMoveToInboxMessages(messages);
      }
      if (!mounted) return;
      setState(() => _selectedMessageIds = const <String>{});
    } catch (error) {
      if (!mounted) return;
      _showTransientNotice(
        'Batch mail action failed: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  Future<void> _moveSelectedMessagesToMailbox(MailboxKind destination) async {
    final messages = _selectedMessages;
    if (messages.isEmpty) return;
    try {
      _scheduleMoveToMailboxMessages(messages, destination);
      if (!mounted) return;
      setState(() => _selectedMessageIds = const <String>{});
    } catch (error) {
      if (!mounted) return;
      _showTransientNotice(
        'Batch mail action failed: $error',
        kind: _NoticeKind.error,
      );
    }
  }

  void _replaceMessages(List<MailMessage> updatedMessages) {
    if (updatedMessages.isEmpty) return;
    final currentById = {for (final message in _messages) message.id: message};
    final selected = _selected;
    if (selected != null &&
        (selected.bodyLoaded ||
            !(currentById[selected.id]?.bodyLoaded ?? false))) {
      currentById[selected.id] = selected;
    }
    for (final entry in _mobileMessageNotifiers.entries) {
      final current = currentById[entry.key];
      if (entry.value.value.bodyLoaded && !(current?.bodyLoaded ?? false)) {
        currentById[entry.key] = entry.value.value;
      }
    }
    final mergedUpdates = [
      for (final update in updatedMessages)
        if (currentById[update.id] case final current?)
          mailMessageUpdatePreservingLoadedBody(
            current: current,
            update: update,
          )
        else
          update,
    ];
    setState(() {
      final byId = {for (final message in mergedUpdates) message.id: message};
      final messages = <MailMessage>[];
      for (final message in _messages) {
        final updated = byId[message.id];
        if (updated == null) {
          messages.add(message);
        } else if (_messageBelongsToCurrentView(updated)) {
          messages.add(updated);
        }
      }
      _messages = _sortMessagesForDisplay(messages);
      _selectedMessageIds = _selectedMessageIds.intersection(
        messages.map((message) => message.id).toSet(),
      );
      final selected = _selected;
      if (selected != null) {
        final updatedSelected = byId[selected.id];
        if (updatedSelected != null) {
          _selected =
              _messageBelongsToCurrentView(updatedSelected)
                  ? updatedSelected
                  : _messageFor(messages, null);
        }
      }
    });
    _updateMobileMessageNotifiers(mergedUpdates);
  }

  void _replaceMessage(MailMessage updated) {
    _replaceMessages([updated]);
  }

  void _updateMobileMessageNotifiers(Iterable<MailMessage> messages) {
    for (final message in messages) {
      final notifier = _mobileMessageNotifiers[message.id];
      if (notifier != null) {
        notifier.value = message;
      }
    }
  }

  void _removeMessages(Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    final selectedMessageId = _selected?.id;
    setState(() {
      _messages =
          _messages
              .where((message) => !messageIds.contains(message.id))
              .toList();
      _selected = _messageFor(
        _messages,
        selectedMessageId,
        fallbackToFirst: selectedMessageId != null,
      );
      _selectedMessageIds = _selectedMessageIds.difference(messageIds);
    });
    _ensureSelectedMessageBody();
  }

  bool _messageBelongsToCurrentView(MailMessage message) {
    if (!mailMessageMatchesQuery(message, _search.text)) return false;
    final smart = _view.smartFolder;
    if (smart != null) return mailMessageMatchesSmartFolder(message, smart);
    final folder = _view.folder;
    return folder == null || mailMessageMatchesFolder(message, folder);
  }

  String? _selectedAccountIdFor(List<MailAccount> accounts) {
    final selected = _selectedAccountId;
    if (selected == null) return null;
    return accounts.any((account) => account.id == selected) ? selected : null;
  }

  MailMessage? _messageFor(
    List<MailMessage> messages,
    String? preferredId, {
    bool fallbackToFirst = true,
  }) {
    if (messages.isEmpty) return null;
    if (preferredId != null) {
      for (final message in messages) {
        if (message.id == preferredId) return message;
      }
    }
    return fallbackToFirst ? messages.first : null;
  }

  MailMessage? _messageForId(List<MailMessage> messages, String id) {
    for (final message in messages) {
      if (message.id == id) return message;
    }
    return null;
  }
}
