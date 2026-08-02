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
import '../system/notification_service.dart';
import '../system/startup_service.dart';
import '../system/system_behavior_settings.dart';
import '../system/tray_service.dart';
import 'mail_html_view.dart';

const _maxOutgoingAttachmentBytes = 25 * 1024 * 1024;
const _googleAndroidOAuthClient = GoogleAndroidOAuthClient();
const _mailRefreshTimeout = Duration(seconds: 45);
const _mailLoadMoreTimeout = Duration(seconds: 60);
const _oauthRefreshTimeout = Duration(seconds: 20);
const _folderDiscoveryTimeout = Duration(seconds: 45);
const _automaticMailRefreshInterval = Duration(minutes: 1);

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
  final _search = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'Mail search');
  bool _hasMoreMessages = true;
  int _messageLoadGeneration = 0;
  SystemBehaviorSettings _systemSettings = SystemBehaviorSettings.defaults;
  Timer? _automaticMailRefreshTimer;
  bool _automaticMailRefreshInProgress = false;
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
    unawaited(_flushPendingMailActions());
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
        _appIsInForeground = false;
        _automaticMailRefreshTimer?.cancel();
        _automaticMailRefreshTimer = null;
        unawaited(_flushPendingMailActions());
        break;
      case AppLifecycleState.resumed:
        _appIsInForeground = true;
        _syncAutomaticMailRefresh();
        unawaited(_refreshMailboxAutomatically(forceFullRefresh: true));
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
      }
    }
  }

  void _syncAutomaticMailRefresh() {
    _automaticMailRefreshTimer?.cancel();
    _automaticMailRefreshTimer = null;
    if (_pendingStartupMailboxWork > 0 ||
        !_appIsInForeground ||
        !_hasUnlockedLocalVault ||
        _accounts.isEmpty) {
      return;
    }
    _automaticMailRefreshTimer = Timer.periodic(
      _automaticMailRefreshInterval,
      (_) => unawaited(_refreshMailboxAutomatically()),
    );
  }

  Future<void> _refreshMailboxAutomatically({
    bool forceFullRefresh = false,
  }) async {
    if (!_appIsInForeground ||
        _automaticMailRefreshInProgress ||
        _refreshingMail ||
        _pendingStartupMailboxWork > 0 ||
        !_hasUnlockedLocalVault ||
        _accounts.isEmpty) {
      return;
    }
    _automaticMailRefreshInProgress = true;
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
    for (final message in fresh) {
      final content = MailNotificationContent.fromMessage(message);
      await _notificationService.showNewMail(
        notificationKey: message.id,
        title: content.title,
        body: content.body,
        accountLabel: _notificationAccountLabel(message.accountId),
        payload: message.id,
      );
    }
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
    try {
      final result = await widget.releaseService.check();
      if (!mounted) return;
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
    } catch (_) {
      if (!silent && mounted) {
        setState(
          () => _setPersistentNotice(
            'Could not complete the update.',
            kind: _NoticeKind.error,
          ),
        );
      }
    }
  }

  Future<bool> _confirmUpdateInstall(ReleaseArtifact artifact) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: !artifact.force,
          builder:
              (dialogContext) => AlertDialog(
                title: Text(
                  artifact.force ? 'Required update' : 'Install update?',
                ),
                content: _DialogContent(
                  width: 460,
                  maxHeight: 520,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'The release manifest was accepted. Download, verify, and install this artifact?',
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
                    label: const Text('Download'),
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
    final useFolderDrawer = shellWidth < 1500;
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
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              session: _session,
              profile: _profile,
              compactTitle:
                  useFolderDrawer
                      ? _labelForMailboxView(_view, _accounts)
                      : null,
              showFolderMenu: useFolderDrawer,
              onCompose: _accounts.isEmpty ? null : _showCompose,
              onRefresh: _refreshingMail ? null : _loadMessages,
              refreshing: _refreshingMail,
              onSettings: _showSettings,
            ),
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
                  if (constraints.maxWidth < 860) {
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
                  final collapseSidebar = constraints.maxWidth < 1500;
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
    var keepOpen = true;
    _SettingsFeedback? feedback;
    while (keepOpen) {
      if (!mounted) return;
      final smallScreen = MediaQuery.sizeOf(context).width < 720;
      final action =
          smallScreen
              ? await Navigator.of(context).push<_SettingsAction>(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder:
                      (context) => _SettingsPage(
                        session: _session,
                        profile: _profile,
                        accountCount: _accounts.length,
                        claimingVaultShare: _claimingVaultShare,
                        hasPendingPairingQr: _pendingPairingPackage != null,
                        feedback: feedback,
                      ),
                ),
              )
              : await showDialog<_SettingsAction>(
                context: context,
                builder:
                    (context) => _SettingsDialog(
                      session: _session,
                      profile: _profile,
                      accountCount: _accounts.length,
                      claimingVaultShare: _claimingVaultShare,
                      hasPendingPairingQr: _pendingPairingPackage != null,
                      feedback: feedback,
                    ),
              );
      if (!mounted || action == null) return;
      feedback = null;
      if (action == _SettingsAction.addMailbox) {
        feedback = await _showAddMailbox(showResultNotice: false);
        keepOpen = true;
        continue;
      }
      _capturedSettingsFeedback = null;
      _captureSettingsNotices = true;
      try {
        keepOpen = await _handleSettingsAction(action);
        feedback = _capturedSettingsFeedback;
      } finally {
        _captureSettingsNotices = false;
        _capturedSettingsFeedback = null;
      }
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
      );
      if (path == null) return;
      await io.File(path).writeAsString(encoded, encoding: utf8);
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
    if (message.bodyLoaded) return Future.value(message);
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

class _MailUndoSnapshot {
  const _MailUndoSnapshot({
    required this.messages,
    required this.selected,
    required this.selectedMessageIds,
    required this.pinnedMessageIds,
    required this.interactionSettings,
  });

  final List<MailMessage> messages;
  final MailMessage? selected;
  final Set<String> selectedMessageIds;
  final Set<String> pinnedMessageIds;
  final MailInteractionSettings interactionSettings;
}

class _PendingMailAction {
  _PendingMailAction({
    required this.id,
    required this.description,
    required this.messages,
    required this.messageIds,
    required this.displayOrder,
    required this.commitRemote,
  });

  final int id;
  final String description;
  final List<MailMessage> messages;
  final Set<String> messageIds;
  final Map<String, int> displayOrder;
  final Future<Set<String>> Function() commitRemote;
  Timer? timer;
  VoidCallback? closePrompt;
  bool undone = false;
  bool committing = false;
}

class _PendingMailCommitFailure implements Exception {
  const _PendingMailCommitFailure({
    required this.cause,
    required this.committedMessageIds,
  });

  final Object cause;
  final Set<String> committedMessageIds;

  @override
  String toString() => cause.toString();
}

class _UndoCountdownIndicator extends StatefulWidget {
  const _UndoCountdownIndicator({required this.duration});

  final Duration duration;

  @override
  State<_UndoCountdownIndicator> createState() =>
      _UndoCountdownIndicatorState();
}

class _UndoCountdownIndicatorState extends State<_UndoCountdownIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
  }

  @override
  void didUpdateWidget(_UndoCountdownIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration == widget.duration) return;
    _controller
      ..duration = widget.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final remainingProgress = (1 - _controller.value).clamp(0.0, 1.0);
        final remainingSeconds =
            (widget.duration.inMilliseconds * remainingProgress / 1000).ceil();
        return SizedBox.square(
          dimension: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: remainingProgress,
                strokeWidth: 2.5,
                color: colorScheme.inversePrimary,
                backgroundColor: colorScheme.onInverseSurface.withValues(
                  alpha: 0.22,
                ),
              ),
              Text(
                '$remainingSeconds',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UpdateDetailRow extends StatelessWidget {
  const _UpdateDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DialogContent extends StatelessWidget {
  const _DialogContent({
    required this.width,
    required this.child,
    this.maxHeight = 560,
  });

  final double width;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final availableWidth = size.width - 96;
    final effectiveWidth =
        availableWidth > 0 && availableWidth < width ? availableWidth : width;
    final availableHeight = size.height - 220;
    final effectiveMaxHeight =
        availableHeight <= 0
            ? 96.0
            : availableHeight.clamp(96.0, maxHeight).toDouble();
    return SizedBox(
      width: effectiveWidth,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}

class _VaultGatePage extends StatelessWidget {
  const _VaultGatePage({
    required this.profile,
    required this.banner,
    required this.unlocking,
    required this.onUnlock,
    required this.onClearLocalData,
    required this.onCheckUpdates,
  });

  final LocalProfile? profile;
  final String? banner;
  final bool unlocking;
  final VoidCallback onUnlock;
  final VoidCallback onClearLocalData;
  final VoidCallback onCheckUpdates;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title =
        profile == null ? 'Create local vault' : 'Unlock ${profile!.label}';
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: colorScheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.mail_lock_outlined),
              const SizedBox(width: 10),
              Text('NyaMail', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                tooltip: 'Check for updates',
                onPressed: onCheckUpdates,
                icon: const Icon(Icons.system_update_alt),
              ),
              IconButton(
                tooltip: 'Clear local data',
                onPressed: onClearLocalData,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 44,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 18),
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      profile == null
                          ? 'A local vault is required before mail accounts can be added.'
                          : 'Your local vault is locked on this device.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (banner != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        banner!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colorScheme.primary),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: unlocking ? null : onUnlock,
                      icon:
                          unlocking
                              ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                              : Icon(
                                profile == null
                                    ? Icons.add_circle_outline
                                    : Icons.lock_open_outlined,
                              ),
                      label: Text(
                        unlocking
                            ? profile == null
                                ? 'Creating'
                                : 'Unlocking'
                            : profile == null
                            ? 'Create'
                            : 'Unlock',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.session,
    required this.profile,
    required this.compactTitle,
    required this.showFolderMenu,
    required this.onCompose,
    required this.onRefresh,
    required this.refreshing,
    required this.onSettings,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final String? compactTitle;
  final bool showFolderMenu;
  final VoidCallback? onCompose;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 860;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: compact ? _compactRow(context) : _wideRow(context),
        );
      },
    );
  }

  Widget _wideRow(BuildContext context) {
    return Row(
      children: [
        if (showFolderMenu) ...[
          IconButton(
            tooltip: 'Folders',
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu_open),
          ),
          const SizedBox(width: 4),
        ],
        const Icon(Icons.mail_lock_outlined),
        const SizedBox(width: 10),
        Text('NyaMail', style: Theme.of(context).textTheme.titleLarge),
        if (compactTitle != null) ...[
          const SizedBox(width: 12),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              compactTitle!,
              style: Theme.of(context).textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        const Spacer(),
        IconButton(
          tooltip:
              onCompose == null
                  ? 'Add a mailbox before composing'
                  : 'New message',
          onPressed: onCompose,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: refreshing ? 'Refreshing mail...' : 'Refresh mail',
          onPressed: refreshing ? null : onRefresh,
          icon: _RefreshButtonIcon(refreshing: refreshing),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }

  Widget _compactRow(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Folders',
          onPressed:
              showFolderMenu ? () => Scaffold.of(context).openDrawer() : null,
          icon: const Icon(Icons.menu_open),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            compactTitle ?? profile?.label ?? 'NyaMail',
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip:
              onCompose == null
                  ? 'Add a mailbox before composing'
                  : 'New message',
          onPressed: onCompose,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: refreshing ? 'Refreshing mail...' : 'Refresh mail',
          onPressed: refreshing ? null : onRefresh,
          icon: _RefreshButtonIcon(refreshing: refreshing),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }
}

class _RefreshButtonIcon extends StatelessWidget {
  const _RefreshButtonIcon({required this.refreshing});

  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    if (!refreshing) return const Icon(Icons.refresh);
    return const SizedBox.square(
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

enum _NoticeKind { info, success, warning, error, progress }

class _InlineNoticeBanner extends StatelessWidget {
  const _InlineNoticeBanner({
    required this.message,
    required this.kind,
    required this.onDismiss,
    this.actionIcon,
    this.actionTooltip,
    this.onAction,
  });

  final String message;
  final _NoticeKind kind;
  final VoidCallback onDismiss;
  final IconData? actionIcon;
  final String? actionTooltip;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = switch (kind) {
      _NoticeKind.error => colorScheme.errorContainer,
      _NoticeKind.warning => colorScheme.tertiaryContainer,
      _NoticeKind.success => colorScheme.primaryContainer,
      _NoticeKind.info ||
      _NoticeKind.progress => colorScheme.secondaryContainer,
    };
    final foregroundColor = switch (kind) {
      _NoticeKind.error => colorScheme.onErrorContainer,
      _NoticeKind.warning => colorScheme.onTertiaryContainer,
      _NoticeKind.success => colorScheme.onPrimaryContainer,
      _NoticeKind.info ||
      _NoticeKind.progress => colorScheme.onSecondaryContainer,
    };
    return Material(
      color: backgroundColor,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              switch (kind) {
                _NoticeKind.error => Icons.error_outline,
                _NoticeKind.warning => Icons.warning_amber_outlined,
                _NoticeKind.success => Icons.check_circle_outline,
                _NoticeKind.progress => Icons.sync,
                _NoticeKind.info => Icons.info_outline,
              },
              color: foregroundColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: foregroundColor),
              ),
            ),
            if (actionIcon != null && onAction != null)
              IconButton(
                tooltip: actionTooltip,
                onPressed: onAction,
                icon: Icon(actionIcon),
                color: foregroundColor,
                visualDensity: VisualDensity.compact,
              ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
              color: foregroundColor,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

enum _SettingsAction {
  syncAccount,
  checkUpdates,
  addMailbox,
  mailboxes,
  clearMailCache,
  appThemeSettings,
  localVaultSettings,
  mailSettings,
  mailInteractionSettings,
  oauthProviderSettings,
  systemSettings,
  clearLocalData,
  exportVault,
  importVault,
  devices,
  receiveVaultShare,
  showPairingQr,
}

class _SettingsFeedback {
  const _SettingsFeedback({
    required this.message,
    this.kind = _NoticeKind.success,
  });

  final String message;
  final _NoticeKind kind;
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
    this.feedback,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final _SettingsFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: _DialogContent(
        width: 560,
        maxHeight: 680,
        child: _SettingsContent(
          session: session,
          profile: profile,
          accountCount: accountCount,
          claimingVaultShare: claimingVaultShare,
          hasPendingPairingQr: hasPendingPairingQr,
          feedback: feedback,
          compact: false,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
    this.feedback,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final _SettingsFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SettingsContent(
              session: session,
              profile: profile,
              accountCount: accountCount,
              claimingVaultShare: claimingVaultShare,
              hasPendingPairingQr: hasPendingPairingQr,
              feedback: feedback,
              compact: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsContent extends StatelessWidget {
  const _SettingsContent({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
    required this.compact,
    this.feedback,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final bool compact;
  final _SettingsFeedback? feedback;

  @override
  Widget build(BuildContext context) {
    final spacing = compact ? 20.0 : 18.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (feedback case final feedback?) ...[
          _SettingsFeedbackBanner(feedback: feedback),
          SizedBox(height: spacing),
        ],
        _SettingsSection(
          title: 'Mail',
          children: [
            _SettingsTile(
              action: _SettingsAction.addMailbox,
              icon: Icons.add,
              title: 'Add mailbox',
              subtitle:
                  accountCount == 0
                      ? 'No mailbox configured'
                      : accountCount == 1
                      ? '1 mailbox'
                      : '$accountCount mailboxes',
            ),
            _SettingsTile(
              action: _SettingsAction.mailboxes,
              icon: Icons.alternate_email,
              title: 'Mailboxes',
              subtitle:
                  accountCount == 0
                      ? 'No mailbox configured'
                      : '$accountCount configured',
              enabled: accountCount > 0,
            ),
            _SettingsTile(
              action: _SettingsAction.clearMailCache,
              icon: Icons.cleaning_services_outlined,
              title: 'Clear mail cache',
              subtitle: 'Re-fetch messages and rebuild local index',
            ),
            _SettingsTile(
              action: _SettingsAction.oauthProviderSettings,
              icon: Icons.vpn_key_outlined,
              title: 'OAuth providers',
            ),
            _SettingsTile(
              action: _SettingsAction.checkUpdates,
              icon: Icons.system_update_alt,
              title: 'Check for updates',
            ),
          ],
        ),
        SizedBox(height: spacing),
        _SettingsSection(
          title: 'Appearance',
          children: [
            _SettingsTile(
              action: _SettingsAction.appThemeSettings,
              icon: Icons.palette_outlined,
              title: 'App appearance',
            ),
            _SettingsTile(
              action: _SettingsAction.mailSettings,
              icon: Icons.tune,
              title: 'Mail rendering',
            ),
            _SettingsTile(
              action: _SettingsAction.mailInteractionSettings,
              icon: Icons.touch_app_outlined,
              title: 'Mail list actions',
            ),
          ],
        ),
        SizedBox(height: spacing),
        _SettingsSection(
          title: 'System',
          children: [
            _SettingsTile(
              action: _SettingsAction.systemSettings,
              icon: Icons.power_settings_new_outlined,
              title: 'Startup, tray, notifications',
            ),
          ],
        ),
        SizedBox(height: spacing),
        _SettingsSection(
          title: 'Security',
          children: [
            _SettingsTile(
              action: _SettingsAction.localVaultSettings,
              icon: Icons.lock_outline,
              title: 'Local vault',
              subtitle: profile?.label,
            ),
            _SettingsTile(
              action: _SettingsAction.clearLocalData,
              icon: Icons.delete_forever_outlined,
              title: 'Clear local data',
              destructive: true,
            ),
          ],
        ),
        SizedBox(height: spacing),
        _SettingsSection(
          title: 'Vault data',
          children: [
            _SettingsTile(
              action: _SettingsAction.exportVault,
              icon: Icons.file_upload_outlined,
              title: 'Export vault configuration',
              subtitle: 'Encrypted mailbox and OAuth settings only',
            ),
            _SettingsTile(
              action: _SettingsAction.importVault,
              icon: Icons.file_download_outlined,
              title: 'Import vault configuration',
              subtitle: 'Merge with the local vault',
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsFeedbackBanner extends StatelessWidget {
  const _SettingsFeedbackBanner({required this.feedback});

  final _SettingsFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (feedback.kind) {
      _NoticeKind.error => colorScheme.error,
      _NoticeKind.warning => colorScheme.tertiary,
      _NoticeKind.success => colorScheme.primary,
      _NoticeKind.info || _NoticeKind.progress => colorScheme.secondary,
    };
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              switch (feedback.kind) {
                _NoticeKind.error => Icons.error_outline,
                _NoticeKind.warning => Icons.sync_problem_outlined,
                _NoticeKind.success => Icons.check_circle_outline,
                _NoticeKind.progress => Icons.sync,
                _NoticeKind.info => Icons.info_outline,
              },
              color: color,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(feedback.message)),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colorScheme.primary),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.action,
    required this.icon,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.destructive = false,
  });

  final _SettingsAction action;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground =
        destructive && enabled ? colorScheme.error : colorScheme.onSurface;
    final secondary =
        enabled ? colorScheme.onSurfaceVariant : colorScheme.outline;
    final titleColor = enabled ? foreground : secondary;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        enabled: enabled,
        leading: Icon(icon, color: enabled ? foreground : secondary),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: titleColor),
        ),
        subtitle:
            subtitle == null
                ? null
                : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: enabled ? Icon(Icons.chevron_right, color: secondary) : null,
        onTap: enabled ? () => Navigator.of(context).pop(action) : null,
      ),
    );
  }
}

class _SystemSettingsDialog extends StatefulWidget {
  const _SystemSettingsDialog({
    required this.service,
    required this.settings,
    required this.onSettingsChanged,
  });

  final StartupService service;
  final SystemBehaviorSettings settings;
  final Future<void> Function(SystemBehaviorSettings settings)
  onSettingsChanged;

  @override
  State<_SystemSettingsDialog> createState() => _SystemSettingsDialogState();
}

class _SystemSettingsDialogState extends State<_SystemSettingsDialog> {
  bool _loading = true;
  late SystemBehaviorSettings _settings = widget.settings;
  bool _launchAtStartup = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled =
          widget.service.isSupported ? await widget.service.isEnabled() : false;
      if (!mounted) return;
      setState(() {
        _launchAtStartup = enabled;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('System behavior'),
      content: _DialogContent(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Launch at startup'),
              subtitle: Text(widget.service.platformLabel),
              value: _launchAtStartup,
              onChanged:
                  _loading || !widget.service.isSupported
                      ? null
                      : _setLaunchAtStartup,
            ),
            const Divider(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.move_to_inbox_outlined),
              title: const Text('Tray and background mode'),
              subtitle: Text(NyaMailTrayService.platformLabel),
              value: _settings.minimizeToTray,
              onChanged:
                  _loading || !NyaMailTrayService.isSupported
                      ? null
                      : _setMinimizeToTray,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('New mail notifications'),
              subtitle: Text(NyaMailNotificationService.platformLabel),
              value: _settings.newMailNotifications,
              onChanged:
                  _loading || !NyaMailNotificationService.isSupported
                      ? null
                      : _setNewMailNotifications,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.mark_email_read_outlined),
              title: const Text('Open message from notification'),
              subtitle: const Text(
                'Open the matching message when a notification is selected.',
              ),
              value: _settings.openMessageFromNotification,
              onChanged:
                  _loading ||
                          !_settings.newMailNotifications ||
                          !NyaMailNotificationService.isSupported
                      ? null
                      : _setOpenMessageFromNotification,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _setLaunchAtStartup(bool enabled) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.service.setEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _launchAtStartup = enabled;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _setMinimizeToTray(bool enabled) async {
    await _setBehaviorSetting(_settings.copyWith(minimizeToTray: enabled));
  }

  Future<void> _setNewMailNotifications(bool enabled) async {
    await _setBehaviorSetting(
      _settings.copyWith(newMailNotifications: enabled),
    );
  }

  Future<void> _setOpenMessageFromNotification(bool enabled) async {
    await _setBehaviorSetting(
      _settings.copyWith(openMessageFromNotification: enabled),
    );
  }

  Future<void> _setBehaviorSetting(SystemBehaviorSettings settings) async {
    setState(() {
      _settings = settings;
      _loading = true;
      _error = null;
    });
    try {
      await widget.onSettingsChanged(settings);
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _settings = widget.settings;
        _loading = false;
      });
    }
  }
}

enum _MessageAppearanceAction { useSetting, automatic, light, dark }

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.accounts,
    required this.folders,
    required this.accountFailures,
    required this.view,
    required this.onViewChanged,
    required this.onAccountSettings,
    required this.onAddMailbox,
    required this.onDeleteAccount,
    required this.onResolveAccountFailure,
  });

  final List<MailAccount> accounts;
  final List<MailFolder> folders;
  final Map<String, MailAccountSyncFailure> accountFailures;
  final MailboxView view;
  final ValueChanged<MailboxView> onViewChanged;
  final ValueChanged<MailAccount> onAccountSettings;
  final VoidCallback onAddMailbox;
  final ValueChanged<MailAccount> onDeleteAccount;
  final ValueChanged<MailAccount> onResolveAccountFailure;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final _folderFilter = TextEditingController();

  @override
  void dispose() {
    _folderFilter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = _folderFilter.text.trim().toLowerCase();
    final smartFolders = [
      for (final item in MailSmartFolder.values)
        if (_smartFolderMatchesFilter(item, filter)) item,
    ];
    final accountWidgets = <Widget>[];
    for (final account in widget.accounts) {
      final accountMatches = _accountMatchesFilter(account, filter);
      final accountFolders = _foldersForAccount(widget.folders, account.id);
      final visibleFolders =
          filter.isEmpty || accountMatches
              ? accountFolders
              : [
                for (final folder in accountFolders)
                  if (_folderMatchesFilter(folder, filter)) folder,
              ];
      if (filter.isNotEmpty && !accountMatches && visibleFolders.isEmpty) {
        continue;
      }
      accountWidgets.add(_buildAccountSection(account, visibleFolders, filter));
    }
    final hasMatches = smartFolders.isNotEmpty || accountWidgets.isNotEmpty;
    return SizedBox(
      width: 250,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SearchBar(
            controller: _folderFilter,
            hintText: 'Search folders',
            leading: const Icon(Icons.search),
            trailing:
                filter.isEmpty
                    ? null
                    : [
                      IconButton(
                        tooltip: 'Clear folder search',
                        onPressed: () {
                          _folderFilter.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Text('Smart Folders', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          for (final item in smartFolders)
            ListTile(
              selected: widget.view.smartFolder == item,
              leading: Icon(_iconForSmartFolder(item)),
              title: Text(_labelForSmartFolder(item)),
              dense: true,
              onTap: () => widget.onViewChanged(MailboxView.smart(item)),
            ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Accounts',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              IconButton(
                tooltip: 'Add mailbox',
                onPressed: widget.onAddMailbox,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hasMatches)
            ...accountWidgets
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No matching folders',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAccountSection(
    MailAccount account,
    List<MailFolder> visibleFolders,
    String filter,
  ) {
    final filtering = filter.isNotEmpty;
    final failure = widget.accountFailures[account.id];
    final failureLabel =
        failure?.authenticationRequired == true
            ? 'Authorization required'
            : 'Sync failed';
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown:
          account.id == 'all'
              ? null
              : (details) => _showAccountContextMenu(
                context,
                account,
                details.globalPosition,
              ),
      onLongPress:
          account.id == 'all'
              ? null
              : () => _showAccountContextMenu(
                context,
                account,
                Offset(
                  MediaQuery.sizeOf(context).width / 2,
                  MediaQuery.sizeOf(context).height / 3,
                ),
              ),
      child: ExpansionTile(
        key:
            filtering
                ? ValueKey('filtered-account-${account.id}')
                : PageStorageKey('account-${account.id}'),
        initiallyExpanded:
            filtering ||
            widget.view.folder?.accountId == account.id ||
            widget.accounts.length == 1,
        leading: Icon(
          failure == null
              ? Icons.alternate_email
              : failure.authenticationRequired
              ? Icons.key_off_outlined
              : Icons.sync_problem_outlined,
          color: failure == null ? null : colorScheme.error,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                account.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (failure != null)
              IconButton(
                tooltip:
                    failure.authenticationRequired
                        ? 'Reauthorize ${account.address}'
                        : 'Retry ${account.address}',
                visualDensity: VisualDensity.compact,
                onPressed: () => widget.onResolveAccountFailure(account),
                icon: Icon(
                  failure.authenticationRequired ? Icons.key : Icons.refresh,
                  size: 18,
                ),
              ),
          ],
        ),
        subtitle: Text(
          failure == null
              ? account.address
              : '$failureLabel\n${account.address}',
          maxLines: failure == null ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: failure == null ? null : TextStyle(color: colorScheme.error),
        ),
        children: [
          for (final folder in visibleFolders)
            Builder(
              builder: (context) {
                final folderPathLabel = folder.effectiveDisplayPath;
                return ListTile(
                  contentPadding: const EdgeInsets.only(left: 56, right: 12),
                  selected: widget.view.folder?.key == folder.key,
                  leading: Icon(_iconForMailbox(folder.kind), size: 18),
                  title: Text(
                    folder.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle:
                      folderPathLabel == folder.displayName
                          ? null
                          : Text(
                            folderPathLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  dense: true,
                  onTap: () => widget.onViewChanged(MailboxView.folder(folder)),
                );
              },
            ),
        ],
      ),
    );
  }

  bool _smartFolderMatchesFilter(MailSmartFolder folder, String filter) {
    return filter.isEmpty ||
        _sidebarTextMatches(_labelForSmartFolder(folder), filter);
  }

  bool _accountMatchesFilter(MailAccount account, String filter) {
    return filter.isEmpty ||
        _sidebarTextMatches(account.displayName, filter) ||
        _sidebarTextMatches(account.address, filter) ||
        _sidebarTextMatches(account.provider, filter);
  }

  bool _folderMatchesFilter(MailFolder folder, String filter) {
    return filter.isEmpty ||
        _sidebarTextMatches(folder.displayName, filter) ||
        _sidebarTextMatches(folder.effectiveDisplayPath, filter) ||
        _sidebarTextMatches(_labelForMailbox(folder.kind), filter);
  }

  bool _sidebarTextMatches(String value, String filter) {
    return value.toLowerCase().contains(filter);
  }

  Future<void> _showAccountContextMenu(
    BuildContext context,
    MailAccount account,
    Offset position,
  ) async {
    final action = await showMenu<_AccountContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, 0),
      items: const [
        PopupMenuItem(
          value: _AccountContextAction.settings,
          child: ListTile(
            leading: Icon(Icons.settings_outlined),
            title: Text('Settings'),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: _AccountContextAction.delete,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Remove'),
            dense: true,
          ),
        ),
      ],
    );
    switch (action) {
      case _AccountContextAction.settings:
        widget.onAccountSettings(account);
      case _AccountContextAction.delete:
        widget.onDeleteAccount(account);
      case null:
        break;
    }
  }
}

enum _AccountContextAction { settings, delete }

class _MessageList extends StatefulWidget {
  const _MessageList({
    super.key,
    required this.messages,
    required this.selected,
    required this.search,
    required this.searchFocusNode,
    required this.accounts,
    required this.interactionSettings,
    required this.pinnedMessageIds,
    required this.selectedMessageIds,
    required this.keyboardNavigationMessageId,
    required this.keyboardNavigationDirection,
    required this.onSearch,
    required this.onAddMailbox,
    required this.onRefresh,
    required this.onSelect,
    required this.onMessageAction,
    required this.onBatchAction,
    required this.onMoveSelectedToMailbox,
    required this.onMessageSelected,
    required this.onClearSelection,
    required this.onSelectAll,
    required this.canLoadMore,
    required this.loadingMore,
    required this.refreshing,
    required this.onLoadMore,
    required this.supportsMobileSwipe,
    required this.supportsDesktopContextMenu,
  });

  final List<MailMessage> messages;
  final MailMessage? selected;
  final TextEditingController search;
  final FocusNode searchFocusNode;
  final List<MailAccount> accounts;
  final MailInteractionSettings interactionSettings;
  final Set<String> pinnedMessageIds;
  final Set<String> selectedMessageIds;
  final String? keyboardNavigationMessageId;
  final int keyboardNavigationDirection;
  final VoidCallback onSearch;
  final VoidCallback onAddMailbox;
  final VoidCallback? onRefresh;
  final ValueChanged<MailMessage> onSelect;
  final Future<void> Function(
    MailMessage message,
    MailListActionPreference action,
  )
  onMessageAction;
  final Future<void> Function(MailListActionPreference action) onBatchAction;
  final Future<void> Function(MailboxKind destination) onMoveSelectedToMailbox;
  final void Function(String messageId, bool selected) onMessageSelected;
  final VoidCallback onClearSelection;
  final VoidCallback onSelectAll;
  final bool canLoadMore;
  final bool loadingMore;
  final bool refreshing;
  final VoidCallback onLoadMore;
  final bool supportsMobileSwipe;
  final bool supportsDesktopContextMenu;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  static const _loadMoreThreshold = 480.0;
  static const _searchDebounceDelay = Duration(milliseconds: 450);

  final _scrollController = ScrollController();
  final _messageItemKeys = <String, GlobalKey>{};
  Timer? _searchDebounce;
  bool _viewportCheckScheduled = false;
  int? _lastAutoLoadMessageCount;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    _scheduleViewportCheck();
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messages != widget.messages && _messageItemKeys.isNotEmpty) {
      _messageItemKeys.removeWhere(
        (messageId, _) =>
            !widget.messages.any((message) => message.id == messageId),
      );
    }
    if (oldWidget.messages.length != widget.messages.length ||
        oldWidget.canLoadMore != widget.canLoadMore ||
        oldWidget.loadingMore != widget.loadingMore) {
      if (oldWidget.messages.length != widget.messages.length ||
          !widget.canLoadMore) {
        _lastAutoLoadMessageCount = null;
      }
      _scheduleViewportCheck();
    }
    if (oldWidget.keyboardNavigationMessageId !=
        widget.keyboardNavigationMessageId) {
      final targetMessageId = widget.keyboardNavigationMessageId;
      _messageItemKeys.removeWhere(
        (messageId, _) => messageId != targetMessageId,
      );
      _scheduleKeyboardNavigationScroll();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleSearchTextChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, widget.onSearch);
    if (mounted) setState(() {});
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    widget.search.clear();
    if (mounted) setState(() {});
    widget.onSearch();
  }

  void _submitSearch() {
    _searchDebounce?.cancel();
    widget.onSearch();
  }

  void _scheduleViewportCheck() {
    if (_viewportCheckScheduled) return;
    _viewportCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportCheckScheduled = false;
      if (!mounted) return;
      _maybeLoadMore();
    });
  }

  void _maybeLoadMore() {
    if (!widget.canLoadMore ||
        widget.loadingMore ||
        widget.messages.isEmpty ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      _scheduleViewportCheck();
      return;
    }
    if (position.maxScrollExtent <= 0 ||
        position.extentAfter < _loadMoreThreshold) {
      if (_lastAutoLoadMessageCount == widget.messages.length) return;
      _lastAutoLoadMessageCount = widget.messages.length;
      widget.onLoadMore();
    }
  }

  Key _messageItemKeyFor(String messageId) {
    if (widget.keyboardNavigationMessageId != messageId) {
      return ValueKey<String>(messageId);
    }
    return _messageItemKeys.putIfAbsent(messageId, GlobalKey.new);
  }

  void _scheduleKeyboardNavigationScroll() {
    final messageId = widget.keyboardNavigationMessageId;
    if (messageId == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemContext = _messageItemKeys[messageId]?.currentContext;
      if (itemContext == null) {
        _scrollToEstimatedKeyboardTarget(messageId);
        return;
      }
      final direction = widget.keyboardNavigationDirection;
      unawaited(
        Scrollable.ensureVisible(
          itemContext,
          alignment: direction < 0 ? 0 : 1,
          alignmentPolicy:
              direction < 0
                  ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
                  : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _scrollToEstimatedKeyboardTarget(String messageId) {
    if (!_scrollController.hasClients) return;
    final index = widget.messages.indexWhere(
      (message) => message.id == messageId,
    );
    if (index < 0) return;
    const estimatedRowExtent = 96.0;
    final position = _scrollController.position;
    final targetOffset = (index * estimatedRowExtent).clamp(
      0.0,
      position.maxScrollExtent,
    );
    final targetEnd = targetOffset + estimatedRowExtent;
    final shouldScroll =
        widget.keyboardNavigationDirection < 0
            ? targetOffset < position.pixels
            : targetEnd > position.pixels + position.viewportDimension;
    if (!shouldScroll) return;
    unawaited(
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selecting = widget.selectedMessageIds.isNotEmpty;
    final selectedMessages = [
      for (final message in widget.messages)
        if (widget.selectedMessageIds.contains(message.id)) message,
    ];
    final accountLabels = {
      for (final account in widget.accounts)
        account.id:
            account.displayName.trim().isEmpty
                ? account.address
                : account.displayName,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SearchBar(
            controller: widget.search,
            focusNode: widget.searchFocusNode,
            hintText: 'Search mail',
            leading: const Icon(Icons.search),
            trailing:
                widget.search.text.trim().isEmpty
                    ? null
                    : [
                      IconButton(
                        tooltip: 'Clear search',
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close),
                      ),
                    ],
            onChanged: (_) => _handleSearchTextChanged(),
            onSubmitted: (_) => _submitSearch(),
          ),
        ),
        if (selecting)
          _MessageBatchToolbar(
            selectedCount: widget.selectedMessageIds.length,
            selectedMessages: selectedMessages,
            allPinned:
                selectedMessages.isNotEmpty &&
                selectedMessages.every(
                  (message) => widget.pinnedMessageIds.contains(message.id),
                ),
            onAction: widget.onBatchAction,
            onMoveToMailbox: widget.onMoveSelectedToMailbox,
            onClear: widget.onClearSelection,
            onSelectAll: widget.onSelectAll,
          ),
        Expanded(
          child: ListView.separated(
            controller: _scrollController,
            itemCount: widget.messages.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == widget.messages.length) {
                return _MessageListFooter(
                  isEmpty: widget.messages.isEmpty,
                  canLoadMore: widget.canLoadMore,
                  loadingMore: widget.loadingMore,
                  refreshing: widget.refreshing,
                  hasAccounts: widget.accounts.isNotEmpty,
                  hasSearchQuery: widget.search.text.trim().isNotEmpty,
                  onLoadMore: widget.onLoadMore,
                  onAddMailbox: widget.onAddMailbox,
                  onRefresh: widget.onRefresh,
                  onClearSearch: _clearSearch,
                );
              }
              final message = widget.messages[index];
              return KeyedSubtree(
                key: _messageItemKeyFor(message.id),
                child: _messageItem(
                  context: context,
                  message: message,
                  accountLabel:
                      accountLabels[message.accountId] ?? message.accountId,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _messageItem({
    required BuildContext context,
    required MailMessage message,
    required String accountLabel,
  }) {
    final selecting = widget.selectedMessageIds.isNotEmpty;
    final selectedForBatch = widget.selectedMessageIds.contains(message.id);
    Widget child = _MessageListTile(
      message: message,
      accountLabel: accountLabel,
      selected: widget.selected?.id == message.id,
      selectedForBatch: selectedForBatch,
      selecting: selecting,
      pinned: widget.pinnedMessageIds.contains(message.id),
      multiSelectEnabled: widget.interactionSettings.multiSelectEnabled,
      onTap:
          selecting
              ? () => widget.onMessageSelected(message.id, !selectedForBatch)
              : () => widget.onSelect(message),
      onLongPress:
          widget.interactionSettings.multiSelectEnabled
              ? () => widget.onMessageSelected(message.id, true)
              : null,
      onSelectionChanged:
          (value) => widget.onMessageSelected(message.id, value),
      onAction: (action) => widget.onMessageAction(message, action),
    );
    if (widget.supportsDesktopContextMenu &&
        widget.interactionSettings.desktopContextMenuEnabled) {
      child = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown:
            (details) => _showMessageContextMenu(
              context,
              message,
              details.globalPosition,
            ),
        child: child,
      );
    }
    if (widget.supportsMobileSwipe &&
        widget.interactionSettings.mobileSwipeEnabled &&
        !selecting) {
      child = _SwipeActionTile(
        message: message,
        leftLevel1: widget.interactionSettings.mobileSwipeLeftToRightLevel1,
        leftLevel2: widget.interactionSettings.mobileSwipeLeftToRightLevel2,
        rightLevel1: widget.interactionSettings.mobileSwipeRightToLeftLevel1,
        rightLevel2: widget.interactionSettings.mobileSwipeRightToLeftLevel2,
        onAction: (action) => widget.onMessageAction(message, action),
        child: child,
      );
    }
    return child;
  }

  Future<void> _showMessageContextMenu(
    BuildContext context,
    MailMessage message,
    Offset position,
  ) async {
    final actions = widget.interactionSettings.desktopContextMenuActions;
    if (actions.isEmpty) return;
    final action = await showMenu<MailListActionPreference>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, 0),
      items: [
        for (final action in actions)
          if (_mailListActionAppliesToMessage(action, message))
            PopupMenuItem(
              value: action,
              child: ListTile(
                leading: Icon(
                  _mailListActionIcon(
                    action,
                    message: message,
                    pinned: widget.pinnedMessageIds.contains(message.id),
                  ),
                ),
                title: Text(
                  _mailListActionLabel(
                    action,
                    message: message,
                    pinned: widget.pinnedMessageIds.contains(message.id),
                  ),
                ),
                dense: true,
              ),
            ),
      ],
    );
    if (action != null) {
      await widget.onMessageAction(message, action);
    }
  }
}

class _MessageBatchToolbar extends StatelessWidget {
  const _MessageBatchToolbar({
    required this.selectedCount,
    required this.selectedMessages,
    required this.allPinned,
    required this.onAction,
    required this.onMoveToMailbox,
    required this.onClear,
    required this.onSelectAll,
  });

  final int selectedCount;
  final List<MailMessage> selectedMessages;
  final bool allPinned;
  final Future<void> Function(MailListActionPreference action) onAction;
  final Future<void> Function(MailboxKind destination) onMoveToMailbox;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final markRead = selectedMessages.any((message) => !message.read);
    final star = selectedMessages.any((message) => !message.starred);
    final canArchive = selectedMessages.any(
      (message) => _mailListActionAppliesToMessage(
        MailListActionPreference.archive,
        message,
      ),
    );
    final canMoveToInbox = selectedMessages.any(
      (message) => _mailListActionAppliesToMessage(
        MailListActionPreference.moveToInbox,
        message,
      ),
    );
    final canDelete = selectedMessages.any(
      (message) => _mailListActionAppliesToMessage(
        MailListActionPreference.delete,
        message,
      ),
    );
    final moveDestinations = standardMailboxKinds
        .where(
          (destination) => selectedMessages.any(
            (message) => message.effectiveMailbox != destination,
          ),
        )
        .toList(growable: false);
    final actions = [
      if (canArchive) MailListActionPreference.archive,
      if (canMoveToInbox) MailListActionPreference.moveToInbox,
      if (canDelete) MailListActionPreference.delete,
      MailListActionPreference.toggleStar,
      MailListActionPreference.toggleRead,
      MailListActionPreference.pin,
    ];
    return Material(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Clear selection',
              onPressed: onClear,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '$selectedCount selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: 'Select all visible',
              onPressed: onSelectAll,
              icon: const Icon(Icons.select_all),
            ),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in actions)
                      IconButton(
                        tooltip: _mailListActionLabel(
                          action,
                          read:
                              action == MailListActionPreference.toggleRead
                                  ? !markRead
                                  : null,
                          starred:
                              action == MailListActionPreference.toggleStar
                                  ? !star
                                  : null,
                          pinned:
                              action == MailListActionPreference.pin
                                  ? allPinned
                                  : null,
                        ),
                        onPressed: () => onAction(action),
                        color:
                            action == MailListActionPreference.delete
                                ? colorScheme.error
                                : null,
                        icon: Icon(
                          _mailListActionIcon(
                            action,
                            read:
                                action == MailListActionPreference.toggleRead
                                    ? !markRead
                                    : null,
                            starred:
                                action == MailListActionPreference.toggleStar
                                    ? !star
                                    : null,
                            pinned:
                                action == MailListActionPreference.pin
                                    ? allPinned
                                    : null,
                          ),
                        ),
                      ),
                    if (moveDestinations.isNotEmpty)
                      PopupMenuButton<MailboxKind>(
                        tooltip: 'Move to...',
                        icon: const Icon(Icons.drive_file_move_outlined),
                        onSelected:
                            (destination) =>
                                unawaited(onMoveToMailbox(destination)),
                        itemBuilder:
                            (context) => [
                              for (final destination in moveDestinations)
                                PopupMenuItem(
                                  value: destination,
                                  child: Row(
                                    children: [
                                      Icon(_iconForMailbox(destination)),
                                      const SizedBox(width: 12),
                                      Text(_labelForMailbox(destination)),
                                    ],
                                  ),
                                ),
                            ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageListTile extends StatelessWidget {
  const _MessageListTile({
    required this.message,
    required this.accountLabel,
    required this.selected,
    required this.selectedForBatch,
    required this.selecting,
    required this.pinned,
    required this.multiSelectEnabled,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectionChanged,
    required this.onAction,
  });

  final MailMessage message;
  final String accountLabel;
  final bool selected;
  final bool selectedForBatch;
  final bool selecting;
  final bool pinned;
  final bool multiSelectEnabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool> onSelectionChanged;
  final Future<void> Function(MailListActionPreference action) onAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final secondary = colorScheme.onSurfaceVariant;
    final receivedLabel = mailMessageCompactDisplayDate(message.receivedAt);
    final subjectLabel = mailMessageSubjectLabel(message.subject);
    final preview = message.preview.trim();
    final summaryLabel =
        preview.isEmpty ? subjectLabel : '$subjectLabel - $preview';
    return ListTile(
      isThreeLine: true,
      selected: selected,
      leading:
          selecting
              ? Checkbox(
                value: selectedForBatch,
                onChanged:
                    multiSelectEnabled
                        ? (value) => onSelectionChanged(value ?? false)
                        : null,
              )
              : null,
      title: Row(
        children: [
          if (pinned) ...[
            Icon(Icons.push_pin_outlined, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              message.from,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: message.read ? FontWeight.w500 : FontWeight.w700,
              ),
            ),
          ),
          if (message.starred) ...[
            const SizedBox(width: 6),
            Icon(Icons.star, size: 16, color: colorScheme.tertiary),
          ],
          if (message.hasAttachments) ...[
            const SizedBox(width: 6),
            Icon(Icons.attach_file, size: 16, color: secondary),
          ],
          const SizedBox(width: 8),
          Text(
            receivedLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(color: secondary),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              summaryLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: message.read ? FontWeight.w500 : FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  message.read
                      ? Icons.mark_email_read_outlined
                      : Icons.mark_email_unread_outlined,
                  size: 14,
                  color: secondary,
                ),
                const Spacer(),
                const SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: ShapeDecoration(
                        color: colorScheme.secondaryContainer,
                        shape: StadiumBorder(
                          side: BorderSide(color: colorScheme.outlineVariant),
                        ),
                      ),
                      child: Text(
                        accountLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      trailing:
          selecting
              ? null
              : _MessageOverflowMenu(
                message: message,
                pinned: pinned,
                onAction: onAction,
              ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

class _MessageOverflowMenu extends StatelessWidget {
  const _MessageOverflowMenu({
    required this.message,
    required this.pinned,
    required this.onAction,
  });

  final MailMessage message;
  final bool pinned;
  final Future<void> Function(MailListActionPreference action) onAction;

  @override
  Widget build(BuildContext context) {
    const actions = [
      MailListActionPreference.toggleRead,
      MailListActionPreference.toggleStar,
      MailListActionPreference.pin,
      MailListActionPreference.archive,
      MailListActionPreference.moveToInbox,
      MailListActionPreference.delete,
    ];
    final availableActions = [
      for (final action in actions)
        if (_mailListActionAppliesToMessage(action, message)) action,
    ];
    return PopupMenuButton<MailListActionPreference>(
      tooltip: 'Message actions',
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => unawaited(onAction(action)),
      itemBuilder:
          (context) => [
            for (final action in availableActions)
              PopupMenuItem(
                value: action,
                child: Row(
                  children: [
                    Icon(
                      _mailListActionIcon(
                        action,
                        message: message,
                        pinned: pinned,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _mailListActionLabel(
                        action,
                        message: message,
                        pinned: pinned,
                      ),
                    ),
                  ],
                ),
              ),
          ],
    );
  }
}

class _SwipeActionTile extends StatefulWidget {
  const _SwipeActionTile({
    required this.message,
    required this.leftLevel1,
    required this.leftLevel2,
    required this.rightLevel1,
    required this.rightLevel2,
    required this.onAction,
    required this.child,
  });

  final MailMessage message;
  final MailListActionPreference leftLevel1;
  final MailListActionPreference leftLevel2;
  final MailListActionPreference rightLevel1;
  final MailListActionPreference rightLevel2;
  final Future<void> Function(MailListActionPreference action) onAction;
  final Widget child;

  @override
  State<_SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends State<_SwipeActionTile>
    with SingleTickerProviderStateMixin {
  static const _actionPaneWidth = 72.0;
  static const _resetDuration = Duration(milliseconds: 180);

  final _dragDx = ValueNotifier<double>(0);
  late final AnimationController _resetController;
  double _resetStart = 0;

  @override
  void initState() {
    super.initState();
    _resetController = AnimationController(
      vsync: this,
      duration: _resetDuration,
    )..addListener(_applyResetFrame);
  }

  @override
  void dispose() {
    _resetController.dispose();
    _dragDx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _resetController.stop(),
          onHorizontalDragUpdate:
              (details) => _updateDrag(width, details.primaryDelta ?? 0),
          onHorizontalDragEnd: (_) => _finishDrag(width),
          onHorizontalDragCancel: _animateReset,
          child: ValueListenableBuilder<double>(
            valueListenable: _dragDx,
            child: RepaintBoundary(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: widget.child,
              ),
            ),
            builder: (context, dragDx, child) {
              final selection = _currentSelection(width, dragDx);
              final visualDx = _visualOffset(width, dragDx);
              final direction = _swipeDirectionFor(dragDx);
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: _SwipeActionBackground(
                      message: widget.message,
                      direction: direction,
                      revealExtent: visualDx.abs(),
                      level1Action:
                          direction == _SwipeDirection.leftToRight
                              ? widget.leftLevel1
                              : widget.rightLevel1,
                      activeAction: selection?.action,
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(visualDx, 0),
                    child: child!,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _updateDrag(double width, double delta) {
    final next = _dragDx.value + delta;
    _dragDx.value =
        next
            .clamp(-_maxDragDistance(width), _maxDragDistance(width))
            .toDouble();
  }

  _SwipeActionSelection? _currentSelection(double width, double dragDx) {
    final distance = dragDx.abs();
    if (distance < _level1Distance(width)) return null;
    final level2 = distance >= _level2Distance(width);
    final direction = _swipeDirectionFor(dragDx);
    if (direction == null) return null;
    if (dragDx < 0) {
      return _SwipeActionSelection(
        action: level2 ? widget.rightLevel2 : widget.rightLevel1,
      );
    }
    return _SwipeActionSelection(
      action: level2 ? widget.leftLevel2 : widget.leftLevel1,
    );
  }

  Future<void> _finishDrag(double width) async {
    final selection = _currentSelection(width, _dragDx.value);
    _animateReset();
    if (selection != null) {
      await widget.onAction(selection.action);
    }
  }

  void _animateReset() {
    _resetController.stop();
    _resetStart = _dragDx.value;
    if (_resetStart == 0) return;
    _resetController.forward(from: 0);
  }

  void _applyResetFrame() {
    final progress = Curves.easeOutCubic.transform(_resetController.value);
    _dragDx.value = _resetStart * (1 - progress);
  }

  _SwipeDirection? _swipeDirectionFor(double dragDx) {
    if (dragDx > 0) return _SwipeDirection.leftToRight;
    if (dragDx < 0) return _SwipeDirection.rightToLeft;
    return null;
  }

  double _visualOffset(double width, double dragDx) {
    return dragDx
        .clamp(-_maxVisualOffset(width), _maxVisualOffset(width))
        .toDouble();
  }

  double _level1Distance(double width) {
    final level2 = _level2Distance(width);
    return math.min(math.max(12.0, _maxVisualOffset(width) * 0.25), level2 - 4);
  }

  double _level2Distance(double width) {
    return _maxVisualOffset(width) * 0.5;
  }

  double _maxVisualOffset(double width) {
    return math.min(width * 0.58, _actionPaneWidth * 2.25);
  }

  double _maxDragDistance(double width) {
    return math.min(width * 0.72, _actionPaneWidth * 3);
  }
}

enum _SwipeDirection { leftToRight, rightToLeft }

class _SwipeActionSelection {
  const _SwipeActionSelection({required this.action});

  final MailListActionPreference action;
}

class _SwipeActionBackground extends StatelessWidget {
  const _SwipeActionBackground({
    required this.message,
    required this.direction,
    required this.revealExtent,
    required this.level1Action,
    required this.activeAction,
  });

  final MailMessage message;
  final _SwipeDirection? direction;
  final double revealExtent;
  final MailListActionPreference level1Action;
  final MailListActionPreference? activeAction;

  @override
  Widget build(BuildContext context) {
    final resolvedDirection = direction;
    if (resolvedDirection == null || revealExtent <= 0) {
      return const SizedBox.shrink();
    }
    final action = activeAction ?? level1Action;
    return ColoredBox(
      color: Colors.transparent,
      child: Align(
        alignment:
            resolvedDirection == _SwipeDirection.leftToRight
                ? Alignment.centerLeft
                : Alignment.centerRight,
        child: _SwipeActionPane(
          message: message,
          action: action,
          revealExtent: revealExtent,
          active: activeAction == action,
        ),
      ),
    );
  }
}

class _SwipeActionPane extends StatelessWidget {
  const _SwipeActionPane({
    required this.message,
    required this.action,
    required this.revealExtent,
    required this.active,
  });

  final MailMessage message;
  final MailListActionPreference action;
  final double revealExtent;
  final bool active;

  @override
  Widget build(BuildContext context) {
    if (revealExtent <= 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final progress =
        (revealExtent / _SwipeActionTileState._actionPaneWidth)
            .clamp(0.0, 1.0)
            .toDouble();
    return SizedBox(
      width: revealExtent,
      child: ColoredBox(
        color: _mailListActionColor(action, colorScheme),
        child: Center(
          child: Opacity(
            opacity: progress,
            child: Transform.scale(
              scale: active ? 1.08 : 0.9 + (0.1 * progress),
              child: Icon(
                _mailListActionIcon(action, message: message),
                color: _mailListActionForegroundColor(action, colorScheme),
                size: active ? 24 : 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageListFooter extends StatelessWidget {
  const _MessageListFooter({
    required this.isEmpty,
    required this.canLoadMore,
    required this.loadingMore,
    required this.refreshing,
    required this.hasAccounts,
    required this.hasSearchQuery,
    required this.onLoadMore,
    required this.onAddMailbox,
    required this.onClearSearch,
    this.onRefresh,
  });

  final bool isEmpty;
  final bool canLoadMore;
  final bool loadingMore;
  final bool refreshing;
  final bool hasAccounts;
  final bool hasSearchQuery;
  final VoidCallback onLoadMore;
  final VoidCallback onAddMailbox;
  final VoidCallback onClearSearch;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    if (isEmpty && refreshing) {
      return SizedBox(
        height: 260,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text('Refreshing mail...', style: labelStyle),
            ],
          ),
        ),
      );
    }
    if (loadingMore) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text('Loading more mail...', style: labelStyle),
            ],
          ),
        ),
      );
    }
    if (canLoadMore && !isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: TextButton.icon(
            onPressed: onLoadMore,
            icon: const Icon(Icons.expand_more),
            label: const Text('Load more'),
          ),
        ),
      );
    }
    if (isEmpty) {
      return _MessageEmptyState(
        hasAccounts: hasAccounts,
        hasSearchQuery: hasSearchQuery,
        onAddMailbox: onAddMailbox,
        onClearSearch: onClearSearch,
        onRefresh: onRefresh,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(child: Text('No more mail', style: labelStyle)),
    );
  }
}

class _MessageEmptyState extends StatelessWidget {
  const _MessageEmptyState({
    required this.hasAccounts,
    required this.hasSearchQuery,
    required this.onAddMailbox,
    required this.onClearSearch,
    required this.onRefresh,
  });

  final bool hasAccounts;
  final bool hasSearchQuery;
  final VoidCallback onAddMailbox;
  final VoidCallback onClearSearch;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final icon =
        !hasAccounts
            ? Icons.alternate_email
            : hasSearchQuery
            ? Icons.search_off
            : Icons.inbox_outlined;
    final title =
        !hasAccounts
            ? 'No mailbox accounts'
            : hasSearchQuery
            ? 'No matching messages'
            : 'No messages here';
    final message =
        !hasAccounts
            ? 'Add a mailbox to start reading mail on this device.'
            : hasSearchQuery
            ? 'Try a different sender, subject, or attachment name.'
            : 'Refresh to check for new mail.';
    return SizedBox(
      height: 300,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (!hasAccounts)
                FilledButton.icon(
                  onPressed: onAddMailbox,
                  icon: const Icon(Icons.add),
                  label: const Text('Add mailbox'),
                )
              else if (hasSearchQuery)
                OutlinedButton.icon(
                  onPressed: onClearSearch,
                  icon: const Icon(Icons.close),
                  label: const Text('Clear search'),
                )
              else
                OutlinedButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Reader extends StatelessWidget {
  const _Reader({
    required this.message,
    this.mailboxContextLabel = '',
    required this.onSendReply,
    required this.onSendReplyAll,
    required this.onForward,
    required this.onSetRead,
    required this.onSetStarred,
    required this.onArchive,
    required this.onDelete,
    required this.onMoveToInbox,
    required this.onMoveToMailbox,
    required this.onDownloadAttachment,
    required this.renderSettings,
    this.mobileFullScreen = false,
    this.onClose,
  });

  final MailMessage? message;
  final String mailboxContextLabel;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReplyAll;
  final Future<void> Function(MailMessage message) onForward;
  final Future<void> Function(MailMessage message, bool read) onSetRead;
  final Future<void> Function(MailMessage message, bool starred) onSetStarred;
  final Future<void> Function(MailMessage message) onArchive;
  final Future<void> Function(MailMessage message) onDelete;
  final Future<void> Function(MailMessage message) onMoveToInbox;
  final Future<void> Function(MailMessage message, MailboxKind destination)
  onMoveToMailbox;
  final Future<void> Function(MailMessage message, MailAttachment attachment)
  onDownloadAttachment;
  final MailRenderSettings renderSettings;
  final bool mobileFullScreen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    if (message == null) {
      return const _ReaderEmptyState();
    }
    return _ReaderBody(
      message: message,
      mailboxContextLabel: mailboxContextLabel,
      onSendReply: onSendReply,
      onSendReplyAll: onSendReplyAll,
      onForward: onForward,
      onSetRead: onSetRead,
      onSetStarred: onSetStarred,
      onArchive: onArchive,
      onDelete: onDelete,
      onMoveToInbox: onMoveToInbox,
      onMoveToMailbox: onMoveToMailbox,
      onDownloadAttachment: onDownloadAttachment,
      renderSettings: renderSettings,
      mobileFullScreen: mobileFullScreen,
      onClose: onClose,
    );
  }
}

class _ReaderEmptyState extends StatelessWidget {
  const _ReaderEmptyState();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.mark_email_unread_outlined,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              'Select a message',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Your mail will open here.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({
    this.title = 'New message',
    required this.accounts,
    required this.initialAccountId,
    this.initialTo = '',
    this.initialCc = '',
    this.initialBcc = '',
    this.initialSubject = '',
    this.initialBody = '',
    this.initialHtmlBody = '',
    this.initialAttachments = const [],
    this.onDraftChanged,
    required this.onSend,
  });

  final String title;
  final List<MailAccount> accounts;
  final String? initialAccountId;
  final String initialTo;
  final String initialCc;
  final String initialBcc;
  final String initialSubject;
  final String initialBody;
  final String initialHtmlBody;
  final List<OutgoingAttachment> initialAttachments;
  final Future<void> Function(MailDraft draft)? onDraftChanged;
  final Future<void> Function({
    required String accountId,
    required String to,
    required String cc,
    required String bcc,
    required String subject,
    required String textBody,
    required String htmlBody,
    required List<OutgoingAttachment> attachments,
  })
  onSend;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  late String _accountId = _initialAccountId();
  late final TextEditingController _to;
  late final TextEditingController _cc;
  late final TextEditingController _bcc;
  late final TextEditingController _subject;
  late final TextEditingController _body;
  final _attachments = <OutgoingAttachment>[];
  InAppWebViewController? _bodyWebController;
  bool _bodyEditorReady = false;
  bool _showCcBcc = false;
  bool _savingDraft = false;
  bool _draftSaveFailed = false;
  bool _draftEverSaved = false;
  Timer? _draftSaveTimer;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _to = TextEditingController(text: widget.initialTo);
    _cc = TextEditingController(text: widget.initialCc);
    _bcc = TextEditingController(text: widget.initialBcc);
    _subject = TextEditingController(text: widget.initialSubject);
    _body = TextEditingController(text: widget.initialBody);
    _attachments.addAll(widget.initialAttachments);
    _showCcBcc =
        widget.initialCc.trim().isNotEmpty ||
        widget.initialBcc.trim().isNotEmpty;
    _to.addListener(_scheduleDraftSave);
    _cc.addListener(_scheduleDraftSave);
    _bcc.addListener(_scheduleDraftSave);
    _subject.addListener(_scheduleDraftSave);
    if (!_supportsReplyRichEditor) {
      _body.addListener(_scheduleDraftSave);
    }
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _to.dispose();
    _cc.dispose();
    _bcc.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  String _initialAccountId() {
    final initial = widget.initialAccountId;
    if (initial != null &&
        widget.accounts.any((account) => account.id == initial)) {
      return initial;
    }
    return widget.accounts.first.id;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _DialogContent(
        width: 520,
        maxHeight: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _accountId,
              decoration: const InputDecoration(labelText: 'From'),
              items: [
                for (final account in widget.accounts)
                  DropdownMenuItem(
                    value: account.id,
                    child: Text(
                      '${account.displayName} <${account.address}>',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged:
                  _sending
                      ? null
                      : (value) {
                        setState(() => _accountId = value ?? _accountId);
                        _scheduleDraftSave();
                      },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _to,
              decoration: const InputDecoration(
                labelText: 'To',
                hintText: 'name@example.com',
              ),
            ),
            const SizedBox(height: 10),
            if (!_showCcBcc) ...[
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed:
                      _sending ? null : () => setState(() => _showCcBcc = true),
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('Cc/Bcc'),
                ),
              ),
            ] else ...[
              TextField(
                controller: _cc,
                decoration: const InputDecoration(
                  labelText: 'Cc',
                  hintText: 'name@example.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _bcc,
                decoration: const InputDecoration(
                  labelText: 'Bcc',
                  hintText: 'name@example.com',
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _subject,
              decoration: const InputDecoration(labelText: 'Subject'),
            ),
            const SizedBox(height: 10),
            _composeBodyEditor(context),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _sending ? null : _pickAttachments,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _attachments.isEmpty
                        ? 'No attachments'
                        : '${_attachments.length} attached - '
                            '${_formatBytes(_attachmentTotalBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (_attachments.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (var index = 0; index < _attachments.length; index++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    _attachments[index].filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _outgoingAttachmentSubtitle(_attachments[index]),
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove attachment',
                    onPressed:
                        _sending
                            ? null
                            : () {
                              setState(() => _attachments.removeAt(index));
                              _scheduleDraftSave();
                            },
                    icon: const Icon(Icons.close),
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_draftStatusLabel != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              _draftStatusLabel!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    _draftSaveFailed
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        TextButton(
          onPressed: _sending ? null : _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _sending ? null : _send,
          icon:
              _sending
                  ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(),
                  )
                  : const Icon(Icons.send),
          label: const Text('Send'),
        ),
      ],
    );
  }

  Widget _composeBodyEditor(BuildContext context) {
    if (!_supportsReplyRichEditor) {
      return TextField(
        controller: _body,
        minLines: 8,
        maxLines: 12,
        decoration: const InputDecoration(labelText: 'Message'),
      );
    }
    final colorScheme = Theme.of(context).colorScheme;
    final dark = colorScheme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ReplyComposerToolbar(
          enabled: _bodyEditorReady && !_sending,
          onCommand: _execBodyEditorCommand,
          onInsertLink: _insertBodyLink,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 240,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: InAppWebView(
                initialData: InAppWebViewInitialData(
                  data: _replyEditorHtml(
                    dark: dark,
                    initialText: widget.initialBody,
                    initialHtml: widget.initialHtmlBody,
                    placeholderText: 'Write a message',
                  ),
                  mimeType: 'text/html',
                  encoding: 'utf8',
                  baseUrl: WebUri('about:blank'),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  javaScriptCanOpenWindowsAutomatically: false,
                  mediaPlaybackRequiresUserGesture: true,
                  useShouldOverrideUrlLoading: true,
                  useShouldInterceptRequest: true,
                  cacheEnabled: false,
                  clearCache: true,
                  incognito: true,
                  transparentBackground: false,
                  supportZoom: false,
                ),
                onWebViewCreated: (controller) {
                  _bodyWebController = controller;
                  controller.addJavaScriptHandler(
                    handlerName: 'nyamailComposeChanged',
                    callback: (_) {
                      _scheduleDraftSave();
                      return null;
                    },
                  );
                },
                onLoadStop: (controller, _) async {
                  if (!mounted) return;
                  setState(() => _bodyEditorReady = true);
                  await controller.evaluateJavascript(
                    source:
                        "document.getElementById('editor')?.addEventListener('input', "
                        "() => window.flutter_inappwebview.callHandler('nyamailComposeChanged'));",
                  );
                  unawaited(_focusBodyEditor());
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  final uri = Uri.tryParse(
                    action.request.url?.toString() ?? '',
                  );
                  if (uri != null && uri.scheme == 'about') {
                    return NavigationActionPolicy.ALLOW;
                  }
                  return NavigationActionPolicy.CANCEL;
                },
                shouldInterceptRequest: (controller, request) async {
                  final uri = Uri.tryParse(request.url.toString());
                  if (uri == null || !_isRemoteHttpUri(uri)) return null;
                  return WebResourceResponse(
                    contentType: 'text/plain',
                    contentEncoding: 'utf-8',
                    data: Uint8List.fromList(utf8.encode('')),
                    headers: const {},
                    statusCode: 204,
                    reasonPhrase: 'No Content',
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _focusBodyEditor() async {
    try {
      await _bodyWebController?.evaluateJavascript(
        source: 'window.nyamailFocusEditor && window.nyamailFocusEditor();',
      );
    } catch (_) {
      // Focusing is best-effort.
    }
  }

  Future<void> _execBodyEditorCommand(String command) async {
    await _evaluateBodyEditorCommand(command);
  }

  Future<void> _evaluateBodyEditorCommand(
    String command, [
    String value = '',
  ]) async {
    final controller = _bodyWebController;
    if (controller == null || !_bodyEditorReady) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.nyamailExecCommand && '
            'window.nyamailExecCommand(${jsonEncode(command)}, ${jsonEncode(value)});',
      );
      _scheduleDraftSave();
      await _focusBodyEditor();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _insertBodyLink() async {
    final controller = TextEditingController();
    try {
      final raw = await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Insert link'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (value) => Navigator.of(context).pop(value),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(controller.text),
                  child: const Text('Insert'),
                ),
              ],
            ),
      );
      final url = _normalizeComposerLink(raw);
      if (url == null) return;
      await _evaluateBodyEditorCommand('createLink', url);
    } finally {
      controller.dispose();
    }
  }

  void _scheduleDraftSave() {
    if (widget.onDraftChanged == null || _sending) return;
    _draftSaveTimer?.cancel();
    if (!_savingDraft) {
      setState(() {
        _savingDraft = true;
        _draftSaveFailed = false;
      });
    }
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_saveDraftNow());
    });
  }

  Future<void> _saveDraftNow() async {
    final onDraftChanged = widget.onDraftChanged;
    if (onDraftChanged == null) return;
    if (mounted && !_savingDraft) {
      setState(() {
        _savingDraft = true;
        _draftSaveFailed = false;
      });
    }
    try {
      final body = await _currentComposeContent();
      await onDraftChanged(
        MailDraft(
          accountId: _accountId,
          to: _to.text,
          cc: _cc.text,
          bcc: _bcc.text,
          subject: _subject.text,
          body: body.textBody,
          htmlBody: body.htmlBody,
          attachments: [
            for (final attachment in _attachments)
              MailDraftAttachment(
                filename: attachment.filename,
                contentType: attachment.contentType,
                bytes: attachment.bytes,
              ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = false;
          _draftEverSaved = true;
        });
      }
    } catch (_) {
      // Draft persistence is a local convenience and must not block sending.
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = true;
        });
      }
    }
  }

  String? get _draftStatusLabel {
    if (widget.onDraftChanged == null || _sending) return null;
    if (_savingDraft) return 'Saving draft...';
    if (_draftSaveFailed) return 'Draft not saved';
    if (_draftEverSaved) return 'Draft saved locally';
    return null;
  }

  int get _attachmentTotalBytes {
    return _attachments.fold<int>(
      0,
      (total, attachment) => total + attachment.bytes.length,
    );
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null) return;
      final selected = <OutgoingAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          setState(() => _error = 'Could not read ${file.name}.');
          return;
        }
        selected.add(
          OutgoingAttachment(
            filename: file.name,
            contentType: _contentTypeForFilename(file.name),
            bytes: bytes,
          ),
        );
      }
      final total =
          _attachmentTotalBytes +
          selected.fold<int>(
            0,
            (sum, attachment) => sum + attachment.bytes.length,
          );
      if (total > _maxOutgoingAttachmentBytes) {
        setState(
          () =>
              _error =
                  'Attachments must be ${_formatBytes(_maxOutgoingAttachmentBytes)} or less.',
        );
        return;
      }
      setState(() {
        _attachments.addAll(selected);
        _error = null;
      });
      _scheduleDraftSave();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _cancel() async {
    _draftSaveTimer?.cancel();
    await _saveDraftNow();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _send() async {
    final body = await _currentComposeContent();
    final hasRecipient =
        _to.text.trim().isNotEmpty ||
        _cc.text.trim().isNotEmpty ||
        _bcc.text.trim().isNotEmpty;
    if (!hasRecipient) {
      setState(() => _error = 'At least one recipient is required.');
      return;
    }
    if (!_hasSendableMailContent(
      subject: _subject.text,
      textBody: body.textBody,
      attachments: _attachments,
    )) {
      setState(() => _error = 'Add a subject, message, or attachment.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    _draftSaveTimer?.cancel();
    await _saveDraftNow();
    try {
      await widget.onSend(
        accountId: _accountId,
        to: _to.text.trim(),
        cc: _cc.text.trim(),
        bcc: _bcc.text.trim(),
        subject: _subject.text.trim(),
        textBody: body.textBody,
        htmlBody: body.htmlBody,
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sending = false;
        });
      }
    }
  }

  Future<_ReplyComposerResult> _currentComposeContent() async {
    if (!_supportsReplyRichEditor) {
      final text = _body.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
      );
    }
    final controller = _bodyWebController;
    if (controller == null || !_bodyEditorReady) {
      final text = _body.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
      );
    }
    final raw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.nyamailGetContent());',
    );
    final decoded = _decodeReplyEditorContent(raw);
    final text = _normalizeReplyText(decoded['text'] as String? ?? '');
    final html = _normalizeReplyHtml(decoded['html'] as String? ?? '', text);
    return _ReplyComposerResult(textBody: text, htmlBody: html);
  }
}

class _ReaderBody extends StatefulWidget {
  const _ReaderBody({
    required this.message,
    required this.mailboxContextLabel,
    required this.onSendReply,
    required this.onSendReplyAll,
    required this.onForward,
    required this.onSetRead,
    required this.onSetStarred,
    required this.onArchive,
    required this.onDelete,
    required this.onMoveToInbox,
    required this.onMoveToMailbox,
    required this.onDownloadAttachment,
    required this.renderSettings,
    required this.mobileFullScreen,
    this.onClose,
  });

  final MailMessage message;
  final String mailboxContextLabel;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
    List<OutgoingAttachment> attachments,
  })
  onSendReplyAll;
  final Future<void> Function(MailMessage message) onForward;
  final Future<void> Function(MailMessage message, bool read) onSetRead;
  final Future<void> Function(MailMessage message, bool starred) onSetStarred;
  final Future<void> Function(MailMessage message) onArchive;
  final Future<void> Function(MailMessage message) onDelete;
  final Future<void> Function(MailMessage message) onMoveToInbox;
  final Future<void> Function(MailMessage message, MailboxKind destination)
  onMoveToMailbox;
  final Future<void> Function(MailMessage message, MailAttachment attachment)
  onDownloadAttachment;
  final MailRenderSettings renderSettings;
  final bool mobileFullScreen;
  final VoidCallback? onClose;

  @override
  State<_ReaderBody> createState() => _ReaderBodyState();
}

class _ReaderBodyState extends State<_ReaderBody> {
  bool _sending = false;
  bool _acting = false;
  bool _loadRemoteImagesOnce = false;
  bool _loadExternalStylesAndFontsOnce = false;
  final _allowedRemoteImageIds = <String>{};
  MailAppearance? _appearanceOverride;
  MailHtmlRenderResult? _cachedRendered;
  String? _cachedRenderedHtmlBody;
  String? _cachedRenderedTextBody;
  MailHtmlRenderPolicy? _cachedRenderPolicy;
  String? _downloadingAttachment;
  String? _error;

  @override
  void didUpdateWidget(covariant _ReaderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _loadRemoteImagesOnce = false;
      _loadExternalStylesAndFontsOnce = false;
      _allowedRemoteImageIds.clear();
      _appearanceOverride = null;
      _clearRenderedCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final canReplyAll =
        message.to.isNotEmpty ||
        message.cc.isNotEmpty ||
        message.replyTo.isNotEmpty;
    final effectiveMailbox = message.effectiveMailbox;
    final canDelete = effectiveMailbox != MailboxKind.trash;
    final moveDestinations = standardMailboxKinds
        .where((kind) => kind != effectiveMailbox)
        .toList(growable: false);
    final hostIsDark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final effectiveAppearance =
        _appearanceOverride ?? widget.renderSettings.appearance;
    final renderPolicy = MailHtmlRenderPolicy(
      loadRemoteImages:
          widget.renderSettings.autoLoadRemoteImages || _loadRemoteImagesOnce,
      loadExternalStylesAndFonts:
          widget.renderSettings.autoLoadExternalStylesAndFonts ||
          _loadExternalStylesAndFontsOnce,
      allowedRemoteImageIds: Set.unmodifiable(_allowedRemoteImageIds),
      appearance: effectiveAppearance,
      hostIsDark: hostIsDark,
    );
    final rendered = _renderedFor(
      htmlBody: message.htmlBody,
      textBody: message.body.isEmpty ? message.preview : message.body,
      policy: renderPolicy,
    );
    final title = Text(
      mailMessageSubjectLabel(message.subject),
      style: Theme.of(context).textTheme.headlineSmall,
      maxLines: widget.mobileFullScreen ? 3 : 2,
      overflow: TextOverflow.ellipsis,
    );
    final actionButtons = <Widget>[
      if (_canMoveToInbox(effectiveMailbox))
        IconButton(
          tooltip: 'Move to Inbox',
          onPressed:
              _acting
                  ? null
                  : () => _runAction(widget.onMoveToInbox, closeAfter: true),
          icon: const Icon(Icons.move_to_inbox_outlined),
        )
      else
        IconButton(
          tooltip: 'Archive',
          onPressed:
              _acting
                  ? null
                  : () => _runAction(widget.onArchive, closeAfter: true),
          icon: const Icon(Icons.archive_outlined),
        ),
      PopupMenuButton<MailboxKind>(
        tooltip: 'Move to...',
        enabled: !_acting && moveDestinations.isNotEmpty,
        icon: const Icon(Icons.drive_file_move_outlined),
        onSelected:
            (destination) => _runAction(
              (message) => widget.onMoveToMailbox(message, destination),
              closeAfter: true,
            ),
        itemBuilder:
            (context) => [
              for (final kind in moveDestinations)
                PopupMenuItem(
                  value: kind,
                  child: Row(
                    children: [
                      Icon(_iconForMailbox(kind), size: 18),
                      const SizedBox(width: 10),
                      Text(_labelForMailbox(kind)),
                    ],
                  ),
                ),
            ],
      ),
      IconButton(
        tooltip: message.starred ? 'Unstar' : 'Star',
        onPressed:
            _acting
                ? null
                : () => _runAction(
                  (message) => widget.onSetStarred(message, !message.starred),
                ),
        icon: Icon(message.starred ? Icons.star : Icons.star_border),
      ),
      IconButton(
        tooltip: message.read ? 'Mark unread' : 'Mark read',
        onPressed:
            _acting
                ? null
                : () => _runAction(
                  (message) => widget.onSetRead(message, !message.read),
                ),
        icon: Icon(
          message.read
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_read_outlined,
        ),
      ),
      IconButton(
        tooltip: canDelete ? 'Delete' : 'Already in Trash',
        onPressed:
            _acting || !canDelete
                ? null
                : () => _runAction(widget.onDelete, closeAfter: true),
        icon: const Icon(Icons.delete_outline),
      ),
      IconButton(
        tooltip: 'Reply',
        onPressed: _sending ? null : _showReplyComposer,
        icon: const Icon(Icons.reply),
      ),
      if (canReplyAll)
        IconButton(
          tooltip: 'Reply all',
          onPressed: _sending ? null : () => _showReplyComposer(replyAll: true),
          icon: const Icon(Icons.reply_all),
        ),
      IconButton(
        tooltip: 'Forward',
        onPressed: _acting ? null : () => widget.onForward(widget.message),
        icon: const Icon(Icons.forward),
      ),
      PopupMenuButton<_MessageAppearanceAction>(
        tooltip:
            _appearanceOverride == null
                ? 'Message appearance: ${widget.renderSettings.appearance.label} setting'
                : 'Message appearance: ${_appearanceOverride!.label} for this message',
        icon: Icon(
          _iconForMailAppearance(effectiveAppearance),
          color:
              _appearanceOverride == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
        ),
        onSelected: _setMessageAppearance,
        itemBuilder:
            (context) => [
              PopupMenuItem(
                value: _MessageAppearanceAction.useSetting,
                child: Row(
                  children: [
                    const Icon(Icons.settings_suggest_outlined),
                    const SizedBox(width: 12),
                    Text(
                      'Use setting (${widget.renderSettings.appearance.label})',
                    ),
                  ],
                ),
              ),
              for (final appearance in MailAppearance.values)
                PopupMenuItem(
                  value: _messageAppearanceActionFor(appearance),
                  child: Row(
                    children: [
                      Icon(_iconForMailAppearance(appearance)),
                      const SizedBox(width: 12),
                      Text(appearance.label),
                    ],
                  ),
                ),
            ],
      ),
    ];
    final header =
        widget.mobileFullScreen
            ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.onClose != null)
                      IconButton(
                        tooltip: 'Back',
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.arrow_back),
                      ),
                    Expanded(child: title),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: actionButtons),
                  ),
                ),
              ],
            )
            : LayoutBuilder(
              builder: (context, constraints) {
                final actions = SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actionButtons,
                  ),
                );
                if (constraints.maxWidth < 620) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: 4),
                      Align(alignment: Alignment.centerRight, child: actions),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: title),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: actions,
                      ),
                    ),
                  ],
                );
              },
            );
    return Padding(
      padding:
          widget.mobileFullScreen
              ? const EdgeInsets.fromLTRB(16, 12, 16, 0)
              : const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 8),
          for (final line in mailMessageDetailLines(message))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (widget.mailboxContextLabel.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'In ${widget.mailboxContextLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (rendered.summary.hasBlockedExternalNonImageResources ||
              rendered.summary.removedScripts > 0) ...[
            const SizedBox(height: 12),
            _MailResourceWarning(
              icon: Icons.shield_outlined,
              title: _externalResourceWarningTitle(rendered.summary),
              message: _externalResourceWarningMessage(rendered.summary),
              actionLabel:
                  rendered.summary.hasBlockedExternalNonImageResources
                      ? 'Allow once'
                      : null,
              onAction:
                  rendered.summary.hasBlockedExternalNonImageResources
                      ? () {
                        setState(() {
                          _loadExternalStylesAndFontsOnce = true;
                        });
                      }
                      : null,
            ),
          ],
          if (rendered.summary.hasBlockedImages &&
              !renderPolicy.loadRemoteImages) ...[
            const SizedBox(height: 8),
            _MailResourceWarning(
              icon: Icons.image_not_supported_outlined,
              title: _imageResourceWarningTitle(rendered.summary),
              message: 'Remote images are not loaded automatically.',
              actionLabel: 'Load images',
              onAction: () {
                setState(() => _loadRemoteImagesOnce = true);
              },
            ),
          ],
          const SizedBox(height: 24),
          Expanded(
            child: ListView(
              children: [
                if (!message.bodyLoaded) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Loading full message...',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                ],
                MailHtmlView(
                  rendered: rendered,
                  policy: renderPolicy,
                  onLoadRemoteImagesOnce: () {
                    setState(() => _loadRemoteImagesOnce = true);
                  },
                  onLoadRemoteImageOnce: (imageId) {
                    setState(() => _allowedRemoteImageIds.add(imageId));
                  },
                ),
                if (message.attachments.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Attachments',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final attachment in message.attachments) ...[
                    Builder(
                      builder: (context) {
                        final key = _attachmentKey(attachment);
                        final downloading = _downloadingAttachment == key;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.attach_file),
                          title: Text(
                            attachment.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_attachmentSubtitle(attachment)),
                          trailing: IconButton(
                            tooltip:
                                attachment.partId.isEmpty
                                    ? 'Attachment unavailable'
                                    : 'Download and open',
                            onPressed:
                                attachment.partId.isEmpty || downloading
                                    ? null
                                    : () => _downloadAttachment(attachment),
                            icon:
                                downloading
                                    ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(),
                                    )
                                    : const Icon(Icons.download_outlined),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  MailHtmlRenderResult _renderedFor({
    required String htmlBody,
    required String textBody,
    required MailHtmlRenderPolicy policy,
  }) {
    final cached = _cachedRendered;
    if (cached != null &&
        _cachedRenderedHtmlBody == htmlBody &&
        _cachedRenderedTextBody == textBody &&
        _sameRenderPolicy(_cachedRenderPolicy, policy)) {
      return cached;
    }
    final rendered = buildMailHtmlDocument(
      htmlBody: htmlBody,
      textBody: textBody,
      policy: policy,
    );
    _cachedRendered = rendered;
    _cachedRenderedHtmlBody = htmlBody;
    _cachedRenderedTextBody = textBody;
    _cachedRenderPolicy = policy;
    return rendered;
  }

  bool _sameRenderPolicy(
    MailHtmlRenderPolicy? previous,
    MailHtmlRenderPolicy next,
  ) {
    return previous != null &&
        previous.loadRemoteImages == next.loadRemoteImages &&
        previous.loadExternalStylesAndFonts ==
            next.loadExternalStylesAndFonts &&
        previous.appearance == next.appearance &&
        previous.hostIsDark == next.hostIsDark &&
        setEquals(previous.allowedRemoteImageIds, next.allowedRemoteImageIds);
  }

  void _clearRenderedCache() {
    _cachedRendered = null;
    _cachedRenderedHtmlBody = null;
    _cachedRenderedTextBody = null;
    _cachedRenderPolicy = null;
  }

  void _setMessageAppearance(_MessageAppearanceAction action) {
    setState(() {
      _appearanceOverride = switch (action) {
        _MessageAppearanceAction.useSetting => null,
        _MessageAppearanceAction.automatic => MailAppearance.automatic,
        _MessageAppearanceAction.light => MailAppearance.light,
        _MessageAppearanceAction.dark => MailAppearance.dark,
      };
    });
  }

  Future<void> _showReplyComposer({bool replyAll = false}) async {
    final result = await _openReplyComposer(replyAll ? 'Reply all' : 'Reply');
    if (result == null || result.textBody.trim().isEmpty) return;
    await _sendReplyContent(result, replyAll: replyAll);
  }

  Future<_ReplyComposerResult?> _openReplyComposer(String title) {
    if (widget.mobileFullScreen) {
      return Navigator.of(context).push<_ReplyComposerResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder:
              (context) => Scaffold(
                body: SafeArea(
                  child: _ReplyComposerSurface(title: title, fullScreen: true),
                ),
              ),
        ),
      );
    }
    return showDialog<_ReplyComposerResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final availableWidth = size.width - 96;
        final availableHeight = size.height - 96;
        final width =
            availableWidth > 0 && availableWidth < 720 ? availableWidth : 720.0;
        final height =
            availableHeight > 0 && availableHeight < 560
                ? availableHeight
                : 560.0;
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: width,
            height: height,
            child: _ReplyComposerSurface(title: title, fullScreen: false),
          ),
        );
      },
    );
  }

  Future<void> _sendReplyContent(
    _ReplyComposerResult result, {
    bool replyAll = false,
  }) async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (replyAll) {
        await widget.onSendReplyAll(
          widget.message,
          result.textBody,
          htmlBody: result.htmlBody,
          attachments: result.attachments,
        );
      } else {
        await widget.onSendReply(
          widget.message,
          result.textBody,
          htmlBody: result.htmlBody,
          attachments: result.attachments,
        );
      }
      if (mounted) setState(() => _sending = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sending = false;
        });
      }
    }
  }

  Future<void> _runAction(
    Future<void> Function(MailMessage message) action, {
    bool closeAfter = false,
  }) async {
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action(widget.message);
      if (!mounted) return;
      setState(() => _acting = false);
      if (closeAfter && widget.mobileFullScreen) {
        widget.onClose?.call();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _acting = false;
        });
      }
    }
  }

  Future<void> _downloadAttachment(MailAttachment attachment) async {
    final key = _attachmentKey(attachment);
    setState(() {
      _downloadingAttachment = key;
      _error = null;
    });
    try {
      await widget.onDownloadAttachment(widget.message, attachment);
      if (mounted) setState(() => _downloadingAttachment = null);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _downloadingAttachment = null;
        });
      }
    }
  }
}

