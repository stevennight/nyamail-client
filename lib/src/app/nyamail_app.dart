import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/nyamail_api.dart';
import '../mail/mail_cache.dart';
import '../mail/mail_repository.dart';
import '../mail/mail_transport.dart';
import '../oauth/oauth_loopback_client.dart';
import '../release/release_service.dart';
import '../release/release_verifier.dart';
import '../security/local_secure_store.dart';
import '../security/local_vault_record_store.dart';
import '../security/local_vault_sync_state_store.dart';
import '../security/local_vault_store.dart';
import '../security/vault_crypto.dart';
import '../security/vault_record_crypto.dart';
import '../ui/mail_home_page.dart';
import 'app_config.dart';
import 'app_theme_settings.dart';

class NyaMailApp extends StatefulWidget {
  const NyaMailApp({super.key});

  @override
  State<NyaMailApp> createState() => _NyaMailAppState();
}

class _NyaMailAppState extends State<NyaMailApp> {
  late final AppConfig _config = AppConfig.fromEnvironment();
  late final LocalSecureStore _secureStore = LocalSecureStore();
  String? _apiBaseUrl;
  AppThemeSetting _themeSetting = AppThemeSetting.system;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAppState();
  }

  Future<void> _loadAppState() async {
    final savedApiBaseUrl = await _secureStore.readApiBaseUrl();
    final themeSetting = await const AppThemeSettingsStore().load();
    if (!mounted) return;
    setState(() {
      _apiBaseUrl =
          _normalizedApiBaseUrl(savedApiBaseUrl) ??
          _normalizedApiBaseUrl(_config.apiBaseUrl) ??
          'http://localhost:8080';
      _themeSetting = themeSetting;
      _loading = false;
    });
  }

  Future<void> _setApiBaseUrl(String value) async {
    final normalized = _normalizedApiBaseUrl(value);
    if (normalized == null) {
      throw ArgumentError('Server URL must be an absolute HTTP or HTTPS URL.');
    }
    await _secureStore.saveApiBaseUrl(normalized);
    if (!mounted) return;
    setState(() => _apiBaseUrl = normalized);
  }

  Future<void> _setThemeSetting(AppThemeSetting setting) async {
    await const AppThemeSettingsStore().save(setting);
    if (!mounted) return;
    setState(() => _themeSetting = setting);
  }

  @override
  Widget build(BuildContext context) {
    final apiBaseUrl = _apiBaseUrl;
    final api = apiBaseUrl == null ? null : NyaMailApi(baseUrl: apiBaseUrl);
    return MaterialApp(
      title: 'NyaMail',
      debugShowCheckedModeBanner: false,
      themeMode: _themeSetting.themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF277E7A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF56A3A6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
      ),
      home:
          _loading || api == null || apiBaseUrl == null
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : MailHomePage(
                key: ValueKey(apiBaseUrl),
                api: api,
                apiBaseUrl: apiBaseUrl,
                defaultApiBaseUrl: _config.apiBaseUrl,
                onApiBaseUrlChanged: _setApiBaseUrl,
                appThemeSetting: _themeSetting,
                onAppThemeSettingChanged: _setThemeSetting,
                releaseService: ReleaseService(
                  api: api,
                  channel: _config.releaseChannel,
                  verifier: ReleaseVerifier(
                    publicKey: _config.releasePublicKey,
                  ),
                ),
                secureStore: _secureStore,
                localVaultStore: const LocalVaultStore(),
                localVaultRecordStore: const LocalVaultRecordStore(),
                localVaultSyncStateStore: const LocalVaultSyncStateStore(),
                vaultCrypto: const VaultCrypto(),
                vaultRecordCrypto: const VaultRecordCrypto(),
                oauthClient: OAuthLoopbackClient(
                  openAuthorizationUrl: _openAuthorizationUrl,
                ),
                gmailOAuthClientId: _config.gmailOAuthClientId,
                gmailOAuthClientSecret: _config.gmailOAuthClientSecret,
                outlookOAuthClientId: _config.outlookOAuthClientId,
                outlookOAuthClientSecret: _config.outlookOAuthClientSecret,
                mailRepository: const CachedTransportMailRepository(
                  cache: MailCache(),
                  transport: SocketMailTransport(),
                ),
              ),
    );
  }
}

String? _normalizedApiBaseUrl(String? value) {
  final trimmed = value?.trim() ?? '';
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
  final normalizedPath =
      uri.path.endsWith('/') && uri.path.length > 1
          ? uri.path.replaceFirst(RegExp(r'/+$'), '')
          : uri.path;
  return uri
      .replace(path: normalizedPath)
      .toString()
      .replaceFirst(RegExp(r'/+$'), '');
}

Future<void> _openAuthorizationUrl(Uri uri) async {
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw OAuthLoopbackException('Could not open OAuth authorization URL.');
  }
}
