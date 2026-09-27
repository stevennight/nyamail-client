part of '../mail_home_page.dart';

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
    this.onCompose,
    this.onSettings,
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

  /// Compose and settings live in the sidebar when there is no app bar.
  final VoidCallback? onCompose;
  final VoidCallback? onSettings;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  static const _sidebarTileShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(kNyaRadius)),
  );

  final _folderFilter = TextEditingController();

  @override
  void dispose() {
    _folderFilter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
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
    final sectionStyle = theme.textTheme.labelMedium?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    final onSettings = widget.onSettings;
    return Container(
      width: 256,
      color: colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onSettings != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.mail_rounded, color: colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('NyaMail', style: theme.textTheme.titleMedium),
                  ),
                  IconButton(
                    tooltip: 'Settings',
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: FilledButton.icon(
                onPressed: widget.onCompose,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                icon: const Icon(Icons.edit_outlined, size: 20),
                label: const Text('New message'),
              ),
            ),
          ],
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              children: [
                for (final item in smartFolders)
                  _SidebarTile(
                    icon: _iconForSmartFolder(item),
                    label: _labelForSmartFolder(item),
                    selected: widget.view.smartFolder == item,
                    onTap: () => widget.onViewChanged(MailboxView.smart(item)),
                  ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 4, 2),
                  child: Row(
                    children: [
                      Expanded(child: Text('Accounts', style: sectionStyle)),
                      IconButton(
                        tooltip: 'Add mailbox',
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        onPressed: widget.onAddMailbox,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                if (hasMatches)
                  ...accountWidgets
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'No matching folders',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _folderFilter,
                style: theme.textTheme.bodyMedium,
                textAlignVertical: TextAlignVertical.center,
                decoration: InputDecoration(
                  hintText: 'Filter folders',
                  fillColor: colorScheme.surfaceContainerHigh,
                  contentPadding: EdgeInsets.zero,
                  prefixIcon: const Icon(Icons.filter_list, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36),
                  suffixIcon:
                      filter.isEmpty
                          ? null
                          : IconButton(
                            tooltip: 'Clear folder filter',
                            iconSize: 16,
                            onPressed: () {
                              _folderFilter.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close),
                          ),
                ),
                onChanged: (_) => setState(() {}),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = _accountAccentColor(account.id, colorScheme);
    final name =
        account.displayName.trim().isEmpty
            ? account.address
            : account.displayName;
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
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key:
              filtering
                  ? ValueKey('filtered-account-${account.id}')
                  : PageStorageKey('account-${account.id}'),
          initiallyExpanded:
              filtering ||
              widget.view.folder?.accountId == account.id ||
              widget.accounts.length == 1,
          dense: true,
          shape: _sidebarTileShape,
          collapsedShape: _sidebarTileShape,
          tilePadding: const EdgeInsets.only(left: 10, right: 6),
          childrenPadding: const EdgeInsets.only(bottom: 4),
          minTileHeight: 48,
          leading: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  failure == null
                      ? accent.withValues(alpha: 0.18)
                      : colorScheme.errorContainer,
              shape: BoxShape.circle,
            ),
            child:
                failure == null
                    ? Text(
                      _senderInitial(name),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                    : Icon(
                      failure.authenticationRequired
                          ? Icons.key_off_outlined
                          : Icons.sync_problem_outlined,
                      size: 15,
                      color: colorScheme.onErrorContainer,
                    ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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
            failure == null ? account.address : failureLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color:
                  failure == null
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.error,
            ),
          ),
          children: [
            for (final folder in visibleFolders)
              _SidebarTile(
                icon: _iconForMailbox(folder.kind),
                label: folder.displayName,
                tooltip:
                    folder.effectiveDisplayPath == folder.displayName
                        ? null
                        : folder.effectiveDisplayPath,
                indent: 22,
                selected: widget.view.folder?.key == folder.key,
                onTap: () => widget.onViewChanged(MailboxView.folder(folder)),
              ),
          ],
        ),
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

/// Compact, rounded navigation row used for smart folders and account folders.
class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.indent = 0,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double indent;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final foreground =
        selected ? colorScheme.onPrimaryContainer : colorScheme.onSurface;
    final tile = Padding(
      padding: EdgeInsets.only(left: indent, bottom: 1),
      child: Material(
        color: selected ? colorScheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(kNyaRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kNyaRadius),
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  icon,
                  size: 19,
                  color:
                      selected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
    final text = tooltip;
    if (text == null) return tile;
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 600),
      child: tile,
    );
  }
}
