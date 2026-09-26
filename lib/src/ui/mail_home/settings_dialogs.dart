part of '../mail_home_page.dart';

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