class _MailResourceWarning extends StatelessWidget {
  const _MailResourceWarning({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 10),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _ReplyComposerResult {
  const _ReplyComposerResult({
    required this.textBody,
    required this.htmlBody,
    this.attachments = const [],
  });

  final String textBody;
  final String htmlBody;
  final List<OutgoingAttachment> attachments;
}

class _ReplyComposerSurface extends StatefulWidget {
  const _ReplyComposerSurface({required this.title, required this.fullScreen});

  final String title;
  final bool fullScreen;

  @override
  State<_ReplyComposerSurface> createState() => _ReplyComposerSurfaceState();
}

class _ReplyComposerSurfaceState extends State<_ReplyComposerSurface> {
  final _plainText = TextEditingController();
  final _attachments = <OutgoingAttachment>[];
  InAppWebViewController? _webController;
  bool _editorReady = false;
  bool _finishing = false;
  String? _error;

  @override
  void dispose() {
    _plainText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (widget.fullScreen)
              IconButton(
                tooltip: 'Back',
                onPressed: _finishing ? null : _requestClose,
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: _finishing ? null : _requestClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_supportsReplyRichEditor) ...[
          _ReplyComposerToolbar(
            enabled: _editorReady && !_finishing,
            onCommand: _execEditorCommand,
            onInsertLink: _insertLink,
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child:
              _supportsReplyRichEditor
                  ? _richEditor(context)
                  : TextField(
                    controller: _plainText,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Write a reply',
                      border: OutlineInputBorder(),
                    ),
                  ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _finishing ? null : _pickAttachments,
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _attachments.isEmpty
                    ? 'No attachments'
                    : '${_attachments.length} attached - '
                        '${_formatBytes(_attachmentTotalBytes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (_attachments.isNotEmpty) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 108),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _attachments.length,
              itemBuilder: (context, index) {
                final attachment = _attachments[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    attachment.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_outgoingAttachmentSubtitle(attachment)),
                  trailing: IconButton(
                    tooltip: 'Remove attachment',
                    onPressed:
                        _finishing
                            ? null
                            : () {
                              setState(() => _attachments.removeAt(index));
                            },
                    icon: const Icon(Icons.close),
                  ),
                );
              },
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _finishing ? null : _requestClose,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _finishing ? null : _finish,
              icon:
                  _finishing
                      ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.send),
              label: const Text('Send'),
            ),
          ],
        ),
      ],
    );
    return Padding(
      padding:
          widget.fullScreen
              ? const EdgeInsets.fromLTRB(12, 8, 12, 12)
              : const EdgeInsets.all(20),
      child: content,
    );
  }

  Widget _richEditor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = colorScheme.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: _replyEditorHtml(dark: dark),
            mimeType: 'text/html',
            encoding: 'utf8',
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: false,
            mediaPlaybackRequiresUserGesture: true,
            useShouldOverrideUrlLoading: true,
            useShouldInterceptRequest: true,
            cacheEnabled: false,
            clearCache: true,
            incognito: true,
            transparentBackground: false,
            supportZoom: false,
          ),
          onWebViewCreated: (controller) => _webController = controller,
          onLoadStop: (controller, _) {
            if (!mounted) return;
            setState(() => _editorReady = true);
            unawaited(_focusEditor());
          },
          shouldOverrideUrlLoading: (controller, action) async {
            final uri = Uri.tryParse(action.request.url?.toString() ?? '');
            if (uri != null && uri.scheme == 'about') {
              return NavigationActionPolicy.ALLOW;
            }
            return NavigationActionPolicy.CANCEL;
          },
          shouldInterceptRequest: (controller, request) async {
            final uri = Uri.tryParse(request.url.toString());
            if (uri == null || !_isRemoteHttpUri(uri)) return null;
            return WebResourceResponse(
              contentType: 'text/plain',
              contentEncoding: 'utf-8',
              data: Uint8List.fromList(utf8.encode('')),
              headers: const {},
              statusCode: 204,
              reasonPhrase: 'No Content',
            );
          },
        ),
      ),
    );
  }

  Future<void> _focusEditor() async {
    try {
      await _webController?.evaluateJavascript(
        source: 'window.nyamailFocusEditor && window.nyamailFocusEditor();',
      );
    } catch (_) {
      // Focusing is best-effort; the user can still tap into the editor.
    }
  }

  Future<void> _execEditorCommand(String command) async {
    await _evaluateEditorCommand(command);
  }

  Future<void> _evaluateEditorCommand(
    String command, [
    String value = '',
  ]) async {
    final controller = _webController;
    if (controller == null || !_editorReady) return;
    try {
      await controller.evaluateJavascript(
        source:
            'window.nyamailExecCommand && '
            'window.nyamailExecCommand(${jsonEncode(command)}, ${jsonEncode(value)});',
      );
      await _focusEditor();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _insertLink() async {
    final controller = TextEditingController();
    try {
      final raw = await showDialog<String>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Insert link'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'https://example.com',
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (value) => Navigator.of(context).pop(value),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(controller.text),
                  child: const Text('Insert'),
                ),
              ],
            ),
      );
      final url = _normalizeComposerLink(raw);
      if (url == null) return;
      await _evaluateEditorCommand('createLink', url);
    } finally {
      controller.dispose();
    }
  }

  int get _attachmentTotalBytes {
    return _attachments.fold<int>(
      0,
      (total, attachment) => total + attachment.bytes.length,
    );
  }

  Future<void> _pickAttachments() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (result == null) return;
      final selected = <OutgoingAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null) {
          setState(() => _error = 'Could not read ${file.name}.');
          return;
        }
        selected.add(
          OutgoingAttachment(
            filename: file.name,
            contentType: _contentTypeForFilename(file.name),
            bytes: bytes,
          ),
        );
      }
      final total =
          _attachmentTotalBytes +
          selected.fold<int>(
            0,
            (sum, attachment) => sum + attachment.bytes.length,
          );
      if (total > _maxOutgoingAttachmentBytes) {
        setState(
          () =>
              _error =
                  'Attachments must be ${_formatBytes(_maxOutgoingAttachmentBytes)} or less.',
        );
        return;
      }
      setState(() {
        _attachments.addAll(selected);
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _finish() async {
    setState(() {
      _finishing = true;
      _error = null;
    });
    try {
      final result = await _currentContent();
      if (!_hasSendableMailContent(
        textBody: result.textBody,
        attachments: result.attachments,
      )) {
        if (mounted) {
          setState(() {
            _error = 'Add a message or attachment.';
            _finishing = false;
          });
        }
        return;
      }
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _finishing = false;
        });
      }
    }
  }

  Future<void> _requestClose() async {
    try {
      final result = await _currentContent();
      final hasDraft = _hasSendableMailContent(
        textBody: result.textBody,
        attachments: result.attachments,
      );
      if (!hasDraft) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      if (!mounted) return;
      final discard =
          await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: const Text('Discard reply?'),
                  content: const Text(
                    'This reply has unsent content or attachments.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Keep editing'),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Discard'),
                    ),
                  ],
                ),
          ) ??
          false;
      if (discard && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<_ReplyComposerResult> _currentContent() async {
    if (!_supportsReplyRichEditor) {
      final text = _plainText.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
    }
    final controller = _webController;
    if (controller == null || !_editorReady) {
      return _ReplyComposerResult(
        textBody: '',
        htmlBody: '',
        attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
      );
    }
    final raw = await controller.evaluateJavascript(
      source: 'JSON.stringify(window.nyamailGetContent());',
    );
    final decoded = _decodeReplyEditorContent(raw);
    final text = _normalizeReplyText(decoded['text'] as String? ?? '');
    final html = _normalizeReplyHtml(decoded['html'] as String? ?? '', text);
    return _ReplyComposerResult(
      textBody: text,
      htmlBody: html,
      attachments: List<OutgoingAttachment>.unmodifiable(_attachments),
    );
  }
}

