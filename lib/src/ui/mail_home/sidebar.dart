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
  static const _sidebarTileShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(24)),
  );

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
              selectedColor: Theme.of(context).colorScheme.onSecondaryContainer,
              selectedTileColor:
                  Theme.of(context).colorScheme.secondaryContainer,
              shape: _sidebarTileShape,
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
                  selectedColor:
                      Theme.of(context).colorScheme.onSecondaryContainer,
                  selectedTileColor:
                      Theme.of(context).colorScheme.secondaryContainer,
                  shape: _sidebarTileShape,
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
