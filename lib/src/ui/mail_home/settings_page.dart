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

/// Everything the settings screens read or change, supplied by the home page.
/// Values are read through callbacks so a screen that stays open sees the
/// latest state after each change.
class _SettingsEnvironment {
  const _SettingsEnvironment({
    required this.accounts,
    required this.accountFailures,
    required this.profile,
    required this.onAction,
    required this.onOpenAccount,
    required this.startupService,
    required this.systemSettings,
    required this.onSystemSettingsChanged,
    required this.themeSetting,
    required this.onThemeSettingChanged,
    required this.interactionSettings,
    required this.onInteractionSettingsChanged,
  });

  final List<MailAccount> Function() accounts;
  final Map<String, MailAccountSyncFailure> Function() accountFailures;
  final LocalProfile? Function() profile;
  final _SettingsActionHandler onAction;
  final Future<void> Function(MailAccount account) onOpenAccount;
  final StartupService startupService;
  final SystemBehaviorSettings Function() systemSettings;
  final Future<void> Function(SystemBehaviorSettings settings)
  onSystemSettingsChanged;
  final AppThemeSetting Function() themeSetting;
  final Future<void> Function(AppThemeSetting setting) onThemeSettingChanged;
  final MailInteractionSettings Function() interactionSettings;
  final Future<void> Function(MailInteractionSettings settings)
  onInteractionSettingsChanged;
}

enum _SettingsCategory {
  accounts,
  appearance,
  inbox,
  notifications,
  system,
  security,
  about,
}

extension on _SettingsCategory {
  String get label => switch (this) {
    _SettingsCategory.accounts => 'Accounts',
    _SettingsCategory.appearance => 'Appearance',
    _SettingsCategory.inbox => 'Inbox & actions',
    _SettingsCategory.notifications => 'Notifications',
    _SettingsCategory.system => 'Startup & background',
    _SettingsCategory.security => 'Security & data',
    _SettingsCategory.about => 'About',
  };

  String get summary => switch (this) {
    _SettingsCategory.accounts => 'Mailboxes, sign-in and cache',
    _SettingsCategory.appearance => 'Theme and message rendering',
    _SettingsCategory.inbox => 'Smart Inbox, swipes and menus',
    _SettingsCategory.notifications => 'New mail alerts and grouping',
    _SettingsCategory.system =>
      AndroidBackgroundSync.isSupported
          ? 'Background checking and battery'
          : 'Launch at startup and tray',
    _SettingsCategory.security => 'Local vault, export and reset',
    _SettingsCategory.about => 'Version and updates',
  };

  IconData get icon => switch (this) {
    _SettingsCategory.accounts => Icons.alternate_email,
    _SettingsCategory.appearance => Icons.palette_outlined,
    _SettingsCategory.inbox => Icons.inbox_outlined,
    _SettingsCategory.notifications => Icons.notifications_none,
    _SettingsCategory.system => Icons.power_settings_new,
    _SettingsCategory.security => Icons.lock_outline,
    _SettingsCategory.about => Icons.info_outline,
  };

  Color color(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    Color pick(int light, int darkValue) => Color(dark ? darkValue : light);
    return switch (this) {
      _SettingsCategory.accounts => scheme.primary,
      _SettingsCategory.appearance => pick(0xFF8B5CF6, 0xFFB69CFA),
      _SettingsCategory.inbox => pick(0xFF1E9E7A, 0xFF5CC8A8),
      _SettingsCategory.notifications => pick(0xFFE0533D, 0xFFF08A78),
      _SettingsCategory.system => pick(0xFFD9822B, 0xFFF2B35B),
      _SettingsCategory.security => pick(0xFF4B5563, 0xFFA2A5AD),
      _SettingsCategory.about => pick(0xFF0EA5E9, 0xFF7DD3FC),
    };
  }
}