class _ReplyComposerToolbar extends StatelessWidget {
  const _ReplyComposerToolbar({
    required this.enabled,
    required this.onCommand,
    required this.onInsertLink,
  });

  final bool enabled;
  final ValueChanged<String> onCommand;
  final VoidCallback onInsertLink;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _button(
            icon: Icons.format_bold,
            tooltip: 'Bold',
            onPressed: () => onCommand('bold'),
          ),
          _button(
            icon: Icons.format_italic,
            tooltip: 'Italic',
            onPressed: () => onCommand('italic'),
          ),
          _button(
            icon: Icons.format_underlined,
            tooltip: 'Underline',
            onPressed: () => onCommand('underline'),
          ),
          const SizedBox(width: 6),
          _button(
            icon: Icons.format_list_bulleted,
            tooltip: 'Bulleted list',
            onPressed: () => onCommand('insertUnorderedList'),
          ),
          _button(
            icon: Icons.format_list_numbered,
            tooltip: 'Numbered list',
            onPressed: () => onCommand('insertOrderedList'),
          ),
          const SizedBox(width: 6),
          _button(
            icon: Icons.link,
            tooltip: 'Insert link',
            onPressed: onInsertLink,
          ),
          _button(
            icon: Icons.format_clear,
            tooltip: 'Clear formatting',
            onPressed: () => onCommand('removeFormat'),
          ),
        ],
      ),
    );
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      visualDensity: VisualDensity.compact,
    );
  }
}

