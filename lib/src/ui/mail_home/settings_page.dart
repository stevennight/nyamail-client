part of '../mail_home_page.dart';

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
  about,
  clearLocalData,
  exportVault,
  importVault,
  devices,
  receiveVaultShare,
  showPairingQr,
}

typedef _SettingsActionHandler =
    Future<_SettingsActionResult> Function(_SettingsAction action);

class _SettingsActionResult {
  const _SettingsActionResult({required this.keepOpen, this.feedback});

  final bool keepOpen;
  final _SettingsFeedback? feedback;
}

class _SettingsFeedback {
  const _SettingsFeedback({
    required this.message,
    this.kind = _NoticeKind.success,
  });

  final String message;
  final _NoticeKind kind;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
    required this.onAction,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final _SettingsActionHandler onAction;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  _SettingsFeedback? _feedback;

  Future<void> _handleAction(_SettingsAction action) async {
    final result = await widget.onAction(action);
    if (!mounted) return;
    setState(() => _feedback = result.feedback);
    if (!result.keepOpen) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: _DialogContent(
        width: 560,
        maxHeight: 680,
        child: _SettingsContent(
          session: widget.session,
          profile: widget.profile,
          accountCount: widget.accountCount,
          claimingVaultShare: widget.claimingVaultShare,
          hasPendingPairingQr: widget.hasPendingPairingQr,
          feedback: _feedback,
          onAction: _handleAction,
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

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({
    required this.session,
    required this.profile,
    required this.accountCount,
    required this.claimingVaultShare,
    required this.hasPendingPairingQr,
    required this.onAction,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final _SettingsActionHandler onAction;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  _SettingsFeedback? _feedback;

  Future<void> _handleAction(_SettingsAction action) async {
    final result = await widget.onAction(action);
    if (!mounted) return;
    setState(() => _feedback = result.feedback);
    if (!result.keepOpen) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SettingsContent(
              session: widget.session,
              profile: widget.profile,
              accountCount: widget.accountCount,
              claimingVaultShare: widget.claimingVaultShare,
              hasPendingPairingQr: widget.hasPendingPairingQr,
              feedback: _feedback,
              onAction: _handleAction,
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
    required this.onAction,
    this.feedback,
  });

  final LocalSession? session;
  final LocalProfile? profile;
  final int accountCount;
  final bool claimingVaultShare;
  final bool hasPendingPairingQr;
  final bool compact;
  final Future<void> Function(_SettingsAction action) onAction;
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
              onAction: onAction,
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
              onAction: onAction,
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
              onAction: onAction,
              icon: Icons.cleaning_services_outlined,
              title: 'Clear mail cache',
              subtitle: 'Re-fetch messages and rebuild local index',
            ),
            _SettingsTile(
              action: _SettingsAction.oauthProviderSettings,
              onAction: onAction,
              icon: Icons.vpn_key_outlined,
              title: 'OAuth providers',
            ),
            _SettingsTile(
              action: _SettingsAction.checkUpdates,
              onAction: onAction,
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
              onAction: onAction,
              icon: Icons.palette_outlined,
              title: 'App appearance',
            ),
            _SettingsTile(
              action: _SettingsAction.mailSettings,
              onAction: onAction,
              icon: Icons.tune,
              title: 'Mail rendering',
            ),
            _SettingsTile(
              action: _SettingsAction.mailInteractionSettings,
              onAction: onAction,
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
              onAction: onAction,
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
              onAction: onAction,
              icon: Icons.lock_outline,
              title: 'Local vault',
              subtitle: profile?.label,
            ),
            _SettingsTile(
              action: _SettingsAction.clearLocalData,
              onAction: onAction,
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
              onAction: onAction,
              icon: Icons.file_upload_outlined,
              title: 'Export vault configuration',
              subtitle: 'Encrypted mailbox and OAuth settings only',
            ),
            _SettingsTile(
              action: _SettingsAction.importVault,
              onAction: onAction,
              icon: Icons.file_download_outlined,
              title: 'Import vault configuration',
              subtitle: 'Merge with the local vault',
            ),
          ],
        ),
        SizedBox(height: spacing),
        _SettingsSection(
          title: 'Application',
          children: [
            _SettingsTile(
              action: _SettingsAction.about,
              onAction: onAction,
              icon: Icons.info_outline,
              title: 'About',
              subtitle: 'Version and application information',
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
    required this.onAction,
    required this.icon,
    required this.title,
    this.subtitle,
    this.enabled = true,
    this.destructive = false,
  });

  final _SettingsAction action;
  final Future<void> Function(_SettingsAction action) onAction;
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
        onTap: enabled ? () => unawaited(onAction(action)) : null,
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
  final _backgroundSync = AndroidBackgroundSync();
  bool? _ignoringBatteryOptimizations;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_loadBatteryOptimizationState());
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
            if (AndroidBackgroundSync.isSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.sync_outlined),
                title: const Text('Keep checking in the background'),
                subtitle: const Text(
                  '${AndroidBackgroundSync.platformLabel} Without it, new '
                  'mail is only noticed while NyaMail is open.',
                ),
                value:
                    _settings.androidBackgroundSync &&
                    _settings.newMailNotifications,
                onChanged:
                    _loading || !_settings.newMailNotifications
                        ? null
                        : _setAndroidBackgroundSync,
              ),
              if (_settings.androidBackgroundSync &&
                  _settings.newMailNotifications &&
                  _ignoringBatteryOptimizations == false)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.battery_alert_outlined),
                  title: const Text('Battery optimization is on'),
                  subtitle: const Text(
                    'Android may still pause NyaMail. Set it to '
                    '"Not optimized" / "Unrestricted" for reliable '
                    'notifications.',
                  ),
                  trailing: TextButton(
                    onPressed: _openBatteryOptimizationSettings,
                    child: const Text('Open settings'),
                  ),
                ),
            ],
            if (NyaMailNotificationService.isSupported &&
                _settings.newMailNotifications) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Grouping',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              RadioGroup<NotificationGrouping>(
                groupValue: _settings.notificationGrouping,
                onChanged: (value) {
                  if (value != null && !_loading) {
                    _setNotificationGrouping(value);
                  }
                },
                child: Column(
                  children: [
                    for (final mode in NotificationGrouping.values)
                      RadioListTile<NotificationGrouping>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(mode.label),
                        subtitle: Text(mode.description),
                        value: mode,
                      ),
                  ],
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

  Future<void> _setAndroidBackgroundSync(bool enabled) async {
    await _setBehaviorSetting(
      _settings.copyWith(androidBackgroundSync: enabled),
    );
    await _loadBatteryOptimizationState();
  }

  Future<void> _loadBatteryOptimizationState() async {
    if (!AndroidBackgroundSync.isSupported) return;
    final ignoring = await _backgroundSync.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _ignoringBatteryOptimizations = ignoring);
  }

  Future<void> _openBatteryOptimizationSettings() async {
    try {
      await _backgroundSync.openBatteryOptimizationSettings();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
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

  Future<void> _setNotificationGrouping(NotificationGrouping grouping) async {
    await _setBehaviorSetting(
      _settings.copyWith(notificationGrouping: grouping),
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