/// Desktop settings: a large dialog with a category list on the left.
class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.environment});

  final _SettingsEnvironment environment;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  _SettingsCategory _category = _SettingsCategory.accounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: math.min(940, size.width - 64),
        height: math.min(700, size.height - 64),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 240,
              color: colorScheme.surfaceContainerLow,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 18, 10, 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                    child: Text('Settings', style: theme.textTheme.titleLarge),
                  ),
                  for (final category in _SettingsCategory.values)
                    _SidebarTile(
                      icon: category.icon,
                      label: category.label,
                      selected: category == _category,
                      onTap: () => setState(() => _category = category),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _SettingsCategoryView(
                      key: ValueKey(_category),
                      category: _category,
                      environment: widget.environment,
                      showTitle: true,
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone settings: category list, each opening its own page.
class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.environment});

  final _SettingsEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surfaceContainerLow,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: colorScheme.surfaceContainerLow,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _SettingsGroup(
              children: [
                for (final category in _SettingsCategory.values)
                  _SettingsRow(
                    leading: _SettingsIconBadge(
                      icon: category.icon,
                      color: category.color(colorScheme),
                    ),
                    title: category.label,
                    subtitle: category.summary,
                    onTap:
                        () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder:
                                (context) => Scaffold(
                                  backgroundColor:
                                      colorScheme.surfaceContainerLow,
                                  appBar: AppBar(
                                    title: Text(category.label),
                                    backgroundColor:
                                        colorScheme.surfaceContainerLow,
                                  ),
                                  body: SafeArea(
                                    child: _SettingsCategoryView(
                                      category: category,
                                      environment: environment,
                                      showTitle: false,
                                    ),
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
    );
  }
}

class _SettingsCategoryView extends StatefulWidget {
  const _SettingsCategoryView({
    super.key,
    required this.category,
    required this.environment,
    required this.showTitle,
  });

  final _SettingsCategory category;
  final _SettingsEnvironment environment;
  final bool showTitle;

  @override
  State<_SettingsCategoryView> createState() => _SettingsCategoryViewState();
}

class _SettingsCategoryViewState extends State<_SettingsCategoryView> {
  _SettingsFeedback? _feedback;
  String? _version;

  _SettingsEnvironment get _env => widget.environment;

  @override
  void initState() {
    super.initState();
    if (widget.category == _SettingsCategory.about) {
      unawaited(
        PackageInfo.fromPlatform().then((info) {
          if (!mounted) return;
          setState(() => _version = '${info.version} (${info.buildNumber})');
        }),
      );
    }
  }

  Future<void> _run(_SettingsAction action) async {
    final result = await _env.onAction(action);
    if (!mounted) return;
    setState(() => _feedback = result.feedback);
    if (!result.keepOpen) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = switch (widget.category) {
      _SettingsCategory.accounts => _accounts(context),
      _SettingsCategory.appearance => _appearance(context),
      _SettingsCategory.inbox => _inbox(context),
      _SettingsCategory.notifications => [
        _SystemBehaviorPanel(
          environment: _env,
          part: _SystemBehaviorPart.notifications,
        ),
      ],
      _SettingsCategory.system => [
        _SystemBehaviorPanel(
          environment: _env,
          part: _SystemBehaviorPart.system,
        ),
      ],
      _SettingsCategory.security => _security(context),
      _SettingsCategory.about => _about(context),
    };
    return ListView(
      padding: EdgeInsets.fromLTRB(
        widget.showTitle ? 28 : 16,
        widget.showTitle ? 24 : 4,
        widget.showTitle ? 28 : 16,
        24,
      ),
      children: [
        if (widget.showTitle) ...[
          Text(widget.category.label, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            widget.category.summary,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (_feedback case final feedback?) ...[
          _SettingsFeedbackBanner(feedback: feedback),
          const SizedBox(height: 16),
        ],
        ...children,
      ],
    );
  }

  List<Widget> _accounts(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final accounts = _env.accounts();
    final failures = _env.accountFailures();
    return [
      _SettingsGroup(
        title: 'Mailboxes',
        children: [
          for (final account in accounts)
            _SettingsRow(
              leading: _SenderAvatar(
                from:
                    account.displayName.trim().isEmpty
                        ? account.address
                        : '${account.displayName} <${account.address}>',
                size: 32,
              ),
              title:
                  account.displayName.trim().isEmpty
                      ? account.address
                      : account.displayName,
              subtitle: switch (failures[account.id]) {
                null => account.address,
                final failure when failure.authenticationRequired =>
                  'Sign-in required · ${account.address}',
                _ => 'Last sync failed · ${account.address}',
              },
              subtitleColor:
                  failures.containsKey(account.id) ? colorScheme.error : null,
              onTap: () async {
                await _env.onOpenAccount(account);
                if (mounted) setState(() {});
              },
            ),
          _SettingsRow(
            leading: _SettingsIconBadge(
              icon: Icons.add,
              color: colorScheme.primary,
            ),
            title: 'Add mailbox',
            subtitle: 'IMAP/SMTP, Gmail or Outlook',
            onTap: () => _run(_SettingsAction.addMailbox),
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Sign-in',
        children: [
          _SettingsRow(
            icon: Icons.vpn_key_outlined,
            title: 'OAuth providers',
            subtitle: 'Client IDs used for Gmail and Outlook sign-in',
            onTap: () => _run(_SettingsAction.oauthProviderSettings),
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Local cache',
        footer:
            'Mail is cached on this device so lists open instantly. Clearing '
            'it re-downloads recent mail from your providers.',
        children: [
          _SettingsRow(
            icon: Icons.cleaning_services_outlined,
            title: 'Clear mail cache',
            subtitle: 'Re-fetch messages and rebuild the local index',
            onTap: () => _run(_SettingsAction.clearMailCache),
          ),
        ],
      ),
    ];
  }

  List<Widget> _appearance(BuildContext context) {
    final theme = _env.themeSetting();
    return [
      _SettingsGroup(
        title: 'Theme',
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: SegmentedButton<AppThemeSetting>(
              showSelectedIcon: false,
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
              selected: {theme},
              onSelectionChanged: (selection) async {
                await _env.onThemeSettingChanged(selection.first);
                if (mounted) setState(() {});
              },
            ),
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Reading',
        children: [
          _SettingsRow(
            icon: Icons.chrome_reader_mode_outlined,
            title: 'Message rendering',
            subtitle: 'Remote images, message theme and text size',
            onTap: () => _run(_SettingsAction.mailSettings),
          ),
        ],
      ),
    ];
  }

  List<Widget> _inbox(BuildContext context) {
    final settings = _env.interactionSettings();
    return [
      _SettingsGroup(
        title: 'Smart Inbox',
        footer:
            'Mail from people stays in the timeline. Automated notifications '
            'and newsletters collapse into one row each in All incoming, '
            'Inbox and Unread.',
        children: [
          _SettingsSwitchRow(
            icon: Icons.auto_awesome_outlined,
            title: 'Group notifications and newsletters',
            value: settings.smartInbox,
            onChanged: (value) async {
              await _env.onInteractionSettingsChanged(
                settings.copyWith(smartInbox: value),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Actions',
        children: [
          _SettingsRow(
            icon: Icons.swipe_outlined,
            title: 'Swipes, menus and selection',
            subtitle: 'Choose what swipes and right-click do',
            onTap: () async {
              await _run(_SettingsAction.mailInteractionSettings);
            },
          ),
        ],
      ),
    ];
  }

  List<Widget> _security(BuildContext context) {
    return [
      _SettingsGroup(
        title: 'Local vault',
        children: [
          _SettingsRow(
            icon: Icons.lock_outline,
            title: 'Vault and unlock',
            subtitle: _env.profile()?.label ?? 'Password and quick unlock',
            onTap: () => _run(_SettingsAction.localVaultSettings),
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Backup',
        footer:
            'Exports contain mailbox and OAuth settings only, encrypted with '
            'a password you choose. Mail is not included.',
        children: [
          _SettingsRow(
            icon: Icons.file_upload_outlined,
            title: 'Export vault configuration',
            onTap: () => _run(_SettingsAction.exportVault),
          ),
          _SettingsRow(
            icon: Icons.file_download_outlined,
            title: 'Import vault configuration',
            subtitle: 'Merge into this vault',
            onTap: () => _run(_SettingsAction.importVault),
          ),
        ],
      ),
      _SettingsGroup(
        children: [
          _SettingsRow(
            icon: Icons.delete_forever_outlined,
            title: 'Clear local data',
            subtitle: 'Remove the vault, cache and settings from this device',
            destructive: true,
            onTap: () => _run(_SettingsAction.clearLocalData),
          ),
        ],
      ),
    ];
  }

  List<Widget> _about(BuildContext context) {
    return [
      _SettingsGroup(
        children: [
          _SettingsRow(
            icon: Icons.mail_rounded,
            title: 'NyaMail',
            subtitle: _version == null ? 'Version…' : 'Version $_version',
            trailing: const SizedBox.shrink(),
          ),
          _SettingsRow(
            icon: Icons.system_update_alt,
            title: 'Check for updates',
            onTap: () => _run(_SettingsAction.checkUpdates),
          ),
          _SettingsRow(
            icon: Icons.info_outline,
            title: 'About NyaMail',
            subtitle: 'Licenses and application information',
            onTap: () => _run(_SettingsAction.about),
          ),
        ],
      ),
    ];
  }
}

/// A titled card of settings rows, iOS/Spark style.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children, this.title, this.footer});

  final String? title;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final rows = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      if (index > 0) {
        rows.add(const Divider(height: 1, indent: 56));
      }
      rows.add(children[index]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                title!,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsIconBadge extends StatelessWidget {
  const _SettingsIconBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.subtitleColor,
    this.onTap,
    this.trailing,
    this.destructive = false,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final foreground = destructive ? colorScheme.error : colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Center(
                  child:
                      leading ??
                      Icon(
                        icon,
                        size: 22,
                        color:
                            destructive
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: subtitleColor ?? colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing ??
                  (onTap == null
                      ? const SizedBox.shrink()
                      : Icon(
                        Icons.chevron_right,
                        color: colorScheme.onSurfaceVariant,
                      )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.subtitle,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// A radio-style choice row inside a [_SettingsGroup].
class _SettingsChoiceRow extends StatelessWidget {
  const _SettingsChoiceRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SettingsRow(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
      ),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: const SizedBox.shrink(),
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
      borderRadius: BorderRadius.circular(kNyaRadius),
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

enum _SystemBehaviorPart { notifications, system }

/// Notification, startup, tray and Android background settings. Changes save
/// immediately.
class _SystemBehaviorPanel extends StatefulWidget {
  const _SystemBehaviorPanel({required this.environment, required this.part});

  final _SettingsEnvironment environment;
  final _SystemBehaviorPart part;

  @override
  State<_SystemBehaviorPanel> createState() => _SystemBehaviorPanelState();
}

class _SystemBehaviorPanelState extends State<_SystemBehaviorPanel>
    with WidgetsBindingObserver {
  late SystemBehaviorSettings _settings = widget.environment.systemSettings();
  bool _saving = false;
  bool _launchAtStartup = false;
  bool _startupLoaded = false;
  String? _error;
  final _backgroundSync = AndroidBackgroundSync();
  bool? _ignoringBatteryOptimizations;
  bool? _notificationsPermitted;

  StartupService get _startupService => widget.environment.startupService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadStartup());
    unawaited(_loadPlatformState());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system settings screens we opened.
    if (state == AppLifecycleState.resumed) unawaited(_loadPlatformState());
  }

  Future<void> _loadStartup() async {
    try {
      final enabled =
          _startupService.isSupported
              ? await _startupService.isEnabled()
              : false;
      if (!mounted) return;
      setState(() {
        _launchAtStartup = enabled;
        _startupLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _startupLoaded = true;
      });
    }
  }

  Future<void> _loadPlatformState() async {
    if (!AndroidBackgroundSync.isSupported) return;
    final ignoring = await _backgroundSync.isIgnoringBatteryOptimizations();
    final permitted =
        await NyaMailNotificationService.systemPermissionGranted();
    if (!mounted) return;
    setState(() {
      _ignoringBatteryOptimizations = ignoring;
      _notificationsPermitted = permitted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final groups = switch (widget.part) {
      _SystemBehaviorPart.notifications => _notificationGroups(context),
      _SystemBehaviorPart.system => _systemGroups(context),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...groups,
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }

  List<Widget> _notificationGroups(BuildContext context) {
    final supported = NyaMailNotificationService.isSupported;
    final enabled = _settings.newMailNotifications && supported;
    final colorScheme = Theme.of(context).colorScheme;
    return [
      if (enabled && _notificationsPermitted == false)
        _SettingsStatusCard(
          icon: Icons.notifications_off_outlined,
          color: colorScheme.error,
          title: 'Notifications are blocked by Android',
          message:
              'NyaMail is allowed to notify, but the system has notifications '
              'turned off for it.',
          actionLabel: 'Allow',
          onAction: () => unawaited(_backgroundSync.openNotificationSettings()),
        ),
      _SettingsGroup(
        title: 'New mail',
        footer: supported ? null : NyaMailNotificationService.platformLabel,
        children: [
          _SettingsSwitchRow(
            icon: Icons.notifications_active_outlined,
            title: 'Notify me about new mail',
            value: enabled,
            onChanged:
                !supported || _saving
                    ? null
                    : (value) =>
                        _save(_settings.copyWith(newMailNotifications: value)),
          ),
          _SettingsSwitchRow(
            icon: Icons.person_outline,
            title: 'Only mail from people',
            subtitle:
                'Stay quiet for automated notifications and newsletters. '
                'They still arrive in your inbox.',
            value: _settings.smartNotifications,
            onChanged:
                !enabled || _saving
                    ? null
                    : (value) =>
                        _save(_settings.copyWith(smartNotifications: value)),
          ),
          _SettingsSwitchRow(
            icon: Icons.open_in_new,
            title: 'Open the message when tapped',
            value: _settings.openMessageFromNotification,
            onChanged:
                !enabled || _saving
                    ? null
                    : (value) => _save(
                      _settings.copyWith(openMessageFromNotification: value),
                    ),
          ),
        ],
      ),
      if (enabled)
        _SettingsGroup(
          title: 'Grouping',
          footer:
              'When more than $_maxIndividualNewMailNotifications messages '
              'arrive at once they are always summarized in a single '
              'notification.',
          children: [
            for (final mode in NotificationGrouping.values)
              _SettingsChoiceRow(
                title: mode.label,
                subtitle: mode.description,
                selected: _settings.notificationGrouping == mode,
                onTap:
                    _saving
                        ? null
                        : () => _save(
                          _settings.copyWith(notificationGrouping: mode),
                        ),
              ),
          ],
        ),
    ];
  }

  List<Widget> _systemGroups(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (AndroidBackgroundSync.isSupported) {
      final wanted =
          _settings.androidBackgroundSync && _settings.newMailNotifications;
      final protected = _ignoringBatteryOptimizations == true;
      return [
        _SettingsGroup(
          title: 'Background checking',
          footer:
              _settings.newMailNotifications
                  ? '${AndroidBackgroundSync.platformLabel} Without it, new '
                      'mail is only noticed while NyaMail is open.'
                  : 'Turn on new mail notifications first.',
          children: [
            _SettingsSwitchRow(
              icon: Icons.sync_outlined,
              title: 'Keep checking in the background',
              value: wanted,
              onChanged:
                  _saving || !_settings.newMailNotifications
                      ? null
                      : (value) async {
                        await _save(
                          _settings.copyWith(androidBackgroundSync: value),
                        );
                        await _loadPlatformState();
                      },
            ),
          ],
        ),
        if (wanted)
          _SettingsGroup(
            title: 'Background protection',
            footer:
                'Some phones (Xiaomi, Huawei, OPPO, vivo, Samsung...) also '
                'need "Auto-start" or "Allow background activity" in App info.',
            children: [
              _SettingsRow(
                leading: _SettingsIconBadge(
                  icon:
                      protected
                          ? Icons.battery_charging_full
                          : Icons.battery_alert_outlined,
                  color:
                      protected ? const Color(0xFF1E9E7A) : colorScheme.error,
                ),
                title:
                    protected
                        ? 'Battery optimization: off'
                        : 'Battery optimization is on',
                subtitle:
                    protected
                        ? 'Android will not pause NyaMail to save power.'
                        : 'Android may pause NyaMail and delay notifications.',
                trailing:
                    protected
                        ? const Icon(Icons.check, color: Color(0xFF1E9E7A))
                        : FilledButton.tonal(
                          onPressed: () => unawaited(_openBatterySettings()),
                          child: const Text('Fix'),
                        ),
              ),
              _SettingsRow(
                icon: Icons.app_settings_alt_outlined,
                title: 'App info',
                subtitle: 'Auto-start, background activity and data usage',
                onTap:
                    () => unawaited(_backgroundSync.openAppDetailsSettings()),
              ),
            ],
          ),
      ];
    }
    return [
      _SettingsGroup(
        title: 'Startup',
        footer: _startupService.platformLabel,
        children: [
          _SettingsSwitchRow(
            icon: Icons.rocket_launch_outlined,
            title: 'Launch NyaMail when I sign in',
            value: _launchAtStartup,
            onChanged:
                !_startupLoaded || !_startupService.isSupported
                    ? null
                    : _setLaunchAtStartup,
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Background',
        footer:
            'While NyaMail runs in the tray it keeps checking mail and '
            'showing notifications.',
        children: [
          _SettingsSwitchRow(
            icon: Icons.move_to_inbox_outlined,
            title: 'Keep running in the tray when closed',
            subtitle: NyaMailTrayService.platformLabel,
            value: _settings.minimizeToTray,
            onChanged:
                _saving || !NyaMailTrayService.isSupported
                    ? null
                    : (value) =>
                        _save(_settings.copyWith(minimizeToTray: value)),
          ),
        ],
      ),
    ];
  }

  Future<void> _openBatterySettings() async {
    try {
      await _backgroundSync.openBatteryOptimizationSettings();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  Future<void> _setLaunchAtStartup(bool enabled) async {
    setState(() {
      _startupLoaded = false;
      _error = null;
    });
    try {
      await _startupService.setEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _launchAtStartup = enabled;
        _startupLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _startupLoaded = true;
      });
    }
  }

  Future<void> _save(SystemBehaviorSettings settings) async {
    final previous = _settings;
    setState(() {
      _settings = settings;
      _saving = true;
      _error = null;
    });
    try {
      await widget.environment.onSystemSettingsChanged(settings);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _settings = previous;
        _saving = false;
      });
    }
  }
}

/// Highlighted card for a problem the user should fix (e.g. blocked
/// notifications).
class _SettingsStatusCard extends StatelessWidget {
  const _SettingsStatusCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(message, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