bool get _supportsReplyRichEditor {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.fuchsia || TargetPlatform.linux => false,
  };
}

String _replyEditorHtml({
  required bool dark,
  String initialText = '',
  String initialHtml = '',
  String placeholderText = 'Write a reply',
}) {
  final background = dark ? '#111315' : '#FFFFFF';
  final text = dark ? '#E8EAED' : '#202124';
  final caret = dark ? '#8AB4F8' : '#0B57D0';
  final placeholder = dark ? '#9AA0A6' : '#5F6368';
  final editorInitialHtml =
      initialHtml.trim().isNotEmpty
          ? initialHtml
          : initialText.trim().isEmpty
          ? ''
          : _plainTextToOutgoingHtml(initialText);
  final initialHtmlBase64Json = jsonEncode(
    base64Encode(utf8.encode(editorInitialHtml)),
  );
  final placeholderJson = jsonEncode(placeholderText);
  return '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  color-scheme: ${dark ? 'dark' : 'light'};
  background: $background;
  font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
html, body {
  min-height: 100%;
  margin: 0;
  background: $background;
  color: $text;
}
#editor {
  min-height: 100vh;
  box-sizing: border-box;
  padding: 14px;
  outline: none;
  caret-color: $caret;
  overflow-wrap: anywhere;
  font-size: 15px;
  line-height: 1.55;
}
#editor:empty::before {
  content: $placeholderJson;
  color: $placeholder;
}
a { color: $caret; }
blockquote {
  margin: 8px 0;
  padding-left: 12px;
  border-left: 3px solid $placeholder;
}
</style>
</head>
<body>
<div id="editor" contenteditable="true" role="textbox" aria-multiline="true"></div>
<script>
(function () {
  const editor = document.getElementById('editor');
  function decodeInitialHtml(value) {
    try {
      const bytes = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
      return new TextDecoder('utf-8').decode(bytes);
    } catch (_) {
      return '';
    }
  }
  editor.innerHTML = decodeInitialHtml($initialHtmlBase64Json);
  function safeHref(value) {
    const normalized = String(value || '').trim().toLowerCase();
    return normalized.startsWith('http://') ||
      normalized.startsWith('https://') ||
      normalized.startsWith('mailto:') ||
      normalized.startsWith('tel:');
  }
  function sanitize() {
    editor.querySelectorAll('script, style, link, iframe, object, embed, meta, base, form, input, button, textarea, select, img').forEach((node) => node.remove());
    editor.querySelectorAll('*').forEach((node) => {
      Array.from(node.attributes).forEach((attribute) => {
        const name = attribute.name.toLowerCase();
        if (name.startsWith('on') || name === 'style' || name === 'src' || name === 'srcset') {
          node.removeAttribute(attribute.name);
        }
        if (name === 'href' && !safeHref(attribute.value)) {
          node.removeAttribute(attribute.name);
        }
      });
      if (node.tagName === 'A') {
        node.setAttribute('rel', 'noopener noreferrer');
      }
    });
  }
  sanitize();
  editor.addEventListener('paste', () => window.setTimeout(sanitize, 0));
  window.nyamailFocusEditor = function () {
    editor.focus();
  };
  window.nyamailExecCommand = function (command, value) {
    editor.focus();
    document.execCommand(command, false, value || null);
    sanitize();
  };
  window.nyamailGetContent = function () {
    sanitize();
    return {
      html: editor.innerHTML || '',
      text: editor.innerText || ''
    };
  };
  editor.focus();
})();
</script>
</body>
</html>
''';
}

Map<String, Object?> _decodeReplyEditorContent(Object? raw) {
  if (raw is Map) return raw.cast<String, Object?>();
  var value = raw?.toString() ?? '{}';
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, Object?>();
      if (decoded is String) {
        value = decoded;
        continue;
      }
    } catch (_) {
      break;
    }
  }
  return const {};
}

String _normalizeReplyText(String value) {
  return value.replaceAll('\u00a0', ' ').trim();
}

String _normalizeReplyHtml(String html, String text) {
  final normalized = html.trim();
  if (text.trim().isEmpty) return '';
  if (normalized.isEmpty || normalized == '<br>') {
    return _plainTextToOutgoingHtml(text);
  }
  return '<div>$normalized</div>';
}

String _plainTextToOutgoingHtml(String text) {
  final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(text.trim());
  return '<div>${escaped.replaceAll('\n', '<br>')}</div>';
}

bool _hasSendableMailContent({
  String subject = '',
  String textBody = '',
  List<OutgoingAttachment> attachments = const [],
}) {
  return subject.trim().isNotEmpty ||
      textBody.trim().isNotEmpty ||
      attachments.isNotEmpty;
}

String? _normalizeComposerLink(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final withScheme =
      RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(value)
          ? value
          : value.contains('@') && !value.contains('/')
          ? 'mailto:$value'
          : 'https://$value';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'mailto' ||
      scheme == 'tel') {
    return uri.toString();
  }
  return null;
}

bool _isRemoteHttpUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

String _externalResourceWarningTitle(MailHtmlResourceSummary summary) {
  final count = summary.blockedExternalNonImageResources;
  if (count <= 0) return 'Active content removed';
  return count == 1
      ? '1 external style or font blocked'
      : '$count external styles or fonts blocked';
}

String _externalResourceWarningMessage(MailHtmlResourceSummary summary) {
  final parts = <String>[];
  if (summary.blockedExternalStyles > 0) {
    parts.add('${summary.blockedExternalStyles} CSS');
  }
  if (summary.blockedExternalFonts > 0) {
    parts.add('${summary.blockedExternalFonts} font');
  }
  if (summary.blockedCssResources > 0) {
    parts.add('${summary.blockedCssResources} CSS URL');
  }
  if (summary.removedScripts > 0) {
    parts.add('${summary.removedScripts} script');
  }
  if (parts.isEmpty) return 'Scripts are always blocked.';
  return '${parts.join(', ')} removed or blocked for this message.';
}

String _imageResourceWarningTitle(MailHtmlResourceSummary summary) {
  final total = summary.blockedRemoteImages + summary.blockedInlineImages;
  if (total == 1) return '1 image blocked';
  return '$total images blocked';
}

class _MobileInbox extends StatelessWidget {
  const _MobileInbox({
    required this.messages,
    required this.selected,
    required this.search,
    required this.searchFocusNode,
    required this.accounts,
    required this.view,
    required this.onSearch,
    required this.onAddMailbox,
    required this.onRefresh,
    required this.onSelect,
    required this.canLoadMore,
    required this.loadingMore,
    required this.refreshing,
    required this.onLoadMore,
    required this.interactionSettings,
    required this.pinnedMessageIds,
    required this.selectedMessageIds,
    required this.keyboardNavigationMessageId,
    required this.keyboardNavigationDirection,
    required this.onMessageAction,
    required this.onBatchAction,
    required this.onMoveSelectedToMailbox,
    required this.onMessageSelected,
    required this.onClearSelection,
    required this.onSelectAll,
    required this.supportsMobileSwipe,
    required this.supportsDesktopContextMenu,
  });

  final List<MailMessage> messages;
  final MailMessage? selected;
  final TextEditingController search;
  final FocusNode searchFocusNode;
  final List<MailAccount> accounts;
  final MailboxView view;
  final VoidCallback onSearch;
  final VoidCallback onAddMailbox;
  final VoidCallback? onRefresh;
  final ValueChanged<MailMessage> onSelect;
  final bool canLoadMore;
  final bool loadingMore;
  final bool refreshing;
  final VoidCallback onLoadMore;
  final MailInteractionSettings interactionSettings;
  final Set<String> pinnedMessageIds;
  final Set<String> selectedMessageIds;
  final String? keyboardNavigationMessageId;
  final int keyboardNavigationDirection;
  final Future<void> Function(
    MailMessage message,
    MailListActionPreference action,
  )
  onMessageAction;
  final Future<void> Function(MailListActionPreference action) onBatchAction;
  final Future<void> Function(MailboxKind destination) onMoveSelectedToMailbox;
  final void Function(String messageId, bool selected) onMessageSelected;
  final VoidCallback onClearSelection;
  final VoidCallback onSelectAll;
  final bool supportsMobileSwipe;
  final bool supportsDesktopContextMenu;

  @override
  Widget build(BuildContext context) {
    return _MessageList(
      key: ValueKey('mobile-${view.key}-${search.text}'),
      messages: messages,
      selected: selected,
      search: search,
      searchFocusNode: searchFocusNode,
      accounts: accounts,
      interactionSettings: interactionSettings,
      pinnedMessageIds: pinnedMessageIds,
      selectedMessageIds: selectedMessageIds,
      keyboardNavigationMessageId: keyboardNavigationMessageId,
      keyboardNavigationDirection: keyboardNavigationDirection,
      onSearch: onSearch,
      onAddMailbox: onAddMailbox,
      onRefresh: onRefresh,
      onSelect: onSelect,
      onMessageAction: onMessageAction,
      onBatchAction: onBatchAction,
      onMoveSelectedToMailbox: onMoveSelectedToMailbox,
      onMessageSelected: onMessageSelected,
      onClearSelection: onClearSelection,
      onSelectAll: onSelectAll,
      canLoadMore: canLoadMore,
      loadingMore: loadingMore,
      refreshing: refreshing,
      onLoadMore: onLoadMore,
      supportsMobileSwipe: supportsMobileSwipe,
      supportsDesktopContextMenu: supportsDesktopContextMenu,
    );
  }
}

class _DevicesDialog extends StatefulWidget {
  const _DevicesDialog({
    required this.api,
    required this.token,
    required this.userId,
    required this.currentDevice,
    required this.secureStore,
    required this.vaultSecret,
  });

  final NyaMailApi api;
  final String token;
  final String userId;
  final DeviceSummary currentDevice;
  final LocalSecureStore secureStore;
  final String vaultSecret;

  @override
  State<_DevicesDialog> createState() => _DevicesDialogState();
}

class _DevicesDialogState extends State<_DevicesDialog> {
  late Future<List<DeviceSummary>> _devices = widget.api.listDevices(
    widget.token,
  );
  static const _pairingCode = DevicePairingCode();
  bool _sharing = false;
  String? _revokingDeviceId;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Devices'),
      content: _DialogContent(
        width: 520,
        child: FutureBuilder<List<DeviceSummary>>(
          future: _devices,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text(snapshot.error.toString());
            }
            final devices = snapshot.data ?? const [];
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (_canScanPairingQr)
                        TextButton.icon(
                          onPressed:
                              _sharing ? null : () => _shareFromQr(devices),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan pairing QR'),
                        ),
                      TextButton.icon(
                        onPressed:
                            _sharing
                                ? null
                                : () => _shareFromClipboard(devices),
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste pairing package'),
                      ),
                    ],
                  ),
                ),
                for (final device in devices)
                  ListTile(
                    leading: Icon(
                      device.trusted
                          ? Icons.verified_user_outlined
                          : Icons.pending_outlined,
                    ),
                    title: Text(device.name),
                    subtitle: Text(
                      device.trusted || device.revoked
                          ? '${device.platform} - ${device.id}'
                          : '${device.platform} - ${device.id}\nPair ${_pairingCode.codeFor(userId: widget.userId, device: device)}',
                    ),
                    isThreeLine: !(device.trusted || device.revoked),
                    trailing:
                        device.id == widget.currentDevice.id
                            ? const Text('This device')
                            : device.revoked
                            ? null
                            : device.trusted
                            ? IconButton(
                              tooltip: 'Revoke device',
                              onPressed:
                                  _busy ? null : () => _revokeDevice(device),
                              icon:
                                  _revokingDeviceId == device.id
                                      ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(),
                                      )
                                      : const Icon(Icons.block_outlined),
                            )
                            : IconButton(
                              tooltip: 'Share vault',
                              onPressed: _busy ? null : () => _shareTo(device),
                              icon: const Icon(Icons.lock_open_outlined),
                            ),
                  ),
                if (_error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  bool get _busy => _sharing || _revokingDeviceId != null;

  bool get _canScanPairingQr {
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  void _reloadDevices() {
    setState(() {
      _devices = widget.api.listDevices(widget.token);
    });
  }

  Future<void> _shareFromClipboard(List<DeviceSummary> devices) async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      await _shareFromPairingPackage(devices, data?.text ?? '');
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _shareFromQr(List<DeviceSummary> devices) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _PairingQrScannerDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    await _shareFromPairingPackage(devices, text);
  }

  Future<void> _shareFromPairingPackage(
    List<DeviceSummary> devices,
    String text,
  ) async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final request = DevicePairingRequest.decode(text);
      if (request.userId != widget.userId) {
        throw const DevicePairingRequestException(
          'pairing package is for a different user',
        );
      }
      final device =
          devices.where((item) => item.id == request.device.id).firstOrNull;
      if (device == null) {
        throw const DevicePairingRequestException(
          'pairing device is not waiting for approval',
        );
      }
      _assertPairingRequestMatchesDevice(request, device);
      await _shareTo(device, expectedPairingCode: request.pairingCode);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sharing = false;
        });
      }
    }
  }

  Future<void> _revokeDevice(DeviceSummary device) async {
    if (device.id == widget.currentDevice.id) {
      setState(() => _error = 'This device cannot revoke itself.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Revoke ${device.name}?'),
            content: const Text(
              'This device will lose access to NyaMail sync until it signs in again and is approved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.block_outlined),
                label: const Text('Revoke'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    setState(() {
      _revokingDeviceId = device.id;
      _error = null;
    });
    try {
      await widget.api.revokeDevice(token: widget.token, deviceId: device.id);
      _reloadDevices();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _revokingDeviceId = null);
      }
    }
  }

  void _assertPairingRequestMatchesDevice(
    DevicePairingRequest request,
    DeviceSummary device,
  ) {
    if (device.trusted || device.revoked) {
      throw const DevicePairingRequestException(
        'pairing device is not pending approval',
      );
    }
    if (request.device.publicKey != device.publicKey ||
        request.device.keyAgreementPublicKey != device.keyAgreementPublicKey) {
      throw const DevicePairingRequestException(
        'pairing package keys do not match the pending device',
      );
    }
    final expected = _pairingCode.codeFor(
      userId: widget.userId,
      device: device,
    );
    if (request.pairingCode != expected) {
      throw const DevicePairingRequestException(
        'pairing code does not match the pending device',
      );
    }
  }

  Future<void> _shareTo(
    DeviceSummary device, {
    String? expectedPairingCode,
  }) async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final pairingCode = _pairingCode.codeFor(
        userId: widget.userId,
        device: device,
      );
      if (expectedPairingCode != null && expectedPairingCode != pairingCode) {
        throw const DevicePairingRequestException(
          'pairing package does not match selected device',
        );
      }
      final confirmed = await _confirmPairingCode(device, pairingCode);
      if (!confirmed) {
        if (mounted) {
          setState(() => _sharing = false);
        }
        return;
      }
      final vaultSecret = widget.vaultSecret;
      if (vaultSecret.isEmpty) {
        throw StateError('This device has no transferable vault secret yet.');
      }
      if (device.keyAgreementPublicKey.isEmpty) {
        throw StateError('Target device has no encryption public key.');
      }
      final payload = await const VaultShareCrypto().encryptForDevice(
        recipientPublicKey: device.keyAgreementPublicKey,
        plaintext: vaultSecret,
      );
      final signingKey = await widget.secureStore.readOrCreateDeviceKeyPair();
      final approvalSignature = await const DeviceApprovalCrypto()
          .signVaultShareApproval(
            userId: widget.userId,
            fromDevice: widget.currentDevice,
            toDevice: device,
            share: payload,
            pairingCode: pairingCode,
            privateKey: signingKey.privateKey,
          );
      await widget.api.putVaultShare(
        token: widget.token,
        deviceId: device.id,
        senderPublicKey: payload.senderPublicKey,
        algorithm: payload.algorithm,
        nonce: payload.nonce,
        ciphertext: payload.ciphertext,
        mac: payload.mac,
        pairingCode: pairingCode,
        approvalSignature: approvalSignature,
      );
      if (mounted) {
        Navigator.of(context).pop('Vault access shared with ${device.name}.');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _sharing = false;
        });
      }
    }
  }

  Future<bool> _confirmPairingCode(
    DeviceSummary device,
    String pairingCode,
  ) async {
    final controller = TextEditingController();
    try {
      final result = await showDialog<bool>(
        context: context,
        builder:
            (context) => AlertDialog(
              title: Text('Share with ${device.name}'),
              content: _DialogContent(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      pairingCode,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Pairing code',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () {
                    final entered = _pairingCode.normalize(controller.text);
                    Navigator.of(context).pop(entered == pairingCode);
                  },
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Share'),
                ),
              ],
            ),
      );
      if (result == false && mounted) {
        setState(() => _error = 'Pairing code did not match.');
      }
      return result ?? false;
    } finally {
      controller.dispose();
    }
  }
}

class _PairingQrDialog extends StatelessWidget {
  const _PairingQrDialog({required this.pairingPackage});

  final String pairingPackage;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pair this device'),
      content: _DialogContent(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: pairingPackage,
                version: QrVersions.auto,
                size: 260,
                gapless: false,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: 'NyaMail device pairing package',
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              pairingPackage,
              maxLines: 3,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: pairingPackage));
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          icon: const Icon(Icons.content_copy),
          label: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _RecoveryCodesDialog extends StatelessWidget {
  const _RecoveryCodesDialog({required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final joinedCodes = codes.join('\n');
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Recovery codes'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Save these one-time codes now. They can approve a new device if you lose access to an existing one.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: SelectableText(
                joinedCodes,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: joinedCodes));
          },
          icon: const Icon(Icons.content_copy),
          label: const Text('Copy all'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I saved them'),
        ),
      ],
    );
  }
}

class _PairingQrScannerDialog extends StatefulWidget {
  const _PairingQrScannerDialog();

  @override
  State<_PairingQrScannerDialog> createState() =>
      _PairingQrScannerDialogState();
}

class _PairingQrScannerDialogState extends State<_PairingQrScannerDialog> {
  late final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Scan pairing QR'),
      content: _DialogContent(
        width: 420,
        maxHeight: 460,
        child: SizedBox(
          height: 460,
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: MobileScanner(
                    controller: _controller,
                    onDetect: _handleDetection,
                    errorBuilder: (context, error) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            error.errorDetails?.message ?? error.toString(),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Toggle torch',
          onPressed: () => _controller.toggleTorch(),
          icon: const Icon(Icons.flashlight_on_outlined),
        ),
        IconButton(
          tooltip: 'Switch camera',
          onPressed: () => _controller.switchCamera(),
          icon: const Icon(Icons.cameraswitch_outlined),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_handled) return;
    final value =
        capture.barcodes
            .where((barcode) => barcode.rawValue?.trim().isNotEmpty ?? false)
            .map((barcode) => barcode.rawValue!.trim())
            .firstOrNull;
    if (value == null) return;
    try {
      DevicePairingRequest.decode(value);
      _handled = true;
      Navigator.of(context).pop(value);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }
}

class _LocalVaultCreationInput {
  const _LocalVaultCreationInput({
    required this.displayName,
    required this.password,
    required this.enableQuickUnlock,
  });

  final String displayName;
  final String password;
  final bool enableQuickUnlock;
}

class _LocalVaultCreationDialog extends StatefulWidget {
  const _LocalVaultCreationDialog({
    required this.quickUnlockAvailable,
    required this.quickUnlockMethod,
  });

  final bool quickUnlockAvailable;
  final String quickUnlockMethod;

  @override
  State<_LocalVaultCreationDialog> createState() =>
      _LocalVaultCreationDialogState();
}

class _LocalVaultCreationDialogState extends State<_LocalVaultCreationDialog> {
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _enableQuickUnlock = true;
  String? _error;

  @override
  void dispose() {
    _displayName.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create local vault'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _displayName,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Vault name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Vault password'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmPassword,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: widget.quickUnlockAvailable && _enableQuickUnlock,
              onChanged:
                  widget.quickUnlockAvailable
                      ? (value) =>
                          setState(() => _enableQuickUnlock = value ?? false)
                      : null,
              title: const Text('Enable system quick unlock'),
              subtitle: Text(widget.quickUnlockMethod),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }

  void _submit() {
    final password = _password.text;
    if (password.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (password != _confirmPassword.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.of(context).pop(
      _LocalVaultCreationInput(
        displayName: _displayName.text.trim(),
        password: password,
        enableQuickUnlock: widget.quickUnlockAvailable && _enableQuickUnlock,
      ),
    );
  }
}

class _LocalVaultUnlockInput {
  const _LocalVaultUnlockInput.password(this.password) : useQuickUnlock = false;

  const _LocalVaultUnlockInput.quickUnlock()
    : password = null,
      useQuickUnlock = true;

  final String? password;
  final bool useQuickUnlock;
}

class _LocalVaultUnlockDialog extends StatefulWidget {
  const _LocalVaultUnlockDialog({
    required this.profile,
    required this.quickUnlockAvailable,
    required this.quickUnlockMethod,
  });

  final LocalProfile profile;
  final bool quickUnlockAvailable;
  final String quickUnlockMethod;

  @override
  State<_LocalVaultUnlockDialog> createState() =>
      _LocalVaultUnlockDialogState();
}

class _LocalVaultUnlockDialogState extends State<_LocalVaultUnlockDialog> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Unlock ${widget.profile.label}'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.quickUnlockAvailable) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed:
                      () => Navigator.of(
                        context,
                      ).pop(const _LocalVaultUnlockInput.quickUnlock()),
                  icon: const Icon(Icons.fingerprint),
                  label: Text(widget.quickUnlockMethod),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _password,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Vault password'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }

  void _submit() {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the vault password.');
      return;
    }
    Navigator.of(context).pop(_LocalVaultUnlockInput.password(_password.text));
  }
}

class _VaultPasswordInput {
  const _VaultPasswordInput(this.password);

  final String password;
}

class _VaultPasswordDialog extends StatefulWidget {
  const _VaultPasswordDialog({
    required this.title,
    required this.message,
    required this.confirmPassword,
    this.passwordLabel = 'Vault password',
    this.actionLabel = 'Continue',
  });

  final String title;
  final String message;
  final bool confirmPassword;
  final String passwordLabel;
  final String actionLabel;

  @override
  State<_VaultPasswordDialog> createState() => _VaultPasswordDialogState();
}

class _VaultPasswordDialogState extends State<_VaultPasswordDialog> {
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: Alignment.centerLeft, child: Text(widget.message)),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              textInputAction:
                  widget.confirmPassword
                      ? TextInputAction.next
                      : TextInputAction.done,
              onSubmitted: (_) {
                if (!widget.confirmPassword) _submit();
              },
              decoration: InputDecoration(labelText: widget.passwordLabel),
            ),
            if (widget.confirmPassword) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _confirmPassword,
                obscureText: true,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }

  void _submit() {
    final password = _password.text;
    if (password.length < 12) {
      setState(() => _error = 'Use at least 12 characters.');
      return;
    }
    if (widget.confirmPassword && password != _confirmPassword.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.of(context).pop(_VaultPasswordInput(password));
  }
}

class _VaultImportConflictDialog extends StatefulWidget {
  const _VaultImportConflictDialog({required this.plan});

  final VaultImportPlan plan;

  @override
  State<_VaultImportConflictDialog> createState() =>
      _VaultImportConflictDialogState();
}

class _VaultImportConflictDialogState
    extends State<_VaultImportConflictDialog> {
  VaultImportConflictPolicy _policy = VaultImportConflictPolicy.keepLocal;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final conflictCount =
        plan.mailboxConflicts.length + plan.oauthProviderConflicts.length;
    return AlertDialog(
      title: const Text('Import conflicts found'),
      content: _DialogContent(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.newMailboxCount} new mailbox accounts and ${plan.newOAuthProviderCount} new OAuth providers will be added. $conflictCount existing entries match the import.',
            ),
            const SizedBox(height: 12),
            RadioGroup<VaultImportConflictPolicy>(
              groupValue: _policy,
              onChanged: (value) {
                if (value != null) setState(() => _policy = value);
              },
              child: const Column(
                children: [
                  RadioListTile<VaultImportConflictPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: VaultImportConflictPolicy.keepLocal,
                    title: Text('Keep local entries'),
                    subtitle: Text(
                      'Safer when the imported file may be older.',
                    ),
                  ),
                  RadioListTile<VaultImportConflictPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: VaultImportConflictPolicy.replaceLocal,
                    title: Text('Replace matching entries'),
                    subtitle: Text(
                      'Use credentials and settings from the file.',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_policy),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

String _newLocalProfileId() {
  return 'local-vault-${DateTime.now().microsecondsSinceEpoch}';
}

enum _LocalVaultSettingsAction { enableQuickUnlock, disableQuickUnlock }

class _LocalVaultSettingsDialog extends StatelessWidget {
  const _LocalVaultSettingsDialog({
    required this.profile,
    required this.quickUnlockAvailable,
    required this.quickUnlockEnabled,
    required this.quickUnlockMethod,
  });

  final LocalProfile profile;
  final bool quickUnlockAvailable;
  final bool quickUnlockEnabled;
  final String quickUnlockMethod;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Local vault'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: Text(profile.label),
              subtitle: Text(profile.id),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                quickUnlockEnabled
                    ? Icons.fingerprint
                    : Icons.lock_open_outlined,
                color:
                    quickUnlockEnabled
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
              ),
              title: Text(
                quickUnlockEnabled
                    ? 'System quick unlock enabled'
                    : 'System quick unlock disabled',
              ),
              subtitle: Text(
                quickUnlockAvailable
                    ? quickUnlockMethod
                    : '$quickUnlockMethod is not available on this device.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (quickUnlockEnabled)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colorScheme.error,
              foregroundColor: colorScheme.onError,
            ),
            onPressed:
                () => Navigator.of(
                  context,
                ).pop(_LocalVaultSettingsAction.disableQuickUnlock),
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('Disable'),
          )
        else
          FilledButton.icon(
            onPressed:
                quickUnlockAvailable
                    ? () => Navigator.of(
                      context,
                    ).pop(_LocalVaultSettingsAction.enableQuickUnlock)
                    : null,
            icon: const Icon(Icons.fingerprint),
            label: const Text('Enable'),
          ),
      ],
    );
  }
}

class _ServerSettingsDialog extends StatefulWidget {
  const _ServerSettingsDialog({
    required this.apiBaseUrl,
    required this.defaultApiBaseUrl,
  });

  final String apiBaseUrl;
  final String defaultApiBaseUrl;

  @override
  State<_ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _MailSettingsDialog extends StatefulWidget {
  const _MailSettingsDialog({required this.settings});

  final MailRenderSettings settings;

  @override
  State<_MailSettingsDialog> createState() => _MailSettingsDialogState();
}

class _OAuthProviderSettingsDialog extends StatefulWidget {
  const _OAuthProviderSettingsDialog({
    required this.providers,
    required this.gmailBuildClientId,
    required this.gmailBuildClientSecret,
    required this.gmailAndroidBuildClientId,
    required this.gmailAndroidBuildClientSecret,
    required this.gmailAndroidBuildRedirectUri,
    required this.outlookBuildClientId,
    required this.outlookBuildClientSecret,
    required this.outlookAndroidBuildClientId,
    required this.outlookAndroidBuildClientSecret,
    required this.outlookAndroidBuildRedirectUri,
  });

  final List<VaultOAuthProviderConfig> providers;
  final String gmailBuildClientId;
  final String gmailBuildClientSecret;
  final String gmailAndroidBuildClientId;
  final String gmailAndroidBuildClientSecret;
  final String gmailAndroidBuildRedirectUri;
  final String outlookBuildClientId;
  final String outlookBuildClientSecret;
  final String outlookAndroidBuildClientId;
  final String outlookAndroidBuildClientSecret;
  final String outlookAndroidBuildRedirectUri;

  @override
  State<_OAuthProviderSettingsDialog> createState() =>
      _OAuthProviderSettingsDialogState();
}

class _AppThemeSettingsDialog extends StatefulWidget {
  const _AppThemeSettingsDialog({required this.setting});

  final AppThemeSetting setting;

  @override
  State<_AppThemeSettingsDialog> createState() =>
      _AppThemeSettingsDialogState();
}

class _AppThemeSettingsDialogState extends State<_AppThemeSettingsDialog> {
  late AppThemeSetting _setting = widget.setting;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('App appearance'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AppThemeSetting>(
                segments: const [
                  ButtonSegment(
                    value: AppThemeSetting.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: AppThemeSetting.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: AppThemeSetting.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {_setting},
                onSelectionChanged: (values) {
                  setState(() => _setting = values.single);
                },
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Controls the app shell. Individual messages can still be switched from the reader.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_setting),
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

class _MailSettingsDialogState extends State<_MailSettingsDialog> {
  late bool _autoLoadRemoteImages = widget.settings.autoLoadRemoteImages;
  late bool _autoLoadExternalStylesAndFonts =
      widget.settings.autoLoadExternalStylesAndFonts;
  late MailAppearance _appearance = widget.settings.appearance;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mail rendering'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Mail appearance',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<MailAppearance>(
                segments: const [
                  ButtonSegment(
                    value: MailAppearance.automatic,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('Auto'),
                  ),
                  ButtonSegment(
                    value: MailAppearance.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: MailAppearance.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {_appearance},
                onSelectionChanged: (values) {
                  setState(() => _appearance = values.single);
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Sets the fallback reading canvas; message styles are preserved.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.image_outlined),
              title: const Text('Load remote images'),
              subtitle: const Text('Remote images can expose message opens.'),
              value: _autoLoadRemoteImages,
              onChanged: (value) {
                setState(() => _autoLoadRemoteImages = value);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.style_outlined),
              title: const Text('Load external styles and fonts'),
              subtitle: const Text(
                'External CSS and fonts can make tracking requests.',
              ),
              value: _autoLoadExternalStylesAndFonts,
              onChanged: (value) {
                setState(() => _autoLoadExternalStylesAndFonts = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop(
              MailRenderSettings(
                autoLoadRemoteImages: _autoLoadRemoteImages,
                autoLoadExternalStylesAndFonts: _autoLoadExternalStylesAndFonts,
                appearance: _appearance,
              ),
            );
          },
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

class _MailInteractionSettingsDialog extends StatefulWidget {
  const _MailInteractionSettingsDialog({
    required this.settings,
    required this.supportsMobileSwipe,
    required this.supportsDesktopContextMenu,
  });

  final MailInteractionSettings settings;
  final bool supportsMobileSwipe;
  final bool supportsDesktopContextMenu;

  @override
  State<_MailInteractionSettingsDialog> createState() =>
      _MailInteractionSettingsDialogState();
}

class _MailInteractionSettingsDialogState
    extends State<_MailInteractionSettingsDialog> {
  static const _actions = MailListActionPreference.values;

  late bool _mobileSwipeEnabled = widget.settings.mobileSwipeEnabled;
  late bool _desktopContextMenuEnabled =
      widget.settings.desktopContextMenuEnabled;
  late bool _multiSelectEnabled = widget.settings.multiSelectEnabled;
  late MailListActionPreference _rtlLevel1 =
      widget.settings.mobileSwipeRightToLeftLevel1;
  late MailListActionPreference _rtlLevel2 =
      widget.settings.mobileSwipeRightToLeftLevel2;
  late MailListActionPreference _ltrLevel1 =
      widget.settings.mobileSwipeLeftToRightLevel1;
  late MailListActionPreference _ltrLevel2 =
      widget.settings.mobileSwipeLeftToRightLevel2;
  late final Set<MailListActionPreference> _desktopActions =
      widget.settings.desktopContextMenuActions.toSet();

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: const Icon(Icons.checklist_outlined),
        title: const Text('Multi-select'),
        value: _multiSelectEnabled,
        onChanged: (value) => setState(() => _multiSelectEnabled = value),
      ),
    ];
    if (widget.supportsMobileSwipe) {
      sections.addAll([
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.swipe_outlined),
          title: const Text('Swipe actions'),
          value: _mobileSwipeEnabled,
          onChanged: (value) => setState(() => _mobileSwipeEnabled = value),
        ),
        _actionDropdown(
          label: 'Swipe left level 1',
          value: _rtlLevel1,
          onChanged: (value) => setState(() => _rtlLevel1 = value),
        ),
        const SizedBox(height: 10),
        _actionDropdown(
          label: 'Swipe left level 2',
          value: _rtlLevel2,
          onChanged: (value) => setState(() => _rtlLevel2 = value),
        ),
        const SizedBox(height: 10),
        _actionDropdown(
          label: 'Swipe right level 1',
          value: _ltrLevel1,
          onChanged: (value) => setState(() => _ltrLevel1 = value),
        ),
        const SizedBox(height: 10),
        _actionDropdown(
          label: 'Swipe right level 2',
          value: _ltrLevel2,
          onChanged: (value) => setState(() => _ltrLevel2 = value),
        ),
      ]);
    }
    if (widget.supportsDesktopContextMenu) {
      sections.addAll([
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.ads_click_outlined),
          title: const Text('Right-click menu'),
          value: _desktopContextMenuEnabled,
          onChanged:
              (value) => setState(() => _desktopContextMenuEnabled = value),
        ),
        for (final action in _actions)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _desktopActions.contains(action),
            secondary: Icon(_mailListActionIcon(action)),
            title: Text(_mailListActionLabel(action)),
            onChanged:
                (value) => setState(() {
                  if (value ?? false) {
                    _desktopActions.add(action);
                  } else {
                    _desktopActions.remove(action);
                  }
                }),
          ),
      ]);
    }
    return AlertDialog(
      title: const Text('Mail list actions'),
      content: _DialogContent(
        width: 460,
        maxHeight: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }

  Widget _actionDropdown({
    required String label,
    required MailListActionPreference value,
    required ValueChanged<MailListActionPreference> onChanged,
  }) {
    return DropdownButtonFormField<MailListActionPreference>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final action in _actions)
          DropdownMenuItem(
            value: action,
            child: Row(
              children: [
                Icon(_mailListActionIcon(action), size: 18),
                const SizedBox(width: 8),
                Text(_mailListActionLabel(action)),
              ],
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }

  void _save() {
    final desktopActions =
        _desktopActions.isEmpty
            ? MailInteractionSettings.defaultDesktopContextMenuActions
            : [
              for (final action in _actions)
                if (_desktopActions.contains(action)) action,
            ];
    Navigator.of(context).pop(
      widget.settings.copyWith(
        mobileSwipeEnabled: _mobileSwipeEnabled,
        desktopContextMenuEnabled: _desktopContextMenuEnabled,
        multiSelectEnabled: _multiSelectEnabled,
        mobileSwipeRightToLeftLevel1: _rtlLevel1,
        mobileSwipeRightToLeftLevel2: _rtlLevel2,
        mobileSwipeLeftToRightLevel1: _ltrLevel1,
        mobileSwipeLeftToRightLevel2: _ltrLevel2,
        desktopContextMenuActions: desktopActions,
      ),
    );
  }
}

class _OAuthProviderSettingsDialogState
    extends State<_OAuthProviderSettingsDialog> {
  late final TextEditingController _gmailClientId;
  late final TextEditingController _gmailClientSecret;
  late final TextEditingController _gmailAndroidClientId;
  late final TextEditingController _gmailAndroidClientSecret;
  late final TextEditingController _gmailAndroidRedirectUri;
  late final TextEditingController _outlookClientId;
  late final TextEditingController _outlookClientSecret;
  late final TextEditingController _outlookAndroidClientId;
  late final TextEditingController _outlookAndroidClientSecret;
  late final TextEditingController _outlookAndroidRedirectUri;
  late final List<VaultOAuthProviderConfig> _extraProviders;
  bool _showGmailSecret = false;
  bool _showGmailAndroidSecret = false;
  bool _showOutlookSecret = false;
  bool _showOutlookAndroidSecret = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final gmail = _provider('gmail');
    final outlook = _provider('outlook');
    _gmailClientId = TextEditingController(text: gmail?.clientId ?? '');
    _gmailClientSecret = TextEditingController(text: gmail?.clientSecret ?? '');
    _gmailAndroidClientId = TextEditingController(
      text: gmail?.androidClientId ?? '',
    );
    _gmailAndroidClientSecret = TextEditingController(
      text: gmail?.androidClientSecret ?? '',
    );
    _gmailAndroidRedirectUri = TextEditingController(
      text: gmail?.androidRedirectUri ?? '',
    );
    _outlookClientId = TextEditingController(text: outlook?.clientId ?? '');
    _outlookClientSecret = TextEditingController(
      text: outlook?.clientSecret ?? '',
    );
    _outlookAndroidClientId = TextEditingController(
      text: outlook?.androidClientId ?? '',
    );
    _outlookAndroidClientSecret = TextEditingController(
      text: outlook?.androidClientSecret ?? '',
    );
    _outlookAndroidRedirectUri = TextEditingController(
      text: outlook?.androidRedirectUri ?? '',
    );
    _extraProviders =
        widget.providers
            .where(
              (provider) =>
                  provider.provider != 'gmail' &&
                  provider.provider != 'outlook',
            )
            .toList();
  }

  @override
  void dispose() {
    _gmailClientId.dispose();
    _gmailClientSecret.dispose();
    _gmailAndroidClientId.dispose();
    _gmailAndroidClientSecret.dispose();
    _gmailAndroidRedirectUri.dispose();
    _outlookClientId.dispose();
    _outlookClientSecret.dispose();
    _outlookAndroidClientId.dispose();
    _outlookAndroidClientSecret.dispose();
    _outlookAndroidRedirectUri.dispose();
    super.dispose();
  }

  VaultOAuthProviderConfig? _provider(String provider) {
    final normalized = normalizeOAuthProviderKey(provider);
    for (final item in widget.providers) {
      if (item.provider == normalized) return item;
    }
    return null;
  }

  bool get _showAndroidOAuthFields => !kIsWeb && io.Platform.isAndroid;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('OAuth providers'),
      content: _DialogContent(
        width: 520,
        maxHeight: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _providerFields(
              provider: 'gmail',
              title: 'Gmail',
              icon: Icons.alternate_email,
              clientId: _gmailClientId,
              clientSecret: _gmailClientSecret,
              androidClientId: _gmailAndroidClientId,
              androidClientSecret: _gmailAndroidClientSecret,
              androidRedirectUri: _gmailAndroidRedirectUri,
              showSecret: _showGmailSecret,
              showAndroidSecret: _showGmailAndroidSecret,
              buildClientId: widget.gmailBuildClientId,
              buildClientSecret: widget.gmailBuildClientSecret,
              androidBuildClientId: widget.gmailAndroidBuildClientId,
              androidBuildClientSecret: widget.gmailAndroidBuildClientSecret,
              androidBuildRedirectUri: widget.gmailAndroidBuildRedirectUri,
              onToggleSecret:
                  () => setState(() => _showGmailSecret = !_showGmailSecret),
              onToggleAndroidSecret:
                  () => setState(
                    () => _showGmailAndroidSecret = !_showGmailAndroidSecret,
                  ),
            ),
            const Divider(height: 28),
            _providerFields(
              provider: 'outlook',
              title: 'Outlook',
              icon: Icons.business_center_outlined,
              clientId: _outlookClientId,
              clientSecret: _outlookClientSecret,
              androidClientId: _outlookAndroidClientId,
              androidClientSecret: _outlookAndroidClientSecret,
              androidRedirectUri: _outlookAndroidRedirectUri,
              showSecret: _showOutlookSecret,
              showAndroidSecret: _showOutlookAndroidSecret,
              buildClientId: widget.outlookBuildClientId,
              buildClientSecret: widget.outlookBuildClientSecret,
              androidBuildClientId: widget.outlookAndroidBuildClientId,
              androidBuildClientSecret: widget.outlookAndroidBuildClientSecret,
              androidBuildRedirectUri: widget.outlookAndroidBuildRedirectUri,
              onToggleSecret:
                  () =>
                      setState(() => _showOutlookSecret = !_showOutlookSecret),
              onToggleAndroidSecret:
                  () => setState(
                    () =>
                        _showOutlookAndroidSecret = !_showOutlookAndroidSecret,
                  ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }

  Widget _providerFields({
    required String provider,
    required String title,
    required IconData icon,
    required TextEditingController clientId,
    required TextEditingController clientSecret,
    required TextEditingController androidClientId,
    required TextEditingController androidClientSecret,
    required TextEditingController androidRedirectUri,
    required bool showSecret,
    required bool showAndroidSecret,
    required String buildClientId,
    required String buildClientSecret,
    required String androidBuildClientId,
    required String androidBuildClientSecret,
    required String androidBuildRedirectUri,
    required VoidCallback onToggleSecret,
    required VoidCallback onToggleAndroidSecret,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final showAndroidFields = _showAndroidOAuthFields;
    final usesNativeGoogleAndroid =
        showAndroidFields && normalizeOAuthProviderKey(provider) == 'gmail';
    final activeFallbackStatus =
        showAndroidFields
            ? _androidFallbackStatus(
              provider,
              androidBuildClientId,
              androidBuildClientSecret,
            )
            : _fallbackStatus(buildClientId, buildClientSecret);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon),
            const SizedBox(width: 10),
            Text(title, style: textTheme.titleMedium),
            const Spacer(),
            Tooltip(
              message: activeFallbackStatus,
              child: Icon(
                (showAndroidFields ? androidBuildClientId : buildClientId)
                        .trim()
                        .isEmpty
                    ? Icons.settings_outlined
                    : Icons.check_circle_outline,
                color:
                    (showAndroidFields ? androidBuildClientId : buildClientId)
                            .trim()
                            .isEmpty
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.primary,
                size: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!showAndroidFields || usesNativeGoogleAndroid) ...[
          Text(
            usesNativeGoogleAndroid ? 'Web server' : 'Desktop',
            style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: clientId,
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText:
                  usesNativeGoogleAndroid ? 'Web client ID' : 'Client ID',
              hintText:
                  usesNativeGoogleAndroid
                      ? 'Google OAuth Web client ID'
                      : _clientIdHint(provider),
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: clientSecret,
            obscureText: !showSecret,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText:
                  usesNativeGoogleAndroid
                      ? 'Web client secret'
                      : 'Client secret',
              prefixIcon: const Icon(Icons.key_outlined),
              suffixIcon: IconButton(
                tooltip: showSecret ? 'Hide secret' : 'Show secret',
                onPressed: onToggleSecret,
                icon: Icon(
                  showSecret
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${usesNativeGoogleAndroid ? 'Web' : 'Build'} fallback: '
              '${_fallbackStatus(buildClientId, buildClientSecret)}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        if (showAndroidFields) ...[
          Text(
            'Android',
            style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: androidClientId,
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Android client ID',
              hintText: _androidClientIdHint(provider),
              prefixIcon: const Icon(Icons.android_outlined),
            ),
          ),
          const SizedBox(height: 10),
          if (usesNativeGoogleAndroid) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'The Android client uses package name and SHA-1. The Web client '
                'from the same Google Cloud project provides offline refresh tokens.',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            TextField(
              controller: androidClientSecret,
              obscureText: !showAndroidSecret,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Android client secret',
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  tooltip:
                      showAndroidSecret
                          ? 'Hide Android secret'
                          : 'Show Android secret',
                  onPressed: onToggleAndroidSecret,
                  icon: Icon(
                    showAndroidSecret
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: androidRedirectUri,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Android redirect URI',
                hintText: _androidRedirectUriHint(provider),
                prefixIcon: const Icon(Icons.link_outlined),
                suffixIcon: IconButton(
                  tooltip: 'Copy provider redirect URI',
                  onPressed:
                      () => _copyAndroidRedirectUri(
                        provider: provider,
                        controller: androidRedirectUri,
                        androidBuildRedirectUri: androidBuildRedirectUri,
                      ),
                  icon: const Icon(Icons.content_copy),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Android fallback: ${_androidFallbackStatus(provider, androidBuildClientId, androidBuildClientSecret)}'
              '${usesNativeGoogleAndroid || androidBuildRedirectUri.trim().isEmpty ? '' : ', redirect URI configured'}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!usesNativeGoogleAndroid) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _androidRedirectProviderNote(
                  provider: provider,
                  androidBuildRedirectUri: androidBuildRedirectUri,
                ),
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _clientIdHint(String provider) {
    return switch (provider) {
      'gmail' => 'Google OAuth desktop client ID',
      'outlook' => 'Microsoft OAuth client ID',
      _ => 'OAuth client ID',
    };
  }

  String _androidClientIdHint(String provider) {
    return switch (provider) {
      'gmail' => 'Google OAuth Android client ID',
      'outlook' => 'Microsoft Android/mobile client ID',
      _ => 'Android OAuth client ID',
    };
  }

  String _androidRedirectUriHint(String provider) {
    return switch (provider) {
      'gmail' => 'com.nyatori.nyamail:/oauth2redirect',
      'outlook' => 'com.nyatori.nyamail:/oauth2redirect',
      _ => 'com.nyatori.nyamail:/oauth2redirect',
    };
  }

  String _androidRedirectProviderNote({
    required String provider,
    required String androidBuildRedirectUri,
  }) {
    final redirectUri =
        androidBuildRedirectUri.trim().isEmpty
            ? _androidRedirectUriHint(provider)
            : androidBuildRedirectUri.trim();
    final providerName = switch (provider) {
      'gmail' => 'Google Cloud',
      'outlook' => 'Microsoft Entra',
      _ => 'Provider console',
    };
    return '$providerName redirect URI: $redirectUri';
  }

  Future<void> _copyAndroidRedirectUri({
    required String provider,
    required TextEditingController controller,
    required String androidBuildRedirectUri,
  }) async {
    final redirectUri =
        controller.text.trim().isNotEmpty
            ? controller.text.trim()
            : androidBuildRedirectUri.trim().isNotEmpty
            ? androidBuildRedirectUri.trim()
            : _androidRedirectUriHint(provider);
    await Clipboard.setData(ClipboardData(text: redirectUri));
  }

  String _fallbackStatus(String clientId, String clientSecret) {
    final hasClientId = clientId.trim().isNotEmpty;
    final hasSecret = clientSecret.trim().isNotEmpty;
    if (hasClientId && hasSecret) return 'client id and secret configured';
    if (hasClientId) return 'client id configured';
    return 'not configured';
  }

  String _androidFallbackStatus(
    String provider,
    String clientId,
    String clientSecret,
  ) {
    if (normalizeOAuthProviderKey(provider) == 'gmail') {
      return clientId.trim().isEmpty
          ? 'not configured'
          : 'Android client id configured';
    }
    return _fallbackStatus(clientId, clientSecret);
  }

  void _save() {
    _error = null;
    final providers = [..._extraProviders];
    final gmail = _configFromFields(
      provider: 'gmail',
      clientId: _gmailClientId.text,
      clientSecret: _gmailClientSecret.text,
      androidClientId: _gmailAndroidClientId.text,
      androidClientSecret: _gmailAndroidClientSecret.text,
      androidRedirectUri: _gmailAndroidRedirectUri.text,
    );
    if (_error != null) return;
    final outlook = _configFromFields(
      provider: 'outlook',
      clientId: _outlookClientId.text,
      clientSecret: _outlookClientSecret.text,
      androidClientId: _outlookAndroidClientId.text,
      androidClientSecret: _outlookAndroidClientSecret.text,
      androidRedirectUri: _outlookAndroidRedirectUri.text,
    );
    if (_error != null) return;
    if (gmail != null) providers.add(gmail);
    if (outlook != null) providers.add(outlook);
    Navigator.of(context).pop(providers);
  }

  VaultOAuthProviderConfig? _configFromFields({
    required String provider,
    required String clientId,
    required String clientSecret,
    required String androidClientId,
    required String androidClientSecret,
    required String androidRedirectUri,
  }) {
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    final usesNativeGoogleAndroid = normalizedProvider == 'gmail';
    final id = clientId.trim();
    final secret = clientSecret.trim();
    final androidId = androidClientId.trim();
    final androidSecret =
        usesNativeGoogleAndroid ? '' : androidClientSecret.trim();
    final androidRedirect =
        usesNativeGoogleAndroid ? '' : androidRedirectUri.trim();
    if (id.isEmpty &&
        secret.isEmpty &&
        androidId.isEmpty &&
        androidSecret.isEmpty &&
        androidRedirect.isEmpty) {
      return null;
    }
    if (id.isEmpty) {
      if (secret.isNotEmpty) {
        setState(
          () => _error = 'Client ID is required when a client secret is set.',
        );
        return null;
      }
    }
    if (androidId.isEmpty &&
        (androidSecret.isNotEmpty || androidRedirect.isNotEmpty)) {
      setState(
        () =>
            _error =
                'Android client ID is required when Android OAuth values are set.',
      );
      return null;
    }
    return VaultOAuthProviderConfig(
      provider: normalizedProvider,
      clientId: id,
      clientSecret: secret,
      androidClientId: androidId,
      androidClientSecret: androidSecret,
      androidRedirectUri: androidRedirect,
    ).normalized();
  }
}

class _ServerSettingsDialogState extends State<_ServerSettingsDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.apiBaseUrl,
  );
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('NyaMail server'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://mail.example.com',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 8),
            Text(
              'Current: ${widget.apiBaseUrl}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed:
              widget.defaultApiBaseUrl.trim().isEmpty
                  ? null
                  : () {
                    _url.text = widget.defaultApiBaseUrl.trim();
                    _save();
                  },
          child: const Text('Use default'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final normalized = _normalizeApiBaseUrl(_url.text);
    if (normalized == null) {
      setState(
        () =>
            _error =
                'Use an absolute http:// or https:// URL without query or fragment.',
      );
      return;
    }
    Navigator.of(context).pop(normalized);
  }
}

String? _normalizeApiBaseUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.trim().isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  var normalizedPath = uri.path;
  if (normalizedPath.length > 1) {
    normalizedPath = normalizedPath.replaceFirst(RegExp(r'/+$'), '');
  }
  return uri
      .replace(path: normalizedPath)
      .toString()
      .replaceFirst(RegExp(r'/+$'), '');
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({
    required this.api,
    required this.apiBaseUrl,
    required this.secureStore,
  });

  final NyaMailApi api;
  final String apiBaseUrl;
  final LocalSecureStore secureStore;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  bool _register = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_register ? 'Create NyaMail account' : 'Sign in'),
      content: _DialogContent(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (_register) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _displayName,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Sync server'),
              subtitle: Text(
                widget.apiBaseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed:
                    _submitting
                        ? null
                        : () => Navigator.of(
                          context,
                        ).pop(_LoginDialogAction.serverSettings),
                child: const Text('Change'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => setState(() => _register = !_register),
          child: Text(_register ? 'Use existing account' : 'Create account'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child:
              _submitting
                  ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(),
                  )
                  : const Text('Continue'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final stableDeviceId = await widget.secureStore.readStableDeviceId();
      final deviceKeyPair =
          await widget.secureStore.readOrCreateDeviceKeyPair();
      final deviceBoxKeyPair =
          await widget.secureStore.readOrCreateDeviceBoxKeyPair();
      final device = DeviceInfoPayload(
        id: stableDeviceId,
        name: 'NyaMail device',
        platform: const String.fromEnvironment(
          'NYAMAIL_PLATFORM',
          defaultValue: 'auto',
        ),
        publicKey: deviceKeyPair.publicKey,
        keyAgreementPublicKey: deviceBoxKeyPair.publicKey,
      );
      final AuthSession session;
      if (_register) {
        session = await widget.api.register(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _displayName.text.trim(),
          device: device,
        );
      } else {
        session = await widget.api.login(
          email: _email.text.trim(),
          password: _password.text,
          device: device,
        );
      }
      await widget.secureStore.saveStableDeviceId(session.deviceId);
      _LoginPasswordMemory.write(_password.text);
      if (mounted) Navigator.of(context).pop(session);
    } catch (error) {
      setState(() {
        _error = error.toString();
        _submitting = false;
      });
    }
  }
}

enum _LoginDialogAction { serverSettings }

enum _SyncAccountAction { serverSettings, syncNow, leaveSync, signOut }

class _SyncAccountStatus {
  const _SyncAccountStatus({
    required this.profileId,
    this.cursor = 0,
    this.lastSyncedAt,
    this.recordCount = 0,
    this.dirtyRecordCount = 0,
    this.tombstoneCount = 0,
    this.hasRecordVault = false,
    this.error,
  });

  final String profileId;
  final int cursor;
  final DateTime? lastSyncedAt;
  final int recordCount;
  final int dirtyRecordCount;
  final int tombstoneCount;
  final bool hasRecordVault;
  final String? error;

  bool get hasError => error != null && error!.trim().isNotEmpty;
}

class _SyncAccountDialog extends StatelessWidget {
  const _SyncAccountDialog({
    required this.session,
    required this.apiBaseUrl,
    required this.status,
  });

  final LocalSession session;
  final String apiBaseUrl;
  final _SyncAccountStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor =
        status.hasError
            ? colorScheme.error
            : status.dirtyRecordCount > 0
            ? colorScheme.tertiary
            : colorScheme.primary;
    return AlertDialog(
      title: const Text('Sync account'),
      content: _DialogContent(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Signed in as'),
              subtitle: Text(session.email),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_outlined),
              title: Text(session.deviceName),
              subtitle: Text('${session.devicePlatform} - ${session.deviceId}'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Sync server'),
              subtitle: Text(
                apiBaseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                onPressed:
                    () => Navigator.of(
                      context,
                    ).pop(_SyncAccountAction.serverSettings),
                child: const Text('Change'),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                status.dirtyRecordCount > 0
                    ? Icons.sync_problem_outlined
                    : Icons.cloud_done_outlined,
                color: statusColor,
              ),
              title: Text(_syncStatusTitle(status)),
              subtitle: Text(
                _syncStatusSubtitle(status),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Text(
                'Signing out disconnects sync on this device. Your local encrypted vault, mailbox settings, and mail cache remain available.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton.icon(
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.syncNow),
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.leaveSync),
          icon: const Icon(Icons.link_off_outlined),
          label: const Text('Leave sync'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          onPressed:
              () => Navigator.of(context).pop(_SyncAccountAction.signOut),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

enum _MailboxSettingsActionKind { edit, reauthorize, remove }

class _MailboxSettingsAction {
  const _MailboxSettingsAction({required this.kind, required this.item});

  final _MailboxSettingsActionKind kind;
  final VaultMailboxItem item;
}

class _MailboxSettingsDialog extends StatelessWidget {
  const _MailboxSettingsDialog({
    required this.items,
    required this.selectedMailboxId,
  });

  final List<VaultMailboxItem> items;
  final String? selectedMailboxId;

  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) {
      if (a.id == selectedMailboxId) return -1;
      if (b.id == selectedMailboxId) return 1;
      return a.address.compareTo(b.address);
    });
    return AlertDialog(
      title: const Text('Mailboxes'),
      content: _DialogContent(
        width: 560,
        maxHeight: 680,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = sorted[index];
            final label =
                item.displayName.trim().isEmpty
                    ? item.address
                    : item.displayName;
            return ListTile(
              leading: Icon(
                item.kind == VaultItemKind.oauth
                    ? Icons.open_in_browser
                    : Icons.key_outlined,
              ),
              title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${item.address} - ${item.provider}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: PopupMenuButton<_MailboxSettingsActionKind>(
                tooltip: 'Mailbox actions',
                onSelected:
                    (kind) => Navigator.of(
                      context,
                    ).pop(_MailboxSettingsAction(kind: kind, item: item)),
                itemBuilder:
                    (context) => [
                      const PopupMenuItem(
                        value: _MailboxSettingsActionKind.edit,
                        child: ListTile(
                          leading: Icon(Icons.settings_outlined),
                          title: Text('Settings'),
                          dense: true,
                        ),
                      ),
                      if (item.kind == VaultItemKind.oauth)
                        const PopupMenuItem(
                          value: _MailboxSettingsActionKind.reauthorize,
                          child: ListTile(
                            leading: Icon(Icons.refresh),
                            title: Text('Reauthorize OAuth'),
                            dense: true,
                          ),
                        ),
                      const PopupMenuItem(
                        value: _MailboxSettingsActionKind.remove,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Remove'),
                          dense: true,
                        ),
                      ),
                    ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _MailboxEditDialog extends StatefulWidget {
  const _MailboxEditDialog({required this.item});

  final VaultMailboxItem item;

  @override
  State<_MailboxEditDialog> createState() => _MailboxEditDialogState();
}

class _MailboxEditDialogState extends State<_MailboxEditDialog> {
  late final TextEditingController _displayName = TextEditingController(
    text: widget.item.displayName,
  );
  late final TextEditingController _username = TextEditingController(
    text:
        widget.item.username.trim().isEmpty
            ? _defaultUsernameForAddress(widget.item.address)
            : widget.item.username,
  );
  late final TextEditingController _secret = TextEditingController(
    text:
        widget.item.kind == VaultItemKind.oauth &&
                !_providerSupportsOAuth(widget.item.provider)
            ? ''
            : widget.item.secret,
  );
  late final TextEditingController _imapHost = TextEditingController(
    text: widget.item.imapHost,
  );
  late final TextEditingController _imapPort = TextEditingController(
    text: widget.item.imapPort.toString(),
  );
  late final TextEditingController _smtpHost = TextEditingController(
    text: widget.item.smtpHost,
  );
  late final TextEditingController _smtpPort = TextEditingController(
    text: widget.item.smtpPort.toString(),
  );
  late String _provider = widget.item.provider;
  late String _authMode =
      widget.item.kind == VaultItemKind.oauth &&
              _providerSupportsOAuth(widget.item.provider)
          ? 'oauth'
          : 'app_password';
  late bool _useTls = widget.item.useTls;
  String? _error;

  @override
  void dispose() {
    _displayName.dispose();
    _username.dispose();
    _secret.dispose();
    _imapHost.dispose();
    _imapPort.dispose();
    _smtpHost.dispose();
    _smtpPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oauthAvailable = _providerSupportsOAuth(_provider);
    return AlertDialog(
      title: const Text('Mailbox settings'),
      content: _DialogContent(
        width: 460,
        maxHeight: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alternate_email),
              title: Text(widget.item.address),
              subtitle: Text(widget.item.id),
            ),
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText:
                    'Defaults to the mailbox address. Edit only if your provider uses a different login name.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(
                  value: 'imap',
                  child: Text('Generic IMAP/SMTP'),
                ),
                DropdownMenuItem(value: 'gmail', child: Text('Gmail')),
                DropdownMenuItem(value: 'outlook', child: Text('Outlook')),
                DropdownMenuItem(value: 'icloud', child: Text('iCloud')),
              ],
              onChanged:
                  (value) => setState(() {
                    _provider = value ?? 'imap';
                    if (!_providerSupportsOAuth(_provider) &&
                        _authMode == 'oauth') {
                      _authMode = 'app_password';
                      _secret.clear();
                    }
                  }),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                  value: 'app_password',
                  icon: Icon(Icons.key_outlined),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: 'oauth',
                  enabled: oauthAvailable,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('OAuth'),
                ),
              ],
              selected: {_authMode},
              onSelectionChanged: (values) {
                final next = values.single;
                if (next == 'oauth' && !oauthAvailable) return;
                setState(() {
                  if (_authMode == 'oauth' && next == 'app_password') {
                    _secret.clear();
                  }
                  _authMode = next;
                });
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _secret,
              obscureText: true,
              enabled: _authMode == 'app_password',
              decoration: InputDecoration(
                labelText:
                    _authMode == 'oauth'
                        ? 'OAuth token is managed by reauthorization'
                        : 'App password or token',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _imapHost,
                    decoration: const InputDecoration(labelText: 'IMAP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _imapPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _smtpHost,
                    decoration: const InputDecoration(labelText: 'SMTP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _smtpPort,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use TLS'),
              value: _useTls,
              onChanged: (value) => setState(() => _useTls = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check),
          label: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final imapPort = int.tryParse(_imapPort.text.trim());
    final smtpPort = int.tryParse(_smtpPort.text.trim());
    if (imapPort == null || smtpPort == null) {
      setState(() => _error = 'Ports must be numbers.');
      return;
    }
    if (_authMode == 'app_password' && _secret.text.isEmpty) {
      setState(() => _error = 'Enter the app password or token.');
      return;
    }
    final oauth = _authMode == 'oauth';
    final displayName =
        _displayName.text.trim().isEmpty
            ? widget.item.address
            : _displayName.text.trim();
    final username =
        _username.text.trim().isEmpty
            ? _defaultUsernameForAddress(widget.item.address)
            : _username.text.trim();
    Navigator.of(context).pop(
      VaultMailboxItem(
        id: widget.item.id,
        kind: oauth ? VaultItemKind.oauth : VaultItemKind.imapSmtp,
        address: widget.item.address,
        displayName: displayName,
        provider: _provider,
        username: username,
        secret: oauth ? widget.item.secret : _secret.text,
        refreshToken: oauth ? widget.item.refreshToken : '',
        tokenExpiresAt: oauth ? widget.item.tokenExpiresAt : null,
        tokenScope: oauth ? widget.item.tokenScope : '',
        oauthClientId: oauth ? widget.item.oauthClientId : '',
        oauthClientSecret: oauth ? widget.item.oauthClientSecret : '',
        imapHost: _imapHost.text.trim(),
        imapPort: imapPort,
        smtpHost: _smtpHost.text.trim(),
        smtpPort: smtpPort,
        useTls: _useTls,
      ),
    );
  }
}

class _AddMailboxDialog extends StatefulWidget {
  const _AddMailboxDialog({
    required this.document,
    required this.vaultCrypto,
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
  });

  final VaultDocument document;
  final VaultCrypto vaultCrypto;
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

  @override
  State<_AddMailboxDialog> createState() => _AddMailboxDialogState();
}

class _AddMailboxResult {
  const _AddMailboxResult({required this.mailbox, required this.document});

  final MailboxSummary mailbox;
  final VaultDocument document;
}

class _AddMailboxDialogState extends State<_AddMailboxDialog> {
  final _address = TextEditingController();
  final _displayName = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '587');
  String _provider = 'imap';
  String _authMode = 'app_password';
  bool _useTls = true;
  bool _submitting = false;
  String? _error;
  String? _status;
  MailboxCredential? _pendingCredential;
  String _lastAutoUsername = '';
  bool _syncingUsernameFromAddress = false;
  bool _usernameManuallyEdited = false;

  @override
  void initState() {
    super.initState();
    _address.addListener(_prefillHosts);
    _username.addListener(_handleUsernameChanged);
  }

  @override
  void dispose() {
    _address.removeListener(_prefillHosts);
    _username.removeListener(_handleUsernameChanged);
    _address.dispose();
    _displayName.dispose();
    _username.dispose();
    _secret.dispose();
    _imapHost.dispose();
    _imapPort.dispose();
    _smtpHost.dispose();
    _smtpPort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final oauthAvailable = _providerSupportsOAuth(_provider);
    return AlertDialog(
      title: const Text('Add mailbox'),
      content: _DialogContent(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Mailbox address'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _displayName,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: 'Username',
                helperText:
                    'Defaults to the mailbox address. Edit only if your provider uses a different login name.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(
                  value: 'imap',
                  child: Text('Generic IMAP/SMTP'),
                ),
                DropdownMenuItem(value: 'gmail', child: Text('Gmail')),
                DropdownMenuItem(value: 'outlook', child: Text('Outlook')),
                DropdownMenuItem(value: 'icloud', child: Text('iCloud')),
              ],
              onChanged: (value) {
                setState(() {
                  _provider = value ?? 'imap';
                  _applyProviderPreset();
                  if (!_providerSupportsOAuth(_provider) &&
                      _authMode == 'oauth') {
                    _authMode = 'app_password';
                    _secret.clear();
                  }
                });
              },
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                  value: 'app_password',
                  icon: Icon(Icons.key_outlined),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: 'oauth',
                  enabled: oauthAvailable,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('OAuth'),
                ),
              ],
              selected: {_authMode},
              onSelectionChanged: (values) {
                final next = values.single;
                if (next == 'oauth' && !oauthAvailable) return;
                setState(() {
                  if (_authMode == 'oauth' && next == 'app_password') {
                    _secret.clear();
                  }
                  _authMode = next;
                });
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _secret,
              obscureText: true,
              enabled: _authMode == 'app_password',
              decoration: InputDecoration(
                labelText:
                    _authMode == 'oauth'
                        ? 'OAuth token comes from browser authorization'
                        : 'App password or token',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _imapHost,
                    decoration: const InputDecoration(labelText: 'IMAP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _imapPort,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _smtpHost,
                    decoration: const InputDecoration(labelText: 'SMTP host'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _smtpPort,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use TLS'),
              value: _useTls,
              onChanged: (value) => setState(() => _useTls = value),
            ),
            if (_authMode == 'oauth') ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Builder(
                  builder: (context) {
                    final clientIdMissing =
                        _oauthClientIdForProvider(_provider).isEmpty;
                    final clientSecretMissing =
                        !io.Platform.isAndroid &&
                        _provider == 'gmail' &&
                        _oauthClientSecretForProvider(_provider).isEmpty;
                    return Text(
                      clientIdMissing
                          ? 'OAuth client id is not configured for this provider.'
                          : clientSecretMissing
                          ? 'Google Desktop OAuth may require the client secret from Google Cloud.'
                          : _usesGoogleAndroidOAuth(_provider)
                          ? 'Android will use Google account authorization.'
                          : 'OAuth will open the provider in your browser.',
                      style: TextStyle(
                        color:
                            clientIdMissing || clientSecretMissing
                                ? Theme.of(context).colorScheme.error
                                : Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: Icon(
            _authMode == 'oauth'
                ? Icons.open_in_browser
                : Icons.fact_check_outlined,
          ),
          label: Text(
            _authMode == 'oauth' ? 'Authorize and add' : 'Verify and add',
          ),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
      _status =
          _authMode == 'oauth' ? 'Waiting for provider authorization...' : null;
    });
    if (_authMode == 'oauth') {
      await _submitOAuth();
      return;
    }
    try {
      final address = _address.text.trim();
      final vaultItemId = widget.vaultCrypto.newVaultItemId(address);
      final credential = _buildCredential(
        accountId: vaultItemId,
        address: address,
      );
      _pendingCredential = credential;
      await const SocketMailTransport().validateCredential(
        credential: credential,
      );
      final document = widget.document.upsertMailbox(
        VaultMailboxItem(
          id: vaultItemId,
          kind: VaultItemKind.imapSmtp,
          address: address,
          displayName: credential.displayName,
          provider: _provider,
          username: credential.username,
          secret: credential.secret,
          imapHost: credential.imapHost,
          imapPort: credential.imapPort,
          smtpHost: credential.smtpHost,
          smtpPort: credential.smtpPort,
          useTls: credential.useTls,
        ),
      );
      final mailbox = MailboxSummary(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: _provider,
        authType: 'app_password',
        vaultItemId: vaultItemId,
      );
      if (mounted) {
        Navigator.of(
          context,
        ).pop(_AddMailboxResult(mailbox: mailbox, document: document));
      }
    } catch (error) {
      setState(() {
        final credential = _pendingCredential;
        _error =
            credential == null
                ? error.toString()
                : const MailboxSetupDiagnostics().message(
                  provider: _provider,
                  credential: credential,
                  error: error,
                );
        _submitting = false;
        _status = null;
      });
    } finally {
      _pendingCredential = null;
    }
  }

  Future<void> _submitOAuth() async {
    try {
      final address = _address.text.trim();
      final clientId = _oauthClientIdForProvider(_provider);
      if (clientId.isEmpty) {
        throw StateError('OAuth client id is not configured for $_provider.');
      }
      final clientSecret = _oauthClientSecretForProvider(_provider);
      final oauthProvider = oauthProviderConfig(_provider);
      final vaultItemId = widget.vaultCrypto.newVaultItemId(address);
      final tokenSet = await _authorizeOAuthForCurrentPlatform(
        oauthClient: widget.oauthClient,
        provider: oauthProvider,
        clientId: clientId,
        androidClientId: _oauthAndroidClientIdForProvider(_provider),
        clientSecret: clientSecret,
        loginHint: address,
        mobileRedirectUri: _oauthMobileRedirectUriForProvider(_provider),
        forceAccountPicker: true,
        onProgress: _setOAuthProgress,
      );
      final item = oauthMailboxItem(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: oauthProvider,
        tokenSet: tokenSet,
        oauthClientId: clientId,
        oauthClientSecret: clientSecret,
      );
      final credential = item.toCredential();
      _pendingCredential = credential;
      if (mounted) {
        setState(
          () => _status = _oauthValidationMessage(oauthProvider.provider),
        );
      }
      await const SocketMailTransport().validateCredential(
        credential: credential,
      );
      final document = widget.document.upsertMailbox(item);
      final mailbox = MailboxSummary(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: oauthProvider.provider,
        authType: 'oauth',
        vaultItemId: vaultItemId,
      );
      if (mounted) {
        Navigator.of(
          context,
        ).pop(_AddMailboxResult(mailbox: mailbox, document: document));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          final credential = _pendingCredential;
          _error =
              credential == null
                  ? error.toString()
                  : const MailboxSetupDiagnostics().message(
                    provider: _provider,
                    credential: credential,
                    error: error,
                  );
          _submitting = false;
          _status = null;
        });
      }
    } finally {
      _pendingCredential = null;
    }
  }

  MailboxCredential _buildCredential({
    required String accountId,
    required String address,
  }) {
    final displayName =
        _displayName.text.trim().isEmpty ? address : _displayName.text.trim();
    final username =
        _username.text.trim().isEmpty
            ? _defaultUsernameForAddress(address)
            : _username.text.trim();
    return MailboxCredential(
      accountId: accountId,
      address: address,
      displayName: displayName,
      imapHost: _imapHost.text.trim(),
      imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
      smtpHost: _smtpHost.text.trim(),
      smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 587,
      username: username,
      secret: _secret.text,
      useTls: _useTls,
    );
  }

  void _prefillHosts() {
    final address = _address.text.trim();
    final defaultUsername = _defaultUsernameForAddress(address);
    if (!_usernameManuallyEdited) {
      _setAutoUsername(defaultUsername);
    }
    if (!_looksCompleteEmailAddress(address)) return;
    _applyProviderPreset();
  }

  void _handleUsernameChanged() {
    if (_syncingUsernameFromAddress) return;
    if (_username.text != _lastAutoUsername) {
      _usernameManuallyEdited = true;
    }
  }

  void _setAutoUsername(String value) {
    if (_username.text == value && _lastAutoUsername == value) return;
    _syncingUsernameFromAddress = true;
    _lastAutoUsername = value;
    _username.text = value;
    _syncingUsernameFromAddress = false;
  }

  void _setOAuthProgress(OAuthAuthorizationProgress progress) {
    if (!mounted) return;
    setState(() => _status = _oauthProgressMessage(progress, _provider));
  }

  bool _looksCompleteEmailAddress(String value) {
    final parts = value.split('@');
    if (parts.length != 2) return false;
    final local = parts.first.trim();
    final domain = parts.last.trim();
    if (local.isEmpty || domain.isEmpty || !domain.contains('.')) return false;
    return domain.split('.').every((part) => part.trim().isNotEmpty);
  }

  void _applyProviderPreset() {
    final preset = presetForProvider(_provider, _address.text.trim());
    _imapHost.text = preset.imapHost;
    _imapPort.text = preset.imapPort.toString();
    _smtpHost.text = preset.smtpHost;
    _smtpPort.text = preset.smtpPort.toString();
    _useTls = preset.useTls;
  }

  String _oauthClientIdForProvider(String provider) {
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final normalizedProvider = normalizeOAuthProviderKey(provider);
    if (io.Platform.isAndroid && normalizedProvider != 'gmail') {
      final androidClientId = vaultConfig?.androidClientId.trim() ?? '';
      if (androidClientId.isNotEmpty) return androidClientId;
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
    final vaultConfig = widget.document.oauthProviderFor(provider);
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
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final clientId = vaultConfig?.androidClientId.trim() ?? '';
    if (clientId.isNotEmpty) return clientId;
    return widget.gmailAndroidOAuthClientId.trim();
  }

  Uri? _oauthMobileRedirectUriForProvider(String provider) {
    if (!io.Platform.isAndroid) return null;
    if (_usesGoogleAndroidOAuth(provider)) return null;
    final vaultConfig = widget.document.oauthProviderFor(provider);
    final vaultRedirectUri = vaultConfig?.androidRedirectUri.trim() ?? '';
    if (vaultRedirectUri.isNotEmpty) {
      return _parseOAuthRedirectUri(vaultRedirectUri);
    }
    final buildRedirectUri = switch (provider) {
      'gmail' => widget.gmailAndroidOAuthRedirectUri.trim(),
      'outlook' => widget.outlookAndroidOAuthRedirectUri.trim(),
      _ => '',
    };
    if (buildRedirectUri.isEmpty) return null;
    return _parseOAuthRedirectUri(buildRedirectUri);
  }

  Uri _parseOAuthRedirectUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme) {
      throw StateError('Android OAuth redirect URI is invalid.');
    }
    return uri;
  }
}

class _LoginPasswordMemory {
  static String? _password;

  static Future<void> write(String password) async {
    _password = password;
  }

  static Future<void> clear() async {
    _password = null;
  }

  static Future<String?> read() async => _password;
}

IconData _iconForMailbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.inbox => Icons.inbox_outlined,
    MailboxKind.sent => Icons.send_outlined,
    MailboxKind.drafts => Icons.drafts_outlined,
    MailboxKind.archive => Icons.archive_outlined,
    MailboxKind.spam => Icons.report_gmailerrorred_outlined,
    MailboxKind.trash => Icons.delete_outline,
    MailboxKind.custom => Icons.folder_outlined,
  };
}

String _labelForMailbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.inbox => 'Inbox',
    MailboxKind.sent => 'Sent',
    MailboxKind.drafts => 'Drafts',
    MailboxKind.archive => 'Archive',
    MailboxKind.spam => 'Spam',
    MailboxKind.trash => 'Trash',
    MailboxKind.custom => 'Folder',
  };
}

String _localFolderPathFor(MailboxKind mailbox) {
  return switch (mailbox) {
    MailboxKind.inbox => 'INBOX',
    MailboxKind.sent => 'Sent',
    MailboxKind.drafts => 'Drafts',
    MailboxKind.archive => 'Archive',
    MailboxKind.spam => 'Spam',
    MailboxKind.trash => 'Trash',
    MailboxKind.custom => 'Folder',
  };
}

bool _canMoveToInbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.archive ||
    MailboxKind.spam ||
    MailboxKind.trash ||
    MailboxKind.custom => true,
    MailboxKind.inbox || MailboxKind.sent || MailboxKind.drafts => false,
  };
}

bool _mailListActionAppliesToMessage(
  MailListActionPreference action,
  MailMessage message,
) {
  final mailbox = message.effectiveMailbox;
  return switch (action) {
    MailListActionPreference.archive => mailbox != MailboxKind.archive,
    MailListActionPreference.delete => mailbox != MailboxKind.trash,
    MailListActionPreference.moveToInbox => _canMoveToInbox(mailbox),
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.toggleStar => true,
  };
}

IconData _mailListActionIcon(
  MailListActionPreference action, {
  MailMessage? message,
  bool? read,
  bool? starred,
  bool? pinned,
}) {
  final effectiveRead = read ?? message?.read;
  final effectiveStarred = starred ?? message?.starred;
  final effectivePinned = pinned ?? false;
  return switch (action) {
    MailListActionPreference.pin =>
      effectivePinned ? Icons.push_pin : Icons.push_pin_outlined,
    MailListActionPreference.delete => Icons.delete_outline,
    MailListActionPreference.toggleRead =>
      effectiveRead == true
          ? Icons.mark_email_unread_outlined
          : Icons.mark_email_read_outlined,
    MailListActionPreference.toggleStar =>
      effectiveStarred == true ? Icons.star : Icons.star_border,
    MailListActionPreference.archive => Icons.archive_outlined,
    MailListActionPreference.moveToInbox => Icons.move_to_inbox_outlined,
  };
}

String _mailListActionLabel(
  MailListActionPreference action, {
  MailMessage? message,
  bool? read,
  bool? starred,
  bool? pinned,
}) {
  final effectiveRead = read ?? message?.read;
  final effectiveStarred = starred ?? message?.starred;
  final effectivePinned = pinned ?? false;
  return switch (action) {
    MailListActionPreference.pin => effectivePinned ? 'Unpin' : 'Pin',
    MailListActionPreference.delete => 'Delete',
    MailListActionPreference.toggleRead =>
      effectiveRead == true ? 'Mark unread' : 'Mark read',
    MailListActionPreference.toggleStar =>
      effectiveStarred == true ? 'Unstar' : 'Star',
    MailListActionPreference.archive => 'Archive',
    MailListActionPreference.moveToInbox => 'Move to inbox',
  };
}

Color _mailListActionColor(
  MailListActionPreference action,
  ColorScheme colorScheme,
) {
  return switch (action) {
    MailListActionPreference.delete => colorScheme.errorContainer,
    MailListActionPreference.toggleStar => colorScheme.tertiaryContainer,
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.archive ||
    MailListActionPreference.moveToInbox => colorScheme.primaryContainer,
  };
}

Color _mailListActionForegroundColor(
  MailListActionPreference action,
  ColorScheme colorScheme,
) {
  return switch (action) {
    MailListActionPreference.delete => colorScheme.onErrorContainer,
    MailListActionPreference.toggleStar => colorScheme.onTertiaryContainer,
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.archive ||
    MailListActionPreference.moveToInbox => colorScheme.onPrimaryContainer,
  };
}

IconData _iconForSmartFolder(MailSmartFolder folder) {
  return switch (folder) {
    MailSmartFolder.allIncoming => Icons.all_inbox_outlined,
    MailSmartFolder.unread => Icons.mark_email_unread_outlined,
    MailSmartFolder.inbox => Icons.inbox_outlined,
    MailSmartFolder.sent => Icons.send_outlined,
    MailSmartFolder.drafts => Icons.drafts_outlined,
    MailSmartFolder.archive => Icons.archive_outlined,
    MailSmartFolder.spam => Icons.report_gmailerrorred_outlined,
    MailSmartFolder.trash => Icons.delete_outline,
  };
}

String _labelForSmartFolder(MailSmartFolder folder) {
  return switch (folder) {
    MailSmartFolder.allIncoming => 'All incoming',
    MailSmartFolder.unread => 'Unread',
    MailSmartFolder.inbox => 'Inbox',
    MailSmartFolder.sent => 'Sent',
    MailSmartFolder.drafts => 'Drafts',
    MailSmartFolder.archive => 'Archive',
    MailSmartFolder.spam => 'Spam',
    MailSmartFolder.trash => 'Trash',
  };
}

String _labelForMailboxView(MailboxView view, List<MailAccount> accounts) {
  final smart = view.smartFolder;
  if (smart != null) return _labelForSmartFolder(smart);
  final folder = view.folder;
  if (folder == null) return 'Mail';
  MailAccount? account;
  for (final item in accounts) {
    if (item.id == folder.accountId) {
      account = item;
      break;
    }
  }
  final accountLabel =
      account == null
          ? folder.accountId
          : account.displayName.trim().isEmpty
          ? account.address
          : account.displayName;
  return '$accountLabel / ${folder.displayName}';
}

String _mailboxContextLabelForMessage(
  MailMessage? message,
  List<MailAccount> accounts,
) {
  if (message == null) return '';
  MailAccount? account;
  for (final item in accounts) {
    if (item.id == message.accountId) {
      account = item;
      break;
    }
  }
  final accountLabel =
      account == null
          ? message.accountId
          : account.displayName.trim().isEmpty
          ? account.address
          : account.displayName;
  final folderLabel =
      message.folderDisplayName.trim().isNotEmpty
          ? message.folderDisplayName.trim()
          : message.folderPath.trim().isNotEmpty
          ? message.folderPath.trim()
          : _labelForMailbox(message.effectiveMailbox);
  return accountLabel.trim().isEmpty
      ? folderLabel
      : '$accountLabel / $folderLabel';
}

String _defaultUsernameForAddress(String address) {
  return address.trim();
}

bool _providerSupportsOAuth(String provider) {
  return switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' || 'outlook' || 'microsoft' => true,
    _ => false,
  };
}

String _oauthProgressMessage(
  OAuthAuthorizationProgress progress,
  String provider,
) {
  final label = _providerLabel(provider);
  return switch (progress) {
    OAuthAuthorizationProgress.waitingForAuthorization =>
      'Waiting for $label authorization...',
    OAuthAuthorizationProgress.callbackReceived =>
      '$label callback received. Requesting token...',
    OAuthAuthorizationProgress.exchangingToken => 'Requesting $label token...',
  };
}

String _oauthValidationMessage(String provider) {
  final label = switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' => 'Google mailbox',
    'outlook' || 'microsoft' => 'Outlook mailbox',
    _ => '${provider.trim().isEmpty ? 'OAuth' : provider.trim()} mailbox',
  };
  return 'Validating $label access...';
}

String _providerLabel(String provider) {
  return switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' => 'Google OAuth',
    'outlook' || 'microsoft' => 'Outlook OAuth',
    _ => '${provider.trim().isEmpty ? 'OAuth' : provider.trim()} OAuth',
  };
}

List<MailFolder> _foldersForAccount(
  List<MailFolder> folders,
  String accountId,
) {
  return folders
      .where((folder) => folder.accountId == accountId && folder.selectable)
      .toList(growable: false);
}

IconData _iconForMailAppearance(MailAppearance appearance) {
  return switch (appearance) {
    MailAppearance.automatic => Icons.brightness_auto_outlined,
    MailAppearance.light => Icons.light_mode_outlined,
    MailAppearance.dark => Icons.dark_mode_outlined,
  };
}

_MessageAppearanceAction _messageAppearanceActionFor(
  MailAppearance appearance,
) {
  return switch (appearance) {
    MailAppearance.automatic => _MessageAppearanceAction.automatic,
    MailAppearance.light => _MessageAppearanceAction.light,
    MailAppearance.dark => _MessageAppearanceAction.dark,
  };
}

String _attachmentKey(MailAttachment attachment) {
  return '${attachment.partId}:${attachment.filename}';
}

String _outgoingAttachmentSubtitle(OutgoingAttachment attachment) {
  return '${attachment.contentType} - ${_formatBytes(attachment.bytes.length)}';
}

String _attachmentSubtitle(MailAttachment attachment) {
  final size = attachment.size;
  if (size == null) return attachment.contentType;
  return '${attachment.contentType} - ${_formatBytes(size)}';
}

String _formatBytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _syncStatusTitle(_SyncAccountStatus status) {
  if (status.hasError) return 'Sync status unavailable';
  if (!status.hasRecordVault) return 'Record vault not initialized';
  if (status.dirtyRecordCount > 0) {
    return '${status.dirtyRecordCount} pending local change${status.dirtyRecordCount == 1 ? '' : 's'}';
  }
  return 'Record vault is synced';
}

String _syncStatusSubtitle(_SyncAccountStatus status) {
  if (status.hasError) return status.error!;
  return [
    'Last sync: ${_formatSyncDateTime(status.lastSyncedAt)}',
    'Cursor: ${status.cursor}',
    'Records: ${status.recordCount}',
    'Pending: ${status.dirtyRecordCount}',
    if (status.tombstoneCount > 0) 'Tombstones: ${status.tombstoneCount}',
  ].join(' - ');
}

String _formatSyncDateTime(DateTime? value) {
  if (value == null) return 'Never';
  final local = value.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _contentTypeForFilename(String filename) {
  final parts = filename.toLowerCase().split('.');
  final extension = parts.length > 1 ? parts.last : '';
  return switch (extension) {
    'txt' || 'text' => 'text/plain',
    'csv' => 'text/csv',
    'htm' || 'html' => 'text/html',
    'json' => 'application/json',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'gz' => 'application/gzip',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };
}
