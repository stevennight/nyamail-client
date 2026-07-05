import 'dart:async';
import 'dart:convert';

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
import '../mail/mailbox_diagnostics.dart';
import '../mail/mail_models.dart';
import '../mail/mail_render_settings.dart';
import '../mail/provider_presets.dart';
import '../mail/mail_repository.dart';
import '../mail/mail_transport.dart';
import '../oauth/oauth_loopback_client.dart';
import '../oauth/oauth_mailbox_builder.dart';
import '../oauth/oauth_provider.dart';
import '../oauth/oauth_vault_refresher.dart';
import '../release/release_service.dart';
import '../security/device_approval_crypto.dart';
import '../security/device_pairing_code.dart';
import '../security/device_pairing_request.dart';
import '../security/local_cache_crypto.dart';
import '../security/local_secure_store.dart';
import '../security/local_vault_auth.dart';
import '../security/local_vault_record_store.dart';
import '../security/local_vault_sync_state_store.dart';
import '../security/local_vault_store.dart';
import '../security/vault_crypto.dart';
import '../security/vault_document.dart';
import '../security/vault_record_crypto.dart';
import '../security/vault_record_sync_engine.dart';
import '../security/vault_records.dart';
import '../security/vault_share_crypto.dart';
import 'mail_html_view.dart';

const _maxOutgoingAttachmentBytes = 25 * 1024 * 1024;

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
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
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
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;
  final MailRepository mailRepository;

  @override
  State<MailHomePage> createState() => _MailHomePageState();
}

class _MailHomePageState extends State<MailHomePage> {
  static const _messagePageSize = 30;

  LocalSession? _session;
  LocalProfile? _profile;
  List<MailAccount> _accounts = const [];
  List<MailFolder> _folders = const [];
  List<MailMessage> _messages = const [];
  late MailRepository _mailRepository;
  MailDraftCache? _draftCache;
  VaultDocument? _vaultDocument;
  int? _vaultRevision;
  int? _vaultRecordRevision;
  String? _unlockedVaultSecret;
  String? _unlockedVaultPassword;
  MailboxView _view = const MailboxView.smart(MailSmartFolder.allIncoming);
  String? _selectedAccountId;
  MailMessage? _selected;
  MailRenderSettings _renderSettings = MailRenderSettings.defaults;
  bool _loading = true;
  bool _vaultUnlocking = false;
  bool _loadingMore = false;
  bool _refreshingOAuth = false;
  bool _claimingVaultShare = false;
  String? _banner;
  String? _pendingPairingPackage;
  final _search = TextEditingController();
  bool _hasMoreMessages = true;
  int _messageLoadGeneration = 0;
  late final LocalVaultAuthenticator _vaultAuthenticator =
      LocalVaultAuthenticator();

  @override
  void initState() {
    super.initState();
    _mailRepository = widget.mailRepository;
    _bootstrap();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await _bootstrapLocal();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _vaultUnlocking = false;
        _banner = 'Could not start NyaMail: $error';
      });
    }
  }

  Future<void> _bootstrapLocal() async {
    final renderSettings = await const MailRenderSettingsStore().load();
    var profile = await widget.secureStore.readLocalProfile();
    if (profile == null) {
      profile = await _createLocalVault();
      if (profile == null) {
        if (!mounted) return;
        setState(() {
          _renderSettings = renderSettings;
          _loading = false;
          _banner = 'Create a local encrypted vault before using NyaMail.';
        });
        return;
      }
    } else {
      _profile = profile;
      _draftCache = _draftCacheForProfile(profile);
      final unlocked = await _tryUnlockLocalVault(
        profile,
        promptIfNeeded: true,
      );
      if (!unlocked) {
        if (!mounted) return;
        setState(() {
          _renderSettings = renderSettings;
          _loading = false;
          _banner ??= 'Unlock the local vault before using NyaMail.';
        });
        return;
      }
    }
    final session = await widget.secureStore.readSession();
    if (session != null) {
      _session = session;
    }
    final accounts = await _mailRepository.accounts();
    final folders = await _mailRepository.folders();
    final activeView = _activeViewFor(folders);
    final page = await _mailRepository.cachedViewPage(
      view: activeView,
      limit: _messagePageSize,
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
      _messages = page.messages;
      _selected = _messageFor(
        page.messages,
        _selected?.id,
        fallbackToFirst: false,
      );
      _renderSettings = renderSettings;
      _hasMoreMessages = page.hasMore;
      _loading = false;
    });
    final requestId = _nextMessageLoadGeneration();
    // Keep the first unlocked frame local-only; network work continues behind it.
    unawaited(_refreshMessagesInBackground(requestId: requestId));
    if (session != null) {
      unawaited(_tryUnlockStoredVault(session));
    }
    unawaited(_checkUpdates(silent: true));
  }

  Future<bool> _tryUnlockLocalVault(
    LocalProfile profile, {
    bool promptIfNeeded = false,
  }) async {
    try {
      final vaultSecret = await _unlockVaultSecretForProfile(
        profile,
        promptIfNeeded: promptIfNeeded,
      );
      if (vaultSecret == null || vaultSecret.trim().isEmpty) {
        if (mounted) {
          final currentBanner = _banner;
          if (currentBanner == null ||
              currentBanner == 'Preparing local vault...' ||
              currentBanner == 'Unlocking local vault...') {
            setState(
              () =>
                  _banner =
                      'Local vault exists, but this device cannot unlock it.',
            );
          }
        }
        return false;
      }
      final recordSnapshot = await widget.localVaultRecordStore.read(
        profile.id,
      );
      if (recordSnapshot != null) {
        final records = await widget.vaultRecordCrypto.decryptRecordSet(
          records: recordSnapshot.records,
          vaultSecret: vaultSecret,
        );
        _vaultRecordRevision = recordSnapshot.revision;
        final document = records.toVaultDocument();
        await _applyVaultDocument(document, loadMessages: false);
        await _migrateLegacyVaultSecretIfNeeded(vaultSecret);
        return true;
      }
      var snapshot = await widget.localVaultStore.read(profile.id);
      snapshot ??= await widget.localVaultStore.write(
        profileId: profile.id,
        expectedRevision: 0,
        blob: await widget.vaultCrypto.createInitialVault(
          email: profile.email,
          password: '',
          vaultSecret: vaultSecret,
        ),
      );
      final document = await widget.vaultCrypto.decryptDocument(
        blob: snapshot.blob,
        email: profile.email,
        password: '',
        vaultSecret: vaultSecret,
      );
      await _saveLocalVaultRecords(
        profile: profile,
        document: document,
        vaultSecret: vaultSecret,
      );
      await _applyVaultDocument(
        document,
        revision: snapshot.revision,
        loadMessages: false,
      );
      await _migrateLegacyVaultSecretIfNeeded(vaultSecret);
      return true;
    } on VaultCryptoException catch (error) {
      if (mounted) {
        setState(() => _banner = error.message);
      }
      return false;
    } catch (error) {
      if (mounted) {
        setState(() => _banner = 'Could not unlock local vault: $error');
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
      final revision =
          profile == null
              ? vault.revision
              : await _saveLocalVaultDocument(
                profile: profile,
                document: document,
              );
      await _applyVaultDocument(
        document,
        revision: revision,
        loadMessages: false,
      );
      await _syncVaultRecordsWithServer(silent: true);
      await _refreshOAuthVaultIfNeeded();
    } catch (error) {
      _debugVault('stored server vault unlock failed', error);
      if (!mounted) return;
      if (_hasUnlockedLocalVault) {
        setState(
          () =>
              _banner =
                  'Sync account connected. Server vault sync will retry later.',
        );
        return;
      }
      setState(
        () => _banner = 'Signed in, but server vault could not be opened.',
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
    if (input == null) return null;
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
      if (mounted) {
        setState(() => _banner = 'System quick unlock was cancelled.');
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
            () =>
                _banner =
                    'System quick unlock failed. Use the vault password. ($error)',
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
    final snapshot = await widget.localVaultStore.write(
      profileId: profile.id,
      expectedRevision: 0,
      blob: await widget.vaultCrypto.createInitialVault(
        email: profile.email,
        password: '',
        vaultSecret: vaultSecret,
      ),
    );
    await _saveLocalVaultRecords(
      profile: profile,
      document: document,
      vaultSecret: vaultSecret,
    );
    _vaultDocument = document;
    _vaultRevision = snapshot.revision;

    final quickUnlockEnabled =
        input.enableQuickUnlock &&
        await _enableQuickUnlockForSecret(
          profile: profile,
          vaultSecret: vaultSecret,
        );
    await _applyVaultDocument(
      document,
      revision: snapshot.revision,
      loadMessages: false,
    );
    if (mounted) {
      setState(
        () =>
            _banner =
                quickUnlockEnabled
                    ? 'Local encrypted vault is ready. Quick unlock is enabled.'
                    : 'Local encrypted vault is ready.',
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
          setState(() => _banner = 'NyaMail is up to date.');
        }
        return;
      }
      final artifact = result.latest!;
      if (!await widget.releaseService.verifyManifestSignature(artifact)) {
        if (!mounted) return;
        setState(
          () => _banner = 'Update manifest signature could not be verified.',
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
      setState(() => _banner = 'Downloading update $label...');
      final file = await widget.releaseService.downloadAndVerify(artifact);
      await widget.releaseService.openDownloadedFile(file);
      if (!mounted) return;
      setState(() {
        _banner = 'Update downloaded, verified, and opened: ${file.path}';
      });
    } catch (_) {
      if (!silent && mounted) {
        setState(() => _banner = 'Could not complete the update.');
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
    final requestId = _nextMessageLoadGeneration();
    if (resetLimit) {
      _hasMoreMessages = true;
    }
    await _showCachedMessages(requestId: requestId, resetSelection: resetLimit);
    await _refreshMessagesInBackground(
      requestId: requestId,
      showErrors: true,
      preserveSelection: !resetLimit,
    );
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
      setState(() {
        _messages = page.messages;
        _selected = _messageFor(
          page.messages,
          resetSelection ? null : _selected?.id,
          fallbackToFirst: false,
        );
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _loadingMore = false;
        _banner = 'Could not load cached mail: $error';
      });
    }
  }

  Future<void> _refreshMessagesInBackground({
    required int requestId,
    bool showErrors = false,
    bool preserveSelection = true,
  }) async {
    try {
      await _refreshOAuthVaultIfNeeded();
      if (!_isCurrentMessageLoad(requestId)) return;
      final page = await _mailRepository.viewPage(
        view: _view,
        query: _search.text,
        limit: _messagePageSize,
      );
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _messages = page.messages;
        _selected = _messageFor(
          page.messages,
          preserveSelection ? _selected?.id : null,
          fallbackToFirst: false,
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
        _banner = 'Could not refresh mail: $error';
      });
    }
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
      await _refreshOAuthVaultIfNeeded();
      if (!_isCurrentMessageLoad(requestId)) return;
      final page = await _mailRepository.loadOlderViewMessages(
        view: _view,
        query: _search.text,
        visibleCount: _messages.length,
        limit: _messagePageSize,
      );
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _messages = page.messages;
        _selected = _messageFor(
          page.messages,
          _selected?.id,
          fallbackToFirst: false,
        );
        _hasMoreMessages = page.hasMore;
        _loadingMore = false;
      });
      _ensureSelectedMessageBody();
    } catch (error) {
      if (!_isCurrentMessageLoad(requestId)) return;
      setState(() {
        _loadingMore = false;
        _banner = 'Could not load more mail: $error';
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              session: _session,
              profile: _profile,
              banner: _banner,
              onShowPairingQr:
                  _pendingPairingPackage == null
                      ? null
                      : () => _showPairingQr(_pendingPairingPackage!),
              onRefresh: _loadMessages,
              onCheckUpdates: () => _checkUpdates(),
              onSettings: _showSettings,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 860) {
                    return _MobileInbox(
                      messages: _messages,
                      selected: _selected,
                      search: _search,
                      accounts: _accounts,
                      folders: _folders,
                      view: _view,
                      onViewChanged: _changeView,
                      onSearch: _reloadMessages,
                      onSelect: _openMobileMessage,
                      canLoadMore: _canLoadMore,
                      loadingMore: _loadingMore,
                      onLoadMore: _loadMoreMessages,
                    );
                  }
                  return Row(
                    children: [
                      _Sidebar(
                        accounts: _accounts,
                        folders: _folders,
                        view: _view,
                        onViewChanged: _changeView,
                        onDeleteAccount: _deleteMailbox,
                      ),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 390,
                        child: _MessageList(
                          key: ValueKey('desktop-${_view.key}-${_search.text}'),
                          messages: _messages,
                          selected: _selected,
                          search: _search,
                          onSearch: _reloadMessages,
                          onSelect: _selectMessage,
                          canLoadMore: _canLoadMore,
                          loadingMore: _loadingMore,
                          onLoadMore: _loadMoreMessages,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: _Reader(
                          message: _selected,
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
  }

  bool get _canLoadMore => _hasMoreMessages;

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
        _banner = 'Preparing local vault...';
      });
    }
    try {
      final profile = _profile ?? await widget.secureStore.readLocalProfile();
      if (profile == null) {
        if (mounted) {
          setState(() => _banner = 'Creating local vault...');
        }
        final created = await _createLocalVault();
        if (!mounted) return;
        setState(() => _vaultUnlocking = false);
        if (created == null) return;
        unawaited(_loadMessages());
        return;
      }
      _profile = profile;
      if (mounted) {
        setState(() => _banner = 'Unlocking local vault...');
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
      setState(() {
        _profile = profile;
        _vaultUnlocking = false;
        _banner = 'Local vault unlocked.';
      });
      unawaited(_loadMessages());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _vaultUnlocking = false;
        _banner = 'Could not unlock the local vault: $error';
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

  Future<void> _showSettings() async {
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
                  ),
            );
    if (!mounted || action == null) return;
    await _handleSettingsAction(action);
  }

  Future<void> _handleSettingsAction(_SettingsAction action) async {
    switch (action) {
      case _SettingsAction.syncAccount:
        await _showLogin();
      case _SettingsAction.compose:
        if (_accounts.isNotEmpty) await _showCompose();
      case _SettingsAction.addMailbox:
        await _showAddMailbox();
      case _SettingsAction.appThemeSettings:
        await _showAppThemeSettings();
      case _SettingsAction.localVaultSettings:
        await _showLocalVaultSettings();
      case _SettingsAction.mailSettings:
        await _showMailSettings();
      case _SettingsAction.oauthProviderSettings:
        await _showOAuthProviderSettings();
      case _SettingsAction.clearLocalData:
        await _clearLocalData();
      case _SettingsAction.devices:
        if (_session != null) await _showDevices();
      case _SettingsAction.receiveVaultShare:
        if (_session != null && !_claimingVaultShare) await _claimVaultShare();
      case _SettingsAction.showPairingQr:
        final pairingPackage = _pendingPairingPackage;
        if (pairingPackage != null) await _showPairingQr(pairingPackage);
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
      setState(() => _banner = error.toString());
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
          setState(() => _banner = 'Unlock the local vault first.');
          return;
        }
        final enabled = await _enableQuickUnlockForSecret(
          profile: profile,
          vaultSecret: vaultSecret,
        );
        if (!mounted) return;
        setState(
          () =>
              _banner =
                  enabled
                      ? 'System quick unlock is enabled for this device.'
                      : 'System quick unlock could not be enabled.',
        );
      case _LocalVaultSettingsAction.disableQuickUnlock:
        await widget.secureStore.clearQuickUnlockMaterial();
        if (!mounted) return;
        setState(() => _banner = 'System quick unlock is disabled.');
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
            outlookBuildClientId: widget.outlookOAuthClientId,
            outlookBuildClientSecret: widget.outlookOAuthClientSecret,
          ),
    );
    if (nextProviders == null || !mounted) return;

    final updatedDocument = document.copyWith(oauthProviders: nextProviders);
    try {
      final revision = await _saveLocalVaultDocument(
        profile: profile,
        document: updatedDocument,
      );
      await _applyVaultDocument(
        updatedDocument,
        revision: revision,
        loadMessages: false,
      );
      final synced = await _syncVaultRecordsWithServer(silent: true);
      if (!mounted) return;
      setState(
        () =>
            _banner =
                synced || _session == null
                    ? 'OAuth provider settings saved to the local encrypted vault.'
                    : 'OAuth provider settings saved locally. Sync will retry later.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _banner = 'Could not save OAuth provider settings: $error',
      );
    }
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
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _banner = 'Clearing local data...';
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
    if (!mounted) return;
    setState(() {
      _session = null;
      _profile = null;
      _draftCache = null;
      _vaultDocument = null;
      _vaultRevision = null;
      _vaultRecordRevision = null;
      _unlockedVaultSecret = null;
      _unlockedVaultPassword = null;
      _pendingPairingPackage = null;
      _view = view;
      _selectedAccountId = null;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = page.messages;
      _selected = _messageFor(page.messages, null);
      _banner = 'Local data cleared on this device.';
    });
    _ensureSelectedMessageBody();
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
      _banner =
          result.requiresApproval
              ? 'This device needs approval. Pair $pairingCode. Pairing package copied.'
              : result.recoveryCodes.isEmpty
              ? 'Sync connected as ${result.email}.'
              : 'Recovery codes created. Store them before closing this build.';
    });
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
          () => _banner = 'Sync connected, but record sync will retry later.',
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
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _banner = 'Leaving sync...';
      });
    }
    try {
      await widget.api.leaveSyncDevice(token: session.accessToken);
    } catch (error) {
      if (mounted) {
        setState(() => _banner = 'Could not leave sync: $error');
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
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingPairingPackage = null;
      _view = activeView;
      _selectedAccountId = activeView.folder?.accountId;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = page.messages;
      _selected = _messageFor(page.messages, _selected?.id);
      _banner = 'This device left sync. Local vault remains available.';
    });
    _ensureSelectedMessageBody();
  }

  Future<void> _signOut() async {
    _nextMessageLoadGeneration();
    _search.clear();
    if (mounted) {
      setState(() {
        _loadingMore = false;
        _banner = 'Signing out...';
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
    if (!mounted) return;
    setState(() {
      _session = null;
      _pendingPairingPackage = null;
      _view = view;
      _selectedAccountId = null;
      _hasMoreMessages = page.hasMore;
      _accounts = accounts;
      _folders = folders;
      _messages = page.messages;
      _selected = _messageFor(page.messages, null);
      _banner = 'Sync server disconnected. Local vault remains available.';
    });
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
            () =>
                _banner =
                    'Signed in, but this device could not consume its vault share.',
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
      final revision =
          profile == null
              ? vault.revision
              : await _saveLocalVaultDocument(
                profile: profile,
                document: document,
              );
      await _applyVaultDocument(
        document,
        revision: revision,
        loadMessages: false,
      );
      await _loadMessages();
    } catch (error) {
      _debugVault('login server vault unlock failed', error);
      if (!mounted) return;
      if (_hasUnlockedLocalVault) {
        setState(
          () => _banner = 'Signed in. Server vault sync will retry later.',
        );
        return;
      }
      setState(
        () => _banner = 'Signed in, but server vault could not be opened.',
      );
    }
  }

  Future<void> _claimVaultShare() async {
    final session = _session;
    if (session == null || _claimingVaultShare) return;
    setState(() {
      _claimingVaultShare = true;
      _banner = 'Checking for shared vault access...';
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
      setState(() {
        if (unlocked) _pendingPairingPackage = null;
        _banner =
            unlocked
                ? synced
                    ? 'Vault access received. Mailboxes are ready on this device.'
                    : 'Vault access received. Vault sync will retry later.'
                : 'No vault share is available for this device yet.';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _banner = 'Could not receive vault share: $error');
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
    final revision =
        profile == null
            ? vault.revision
            : await _saveLocalVaultDocument(
              profile: profile,
              document: document,
            );
    await _applyVaultDocument(
      document,
      revision: revision,
      loadMessages: false,
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

  Future<int> _saveLocalVaultDocument({
    required LocalProfile profile,
    required VaultDocument document,
  }) async {
    final vaultSecret = await _readUnlockedVaultSecret();
    final current = await widget.localVaultStore.read(profile.id);
    if (vaultSecret == null || vaultSecret.trim().isEmpty) {
      throw StateError('Local vault unlock material is not available.');
    }
    final expectedRevision = _vaultRevision ?? current?.revision ?? 0;
    final snapshot = await widget.localVaultStore.write(
      profileId: profile.id,
      expectedRevision: expectedRevision,
      blob: await widget.vaultCrypto.encryptDocument(
        document: document,
        email: profile.email,
        password: '',
        vaultSecret: vaultSecret,
      ),
    );
    await _saveLocalVaultRecords(
      profile: profile,
      document: document,
      vaultSecret: vaultSecret,
    );
    _vaultRevision = snapshot.revision;
    return snapshot.revision;
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
        setState(
          () =>
              _banner =
                  'Vault sync complete. Pushed ${result.pushed}, pulled ${result.pulled}$conflictText.',
        );
      }
      return true;
    } catch (error) {
      if (mounted && !silent) {
        setState(() => _banner = 'Vault sync could not complete: $error');
      }
      return false;
    }
  }

  Future<void> _showAddMailbox() async {
    final profile = await _ensureLocalProfile();
    if (profile == null) return;
    if (!mounted) return;
    final added = await showDialog<_AddMailboxResult>(
      context: context,
      builder:
          (context) => _AddMailboxDialog(
            document: _vaultDocument ?? VaultDocument.empty(),
            vaultCrypto: widget.vaultCrypto,
            oauthClient: widget.oauthClient,
            gmailOAuthClientId: widget.gmailOAuthClientId,
            gmailOAuthClientSecret: widget.gmailOAuthClientSecret,
            outlookOAuthClientId: widget.outlookOAuthClientId,
            outlookOAuthClientSecret: widget.outlookOAuthClientSecret,
          ),
    );
    if (added == null) return;
    final revision = await _saveLocalVaultDocument(
      profile: profile,
      document: added.document,
    );
    await _applyVaultDocument(added.document, revision: revision);
    final synced = await _syncVaultRecordsWithServer(silent: true);
    if (!mounted) return;
    setState(() {
      _banner =
          synced || _session == null
              ? '${added.mailbox.address} was added to the local encrypted vault.'
              : '${added.mailbox.address} was added locally. Sync will retry later.';
    });
  }

  Future<void> _deleteMailbox(MailAccount account) async {
    final profile = _profile;
    final session = _session;
    final document = _vaultDocument;
    final revision = _vaultRevision;
    if ((profile == null && session == null) ||
        document == null ||
        revision == null ||
        account.id == 'all') {
      setState(() => _banner = 'Mailbox account data is not available.');
      return;
    }
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
      final localProfile = profile ?? await _ensureLocalProfile();
      final localRevision =
          localProfile == null
              ? revision
              : await _saveLocalVaultDocument(
                profile: localProfile,
                document: updatedDocument,
              );
      await _applyVaultDocument(updatedDocument, revision: localRevision);
      final synced = await _syncVaultRecordsWithServer(silent: true);
      if (!mounted) return;
      setState(
        () =>
            _banner =
                synced || session == null
                    ? '${account.address} was removed from the local encrypted vault.'
                    : '${account.address} was removed locally. Sync will retry later.',
      );
    } catch (error) {
      if (mounted) {
        setState(() => _banner = 'Could not remove mailbox: $error');
      }
    }
  }

  Future<void> _applyVaultDocument(
    VaultDocument document, {
    int? revision,
    bool loadMessages = true,
  }) async {
    _vaultDocument = document;
    if (revision != null) {
      _vaultRevision = revision;
    }
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
    final accounts = await _mailRepository.accounts();
    final folders = await _mailRepository.folders();
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
    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _folders = folders;
      _view = activeView;
      _selectedAccountId = activeView.folder?.accountId;
      if (loadMessages) {
        _messages = page.messages;
        _selected = _messageFor(
          page.messages,
          _selected?.id,
          fallbackToFirst: false,
        );
        _hasMoreMessages = page.hasMore;
      }
    });
    if (requestId != null) {
      unawaited(
        _refreshMessagesInBackground(
          requestId: requestId,
          preserveSelection: false,
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
      backgroundIndexing: true,
    );
  }

  String? _activeCacheNamespace() {
    final profile = _profile;
    if (profile != null) return mailCacheNamespaceForUser(profile.id);
    final session = _session;
    if (session != null) return mailCacheNamespaceForUser(session.userId);
    return null;
  }

  Future<void> _refreshOAuthVaultIfNeeded() async {
    final profile = _profile;
    final session = _session;
    final document = _vaultDocument;
    final revision = _vaultRevision;
    final contextUserId = profile?.id ?? session?.userId;
    final contextSessionToken = session?.accessToken;
    bool isCurrentVaultContext() {
      final currentUserId = _profile?.id ?? _session?.userId;
      return mounted &&
          currentUserId == contextUserId &&
          _session?.accessToken == contextSessionToken &&
          identical(_vaultDocument, document);
    }

    if (_refreshingOAuth ||
        document == null ||
        revision == null ||
        (profile == null && session == null)) {
      return;
    }
    _refreshingOAuth = true;
    try {
      final result = await OAuthVaultRefresher(
        refreshTokens: widget.oauthClient.refresh,
      ).refreshExpiring(
        document: document,
        clientIdForProvider: _oauthClientIdForProvider,
        clientSecretForProvider: _oauthClientSecretForProvider,
      );
      if (!isCurrentVaultContext()) return;
      if (result.changed) {
        final localProfile = profile ?? await _ensureLocalProfile();
        if (!isCurrentVaultContext()) return;
        final int nextRevision;
        if (localProfile != null) {
          nextRevision = await _saveLocalVaultDocument(
            profile: localProfile,
            document: result.document,
          );
        } else {
          nextRevision = revision;
        }
        if (!isCurrentVaultContext()) return;
        await _applyVaultDocument(
          result.document,
          revision: nextRevision,
          loadMessages: false,
        );
        await _syncVaultRecordsWithServer(silent: true);
      }
      if (result.failures.isNotEmpty && isCurrentVaultContext()) {
        final first = result.failures.first;
        setState(
          () => _banner = 'OAuth token refresh failed for ${first.address}.',
        );
      }
    } catch (error) {
      if (isCurrentVaultContext()) {
        setState(() => _banner = 'OAuth token refresh failed: $error');
      }
    } finally {
      _refreshingOAuth = false;
    }
  }

  String _oauthClientIdForProvider(String provider) {
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    final vaultClientId = vaultConfig?.clientId.trim() ?? '';
    if (vaultClientId.isNotEmpty) return vaultClientId;
    return switch (provider) {
      'gmail' => widget.gmailOAuthClientId.trim(),
      'outlook' => widget.outlookOAuthClientId.trim(),
      _ => '',
    };
  }

  String _oauthClientSecretForProvider(String provider) {
    final vaultConfig = _vaultDocument?.oauthProviderFor(provider);
    if (vaultConfig?.clientId.trim().isNotEmpty == true) {
      return vaultConfig!.clientSecret.trim();
    }
    return switch (provider) {
      'gmail' => widget.gmailOAuthClientSecret.trim(),
      'outlook' => widget.outlookOAuthClientSecret.trim(),
      _ => '',
    };
  }

  Future<void> _sendReply(
    MailMessage message,
    String textBody, {
    String htmlBody = '',
  }) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.sendReply(
      original: message,
      textBody: textBody,
      htmlBody: htmlBody,
    );
    if (!mounted) return;
    setState(() => _banner = 'Reply sent.');
  }

  Future<void> _sendReplyAll(
    MailMessage message,
    String textBody, {
    String htmlBody = '',
  }) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.sendReplyAll(
      original: message,
      textBody: textBody,
      htmlBody: htmlBody,
    );
    if (!mounted) return;
    setState(() => _banner = 'Reply all sent.');
  }

  Future<void> _showCompose() async {
    if (_accounts.isEmpty) return;
    final draft = await _draftCache?.loadComposeDraft();
    if (!mounted) return;
    if (draft != null) {
      setState(() => _banner = 'Local draft restored.');
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
            onDraftChanged: _saveComposeDraft,
            onSend: _sendMessage,
          ),
    );
    if (sent == true) {
      await _draftCache?.deleteComposeDraft();
      if (!mounted) return;
      setState(() => _banner = 'Message sent.');
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
      setState(() => _banner = 'Message forwarded.');
    }
  }

  Future<void> _showDevices() async {
    final session = _session;
    if (session == null) return;
    final vaultSecret = await _readUnlockedVaultSecret();
    if (!mounted) return;
    if (vaultSecret == null || vaultSecret.trim().isEmpty) {
      if (mounted) {
        setState(() => _banner = 'Unlock the local vault before sharing it.');
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
      setState(() => _banner = result);
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

  void _selectMessage(MailMessage message) {
    setState(() => _selected = message);
    unawaited(_ensureMessageBody(message));
  }

  void _ensureSelectedMessageBody() {
    final selected = _selected;
    if (selected != null) {
      unawaited(_ensureMessageBody(selected));
    }
  }

  Future<MailMessage?> _ensureMessageBody(MailMessage message) async {
    if (message.bodyLoaded) return message;
    try {
      await _refreshOAuthVaultIfNeeded();
      final loaded = await _mailRepository.loadMessageBody(message);
      if (!mounted) return loaded;
      _replaceMessage(loaded);
      return loaded;
    } catch (error) {
      if (mounted) {
        setState(() => _banner = 'Could not load message body: $error');
      }
      return null;
    }
  }

  Future<void> _openMobileMessage(MailMessage message) async {
    setState(() => _selected = message);
    final notifier = ValueNotifier<MailMessage>(message);
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
      notifier.dispose();
    }
  }

  Future<void> _setRead(MailMessage message, bool read) async {
    await _refreshOAuthVaultIfNeeded();
    final updated = await _mailRepository.setRead(message: message, read: read);
    if (!mounted) return;
    _replaceMessage(updated);
  }

  Future<void> _setStarred(MailMessage message, bool starred) async {
    await _refreshOAuthVaultIfNeeded();
    final updated = await _mailRepository.setStarred(
      message: message,
      starred: starred,
    );
    if (!mounted) return;
    _replaceMessage(updated);
  }

  Future<void> _archiveMessage(MailMessage message) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.archive(message);
    if (!mounted) return;
    _removeMessage(message.id, 'Message archived.');
  }

  Future<void> _deleteMessage(MailMessage message) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.delete(message);
    if (!mounted) return;
    _removeMessage(message.id, 'Message moved to trash.');
  }

  Future<void> _moveToInboxMessage(MailMessage message) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.moveToInbox(message);
    if (!mounted) return;
    _removeMessage(message.id, 'Message moved to inbox.');
  }

  Future<void> _moveMessageToMailbox(
    MailMessage message,
    MailboxKind destination,
  ) async {
    await _refreshOAuthVaultIfNeeded();
    await _mailRepository.moveToMailbox(
      message: message,
      destination: destination,
    );
    if (!mounted) return;
    _removeMessage(
      message.id,
      'Message moved to ${_labelForMailbox(destination)}.',
    );
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
    setState(() => _banner = 'Attachment downloaded: ${file.path}');
  }

  void _replaceMessage(MailMessage updated) {
    setState(() {
      _messages = [
        for (final message in _messages)
          if (message.id == updated.id) updated else message,
      ];
      if (_selected?.id == updated.id) {
        _selected = updated;
      }
    });
  }

  void _removeMessage(String messageId, String banner) {
    setState(() {
      _messages =
          _messages.where((message) => message.id != messageId).toList();
      _selected = _messageFor(_messages, _selected?.id);
      _banner = banner;
    });
    _ensureSelectedMessageBody();
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
    required this.banner,
    required this.onShowPairingQr,
    required this.onRefresh,
    required this.onCheckUpdates,
    required this.onSettings,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final String? banner;
  final VoidCallback? onShowPairingQr;
  final VoidCallback onRefresh;
  final VoidCallback onCheckUpdates;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              compact ? _compactRow(context) : _wideRow(context),
              if (banner != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            banner!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        if (onShowPairingQr != null)
                          IconButton(
                            tooltip: 'Show pairing QR',
                            onPressed: onShowPairingQr,
                            icon: const Icon(Icons.qr_code_2),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _wideRow(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.mail_lock_outlined),
        const SizedBox(width: 10),
        Text('NyaMail', style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        IconButton(
          tooltip: 'Refresh mail',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Check for updates',
          onPressed: onCheckUpdates,
          icon: const Icon(Icons.system_update_alt),
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
        const Icon(Icons.mail_lock_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            session?.email ?? profile?.label ?? 'NyaMail',
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          tooltip: 'Refresh mail',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Check for updates',
          onPressed: onCheckUpdates,
          icon: const Icon(Icons.system_update_alt),
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

enum _SettingsAction {
  syncAccount,
  compose,
  addMailbox,
  appThemeSettings,
  localVaultSettings,
  mailSettings,
  oauthProviderSettings,
  clearLocalData,
  devices,
  receiveVaultShare,
  showPairingQr,
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;

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
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;

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
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final spacing = compact ? 20.0 : 18.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSection(
          title: 'Sync',
          children: [
            _SettingsTile(
              action: _SettingsAction.syncAccount,
              icon:
                  session == null ? Icons.login : Icons.verified_user_outlined,
              title: session == null ? 'Sync account' : session!.email,
              subtitle: session == null ? 'Not signed in' : 'Signed in',
            ),
            _SettingsTile(
              action: _SettingsAction.devices,
              icon: Icons.devices_outlined,
              title: 'Devices',
              subtitle: session == null ? 'Sign in to manage devices' : null,
              enabled: session != null,
            ),
            _SettingsTile(
              action: _SettingsAction.receiveVaultShare,
              icon: Icons.cloud_download_outlined,
              title:
                  claimingVaultShare
                      ? 'Receiving vault share'
                      : 'Receive vault share',
              subtitle: session == null ? 'Sign in on this device first' : null,
              enabled: session != null && !claimingVaultShare,
              progress: claimingVaultShare,
            ),
            _SettingsTile(
              action: _SettingsAction.showPairingQr,
              icon: Icons.qr_code_2,
              title: 'Show pairing QR',
              subtitle: hasPendingPairingQr ? null : 'No pending pairing code',
              enabled: hasPendingPairingQr,
            ),
          ],
        ),
        SizedBox(height: spacing),
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
              action: _SettingsAction.oauthProviderSettings,
              icon: Icons.vpn_key_outlined,
              title: 'OAuth providers',
            ),
            _SettingsTile(
              action: _SettingsAction.compose,
              icon: Icons.edit_outlined,
              title: 'Compose',
              subtitle: accountCount == 0 ? 'Add a mailbox first' : null,
              enabled: accountCount > 0,
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
      ],
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
    this.progress = false,
    this.destructive = false,
  });

  final _SettingsAction action;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool enabled;
  final bool progress;
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
        leading:
            progress
                ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : Icon(icon, color: enabled ? foreground : secondary),
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

enum _MessageAppearanceAction { useSetting, automatic, light, dark }

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.accounts,
    required this.folders,
    required this.view,
    required this.onViewChanged,
    required this.onDeleteAccount,
  });

  final List<MailAccount> accounts;
  final List<MailFolder> folders;
  final MailboxView view;
  final ValueChanged<MailboxView> onViewChanged;
  final ValueChanged<MailAccount> onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('Smart Folders', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          for (final item in MailSmartFolder.values)
            ListTile(
              selected: view.smartFolder == item,
              leading: Icon(_iconForSmartFolder(item)),
              title: Text(_labelForSmartFolder(item)),
              dense: true,
              onTap: () => onViewChanged(MailboxView.smart(item)),
            ),
          const SizedBox(height: 18),
          Text('Accounts', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          for (final account in accounts)
            ExpansionTile(
              initiallyExpanded:
                  view.folder?.accountId == account.id || accounts.length == 1,
              leading: const Icon(Icons.alternate_email),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (account.id != 'all')
                    IconButton(
                      tooltip: 'Remove mailbox',
                      onPressed: () => onDeleteAccount(account),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
              subtitle: Text(
                account.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                for (final folder in _foldersForAccount(folders, account.id))
                  Builder(
                    builder: (context) {
                      final folderPathLabel = folder.effectiveDisplayPath;
                      return ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 56,
                          right: 12,
                        ),
                        selected: view.folder?.key == folder.key,
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
                        onTap: () => onViewChanged(MailboxView.folder(folder)),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MessageList extends StatefulWidget {
  const _MessageList({
    super.key,
    required this.messages,
    required this.selected,
    required this.search,
    required this.onSearch,
    required this.onSelect,
    required this.canLoadMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<MailMessage> messages;
  final MailMessage? selected;
  final TextEditingController search;
  final VoidCallback onSearch;
  final ValueChanged<MailMessage> onSelect;
  final bool canLoadMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  static const _loadMoreThreshold = 480.0;

  final _scrollController = ScrollController();
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
    if (oldWidget.messages.length != widget.messages.length ||
        oldWidget.canLoadMore != widget.canLoadMore ||
        oldWidget.loadingMore != widget.loadingMore) {
      if (oldWidget.messages.length != widget.messages.length ||
          !widget.canLoadMore) {
        _lastAutoLoadMessageCount = null;
      }
      _scheduleViewportCheck();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadMore);
    _scrollController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SearchBar(
            controller: widget.search,
            hintText: 'Search mail',
            leading: const Icon(Icons.search),
            onSubmitted: (_) => widget.onSearch(),
          ),
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
                  onLoadMore: widget.onLoadMore,
                );
              }
              final message = widget.messages[index];
              return ListTile(
                selected: widget.selected?.id == message.id,
                title: Text(
                  message.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight:
                        message.read ? FontWeight.w500 : FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${message.from} - ${message.preview}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(
                  message.hasAttachments
                      ? Icons.attach_file
                      : Icons.chevron_right,
                  size: 18,
                ),
                onTap: () => widget.onSelect(message),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MessageListFooter extends StatelessWidget {
  const _MessageListFooter({
    required this.isEmpty,
    required this.canLoadMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final bool isEmpty;
  final bool canLoadMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelMedium;
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text(
          isEmpty ? 'No messages' : 'No more mail',
          style: labelStyle,
        ),
      ),
    );
  }
}

class _Reader extends StatelessWidget {
  const _Reader({
    required this.message,
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
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
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
      return const Center(child: Text('Select a message'));
    }
    return _ReaderBody(
      message: message,
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
    _to.addListener(_scheduleDraftSave);
    _cc.addListener(_scheduleDraftSave);
    _bcc.addListener(_scheduleDraftSave);
    _subject.addListener(_scheduleDraftSave);
    _body.addListener(_scheduleDraftSave);
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
                    child: Text('${account.displayName} <${account.address}>'),
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
            const SizedBox(height: 10),
            TextField(
              controller: _subject,
              decoration: const InputDecoration(labelText: 'Subject'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _body,
              minLines: 8,
              maxLines: 12,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
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

  void _scheduleDraftSave() {
    if (widget.onDraftChanged == null || _sending) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_saveDraftNow());
    });
  }

  Future<void> _saveDraftNow() async {
    final onDraftChanged = widget.onDraftChanged;
    if (onDraftChanged == null) return;
    try {
      await onDraftChanged(
        MailDraft(
          accountId: _accountId,
          to: _to.text,
          cc: _cc.text,
          bcc: _bcc.text,
          subject: _subject.text,
          body: _body.text,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      // Draft persistence is a local convenience and must not block sending.
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

  Future<void> _cancel() async {
    _draftSaveTimer?.cancel();
    await _saveDraftNow();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _send() async {
    if ((_to.text.trim().isEmpty &&
            _cc.text.trim().isEmpty &&
            _bcc.text.trim().isEmpty) ||
        _body.text.trim().isEmpty) {
      setState(() => _error = 'Recipient and message are required.');
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
        textBody: _body.text.trim(),
        htmlBody: '',
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
}

class _ReaderBody extends StatefulWidget {
  const _ReaderBody({
    required this.message,
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
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
  })
  onSendReply;
  final Future<void> Function(
    MailMessage message,
    String textBody, {
    String htmlBody,
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final canReplyAll =
        message.to.isNotEmpty ||
        message.cc.isNotEmpty ||
        message.replyTo.isNotEmpty;
    final moveDestinations = standardMailboxKinds
        .where((kind) => kind != message.mailbox)
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
    final rendered = buildMailHtmlDocument(
      htmlBody: message.htmlBody,
      textBody: message.body.isEmpty ? message.preview : message.body,
      policy: renderPolicy,
    );
    final title = Text(
      message.subject,
      style: Theme.of(context).textTheme.headlineSmall,
      maxLines: widget.mobileFullScreen ? 3 : 2,
      overflow: TextOverflow.ellipsis,
    );
    final actionButtons = <Widget>[
      if (_canMoveToInbox(message.mailbox))
        IconButton(
          tooltip: 'Move to Inbox',
          onPressed: _acting ? null : () => _runAction(widget.onMoveToInbox),
          icon: const Icon(Icons.move_to_inbox_outlined),
        )
      else
        IconButton(
          tooltip: 'Archive',
          onPressed: _acting ? null : () => _runAction(widget.onArchive),
          icon: const Icon(Icons.archive_outlined),
        ),
      PopupMenuButton<MailboxKind>(
        tooltip: 'Move to...',
        enabled: !_acting && moveDestinations.isNotEmpty,
        icon: const Icon(Icons.drive_file_move_outlined),
        onSelected:
            (destination) => _runAction(
              (message) => widget.onMoveToMailbox(message, destination),
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
        tooltip: 'Delete',
        onPressed: _acting ? null : () => _runAction(widget.onDelete),
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
            : Row(children: [Expanded(child: title), ...actionButtons]);
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
        );
      } else {
        await widget.onSendReply(
          widget.message,
          result.textBody,
          htmlBody: result.htmlBody,
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
    Future<void> Function(MailMessage message) action,
  ) async {
    setState(() {
      _acting = true;
      _error = null;
    });
    try {
      await action(widget.message);
      if (mounted) setState(() => _acting = false);
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
  const _ReplyComposerResult({required this.textBody, required this.htmlBody});

  final String textBody;
  final String htmlBody;
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
                onPressed:
                    _finishing ? null : () => Navigator.of(context).pop(),
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
              onPressed: _finishing ? null : () => Navigator.of(context).pop(),
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
              onPressed: _finishing ? null : () => Navigator.of(context).pop(),
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

  Future<void> _finish() async {
    setState(() {
      _finishing = true;
      _error = null;
    });
    try {
      final result = await _currentContent();
      if (result.textBody.trim().isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'Reply cannot be empty.';
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

  Future<_ReplyComposerResult> _currentContent() async {
    if (!_supportsReplyRichEditor) {
      final text = _plainText.text.trim();
      return _ReplyComposerResult(
        textBody: text,
        htmlBody: _plainTextToOutgoingHtml(text),
      );
    }
    final controller = _webController;
    if (controller == null || !_editorReady) {
      return const _ReplyComposerResult(textBody: '', htmlBody: '');
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

String _replyEditorHtml({required bool dark}) {
  final background = dark ? '#111315' : '#FFFFFF';
  final text = dark ? '#E8EAED' : '#202124';
  final caret = dark ? '#8AB4F8' : '#0B57D0';
  final placeholder = dark ? '#9AA0A6' : '#5F6368';
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
  content: "Write a reply";
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
    required this.accounts,
    required this.folders,
    required this.view,
    required this.onViewChanged,
    required this.onSearch,
    required this.onSelect,
    required this.canLoadMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<MailMessage> messages;
  final MailMessage? selected;
  final TextEditingController search;
  final List<MailAccount> accounts;
  final List<MailFolder> folders;
  final MailboxView view;
  final ValueChanged<MailboxView> onViewChanged;
  final VoidCallback onSearch;
  final ValueChanged<MailMessage> onSelect;
  final bool canLoadMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 54,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final folder in MailSmartFolder.values)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: ChoiceChip(
                    selected: view.smartFolder == folder,
                    label: Text(_labelForSmartFolder(folder)),
                    onSelected: (_) => onViewChanged(MailboxView.smart(folder)),
                  ),
                ),
            ],
          ),
        ),
        if (folders.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final account in accounts)
                  for (final folder in _foldersForAccount(folders, account.id))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: ChoiceChip(
                        selected: view.folder?.key == folder.key,
                        avatar: Icon(_iconForMailbox(folder.kind), size: 16),
                        label: Text(
                          '${account.displayName} / ${folder.displayName}',
                        ),
                        onSelected:
                            (_) => onViewChanged(MailboxView.folder(folder)),
                      ),
                    ),
              ],
            ),
          ),
        Expanded(
          child: _MessageList(
            key: ValueKey('mobile-${view.key}-${search.text}'),
            messages: messages,
            selected: selected,
            search: search,
            onSearch: onSearch,
            onSelect: onSelect,
            canLoadMore: canLoadMore,
            loadingMore: loadingMore,
            onLoadMore: onLoadMore,
          ),
        ),
      ],
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
  });

  final String title;
  final String message;
  final bool confirmPassword;

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
              decoration: const InputDecoration(labelText: 'Vault password'),
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
        FilledButton(onPressed: _submit, child: const Text('Continue')),
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
    required this.outlookBuildClientId,
    required this.outlookBuildClientSecret,
  });

  final List<VaultOAuthProviderConfig> providers;
  final String gmailBuildClientId;
  final String gmailBuildClientSecret;
  final String outlookBuildClientId;
  final String outlookBuildClientSecret;

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

class _OAuthProviderSettingsDialogState
    extends State<_OAuthProviderSettingsDialog> {
  late final TextEditingController _gmailClientId;
  late final TextEditingController _gmailClientSecret;
  late final TextEditingController _outlookClientId;
  late final TextEditingController _outlookClientSecret;
  late final List<VaultOAuthProviderConfig> _extraProviders;
  bool _showGmailSecret = false;
  bool _showOutlookSecret = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final gmail = _provider('gmail');
    final outlook = _provider('outlook');
    _gmailClientId = TextEditingController(text: gmail?.clientId ?? '');
    _gmailClientSecret = TextEditingController(text: gmail?.clientSecret ?? '');
    _outlookClientId = TextEditingController(text: outlook?.clientId ?? '');
    _outlookClientSecret = TextEditingController(
      text: outlook?.clientSecret ?? '',
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
    _outlookClientId.dispose();
    _outlookClientSecret.dispose();
    super.dispose();
  }

  VaultOAuthProviderConfig? _provider(String provider) {
    final normalized = normalizeOAuthProviderKey(provider);
    for (final item in widget.providers) {
      if (item.provider == normalized) return item;
    }
    return null;
  }

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
              showSecret: _showGmailSecret,
              buildClientId: widget.gmailBuildClientId,
              buildClientSecret: widget.gmailBuildClientSecret,
              onToggleSecret:
                  () => setState(() => _showGmailSecret = !_showGmailSecret),
            ),
            const Divider(height: 28),
            _providerFields(
              provider: 'outlook',
              title: 'Outlook',
              icon: Icons.business_center_outlined,
              clientId: _outlookClientId,
              clientSecret: _outlookClientSecret,
              showSecret: _showOutlookSecret,
              buildClientId: widget.outlookBuildClientId,
              buildClientSecret: widget.outlookBuildClientSecret,
              onToggleSecret:
                  () =>
                      setState(() => _showOutlookSecret = !_showOutlookSecret),
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
    required bool showSecret,
    required String buildClientId,
    required String buildClientSecret,
    required VoidCallback onToggleSecret,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
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
              message: _fallbackStatus(buildClientId, buildClientSecret),
              child: Icon(
                buildClientId.trim().isEmpty
                    ? Icons.settings_outlined
                    : Icons.check_circle_outline,
                color:
                    buildClientId.trim().isEmpty
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.primary,
                size: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: clientId,
          keyboardType: TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Client ID',
            hintText: _clientIdHint(provider),
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
            labelText: 'Client secret',
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
            'Build fallback: ${_fallbackStatus(buildClientId, buildClientSecret)}',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
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

  String _fallbackStatus(String clientId, String clientSecret) {
    final hasClientId = clientId.trim().isNotEmpty;
    final hasSecret = clientSecret.trim().isNotEmpty;
    if (hasClientId && hasSecret) return 'client id and secret configured';
    if (hasClientId) return 'client id configured';
    return 'not configured';
  }

  void _save() {
    _error = null;
    final providers = [..._extraProviders];
    final gmail = _configFromFields(
      provider: 'gmail',
      clientId: _gmailClientId.text,
      clientSecret: _gmailClientSecret.text,
    );
    if (_error != null) return;
    final outlook = _configFromFields(
      provider: 'outlook',
      clientId: _outlookClientId.text,
      clientSecret: _outlookClientSecret.text,
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
  }) {
    final id = clientId.trim();
    final secret = clientSecret.trim();
    if (id.isEmpty && secret.isEmpty) return null;
    if (id.isEmpty) {
      setState(
        () => _error = 'Client ID is required when a client secret is set.',
      );
      return null;
    }
    return VaultOAuthProviderConfig(
      provider: provider,
      clientId: id,
      clientSecret: secret,
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

class _AddMailboxDialog extends StatefulWidget {
  const _AddMailboxDialog({
    required this.document,
    required this.vaultCrypto,
    required this.oauthClient,
    required this.gmailOAuthClientId,
    required this.gmailOAuthClientSecret,
    required this.outlookOAuthClientId,
    required this.outlookOAuthClientSecret,
  });

  final VaultDocument document;
  final VaultCrypto vaultCrypto;
  final OAuthLoopbackClient oauthClient;
  final String gmailOAuthClientId;
  final String gmailOAuthClientSecret;
  final String outlookOAuthClientId;
  final String outlookOAuthClientSecret;

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
  MailboxCredential? _pendingCredential;

  @override
  void initState() {
    super.initState();
    _address.addListener(_prefillHosts);
  }

  @override
  void dispose() {
    _address.removeListener(_prefillHosts);
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
              decoration: const InputDecoration(labelText: 'Username'),
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
                setState(() => _provider = value ?? 'imap');
                _applyProviderPreset();
              },
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'app_password',
                  icon: Icon(Icons.key_outlined),
                  label: Text('Password'),
                ),
                ButtonSegment(
                  value: 'oauth',
                  icon: Icon(Icons.open_in_browser),
                  label: Text('OAuth'),
                ),
              ],
              selected: {_authMode},
              onSelectionChanged: (values) {
                setState(() => _authMode = values.single);
              },
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
                        _provider == 'gmail' &&
                        _oauthClientSecretForProvider(_provider).isEmpty;
                    return Text(
                      clientIdMissing
                          ? 'OAuth client id is not configured for this provider.'
                          : clientSecretMissing
                          ? 'Google Desktop OAuth may require the client secret from Google Cloud.'
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
      final oauthProvider = oauthProviderConfig(_provider);
      final vaultItemId = widget.vaultCrypto.newVaultItemId(address);
      final tokenSet = await widget.oauthClient.authorize(
        provider: oauthProvider,
        clientId: clientId,
        clientSecret: _oauthClientSecretForProvider(_provider),
        loginHint: address,
      );
      final item = oauthMailboxItem(
        id: vaultItemId,
        address: address,
        displayName: _displayName.text.trim(),
        provider: oauthProvider,
        tokenSet: tokenSet,
      );
      final credential = item.toCredential();
      _pendingCredential = credential;
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
        _username.text.trim().isEmpty ? address : _username.text.trim();
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
    final parts = _address.text.trim().split('@');
    if (parts.length != 2 || parts.last.isEmpty) return;
    if (_username.text.isEmpty) {
      _username.text = _address.text.trim();
    }
    _applyProviderPreset();
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
    final vaultClientId = vaultConfig?.clientId.trim() ?? '';
    if (vaultClientId.isNotEmpty) return vaultClientId;
    return switch (provider) {
      'gmail' => widget.gmailOAuthClientId.trim(),
      'outlook' => widget.outlookOAuthClientId.trim(),
      _ => '',
    };
  }

  String _oauthClientSecretForProvider(String provider) {
    final vaultConfig = widget.document.oauthProviderFor(provider);
    if (vaultConfig?.clientId.trim().isNotEmpty == true) {
      return vaultConfig!.clientSecret.trim();
    }
    return switch (provider) {
      'gmail' => widget.gmailOAuthClientSecret.trim(),
      'outlook' => widget.outlookOAuthClientSecret.trim(),
      _ => '',
    };
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

bool _canMoveToInbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.archive ||
    MailboxKind.spam ||
    MailboxKind.trash ||
    MailboxKind.custom => true,
    MailboxKind.inbox || MailboxKind.sent || MailboxKind.drafts => false,
  };
}

IconData _iconForSmartFolder(MailSmartFolder folder) {
  return switch (folder) {
    MailSmartFolder.allIncoming => Icons.all_inbox_outlined,
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
    MailSmartFolder.inbox => 'Inbox',
    MailSmartFolder.sent => 'Sent',
    MailSmartFolder.drafts => 'Drafts',
    MailSmartFolder.archive => 'Archive',
    MailSmartFolder.spam => 'Spam',
    MailSmartFolder.trash => 'Trash',
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
