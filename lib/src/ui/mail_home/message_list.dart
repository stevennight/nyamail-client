part of '../mail_home_page.dart';

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
    required this.groupBundles,
    required this.onMarkMessagesRead,
    this.headerTitle,
    this.onPullToRefresh,
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

  /// Collapse notifications and newsletters into Smart Inbox bundles.
  final bool groupBundles;
  final ValueChanged<List<MailMessage>> onMarkMessagesRead;

  /// Shows a title row above the search field (desktop, where there is no
  /// app bar).
  final String? headerTitle;

  /// Enables pull-to-refresh (touch layouts).
  final Future<void> Function()? onPullToRefresh;

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  static const _loadMoreThreshold = 480.0;
  static const _searchDebounceDelay = Duration(milliseconds: 450);

  final _scrollController = ScrollController();
  final _messageItemKeys = <String, GlobalKey>{};
  final _expandedBundles = <MailCategory>{};
  List<_MailListEntry> _entries = const [];
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
    final index = _entries.indexWhere(
      (entry) =>
          entry is _MailListMessageEntry && entry.message.id == messageId,
    );
    if (index < 0) return;
    const estimatedRowExtent = 76.0;
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

  /// Bundles the user opened, plus any bundle holding the message that is
  /// selected or keyboard-focused so it never hides behind a collapsed row.
  Set<MailCategory> get _effectiveExpandedBundles {
    final expanded = {..._expandedBundles};
    for (final id in [
      widget.selected?.id,
      widget.keyboardNavigationMessageId,
    ]) {
      if (id == null || widget.pinnedMessageIds.contains(id)) continue;
      for (final message in widget.messages) {
        if (message.id == id) expanded.add(message.effectiveCategory);
      }
    }
    return expanded;
  }

  void _toggleBundle(MailCategory category) {
    setState(() {
      if (!_expandedBundles.remove(category)) _expandedBundles.add(category);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final selecting = widget.selectedMessageIds.isNotEmpty;
    final selectedMessages = [
      for (final message in widget.messages)
        if (widget.selectedMessageIds.contains(message.id)) message,
    ];
    final multipleAccounts = widget.accounts.length > 1;
    final accountLabels = {
      for (final account in widget.accounts)
        account.id:
            account.displayName.trim().isEmpty
                ? account.address
                : account.displayName,
    };
    final entries =
        _entries = _buildMailListEntries(
          messages: widget.messages,
          pinnedMessageIds: widget.pinnedMessageIds,
          groupBundles: widget.groupBundles,
          expandedBundles: _effectiveExpandedBundles,
        );
    final unreadCount = widget.messages.where((m) => !m.read).length;

    Widget list = ListView.builder(
      controller: _scrollController,
      physics:
          widget.onPullToRefresh == null
              ? null
              : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == entries.length) {
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
        switch (entries[index]) {
          case _MailListHeaderEntry(:final label):
            return _MessageSectionHeader(label: label);
          case final _MailListBundleEntry bundle:
            return _MessageBundleTile(
              key: ValueKey('bundle-${bundle.category.name}'),
              bundle: bundle,
              onTap: () => _toggleBundle(bundle.category),
              onMarkRead:
                  bundle.unreadCount == 0
                      ? null
                      : () => widget.onMarkMessagesRead([
                        for (final message in bundle.messages)
                          if (!message.read) message,
                      ]),
            );
          case _MailListMessageEntry(:final message, :final inBundle):
            return KeyedSubtree(
              key: _messageItemKeyFor(message.id),
              child: _messageItem(
                context: context,
                message: message,
                inBundle: inBundle,
                accountLabel:
                    accountLabels[message.accountId] ?? message.accountId,
                accountColor:
                    multipleAccounts
                        ? _accountAccentColor(message.accountId, colorScheme)
                        : null,
              ),
            );
        }
      },
    );
    final pullToRefresh = widget.onPullToRefresh;
    if (pullToRefresh != null) {
      list = RefreshIndicator(onRefresh: pullToRefresh, child: list);
    }

    final headerTitle = widget.headerTitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (headerTitle != null)
          _MessageListHeader(
            title: headerTitle,
            unreadCount: unreadCount,
            refreshing: widget.refreshing,
            onRefresh: widget.onRefresh,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, headerTitle == null ? 10 : 2, 12, 6),
          child: SearchBar(
            controller: widget.search,
            focusNode: widget.searchFocusNode,
            hintText: 'Search mail',
            leading: Icon(
              Icons.search,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            trailing:
                widget.search.text.trim().isEmpty
                    ? null
                    : [
                      IconButton(
                        tooltip: 'Clear search',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
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
        Expanded(child: list),
      ],
    );
  }

  Widget _messageItem({
    required BuildContext context,
    required MailMessage message,
    required String accountLabel,
    required Color? accountColor,
    bool inBundle = false,
  }) {
    final selecting = widget.selectedMessageIds.isNotEmpty;
    final selectedForBatch = widget.selectedMessageIds.contains(message.id);
    Widget child = _MessageListTile(
      message: message,
      accountLabel: accountLabel,
      accountColor: accountColor,
      inBundle: inBundle,
      showHoverActions: widget.supportsDesktopContextMenu,
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

class _MessageListHeader extends StatelessWidget {
  const _MessageListHeader({
    required this.title,
    required this.unreadCount,
    required this.refreshing,
    required this.onRefresh,
  });

  final String title;
  final int unreadCount;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  refreshing
                      ? 'Checking for new mail…'
                      : unreadCount == 0
                      ? 'All caught up'
                      : '$unreadCount unread',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox.square(
            dimension: 40,
            child:
                refreshing
                    ? const Padding(
                      padding: EdgeInsets.all(11),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : IconButton(
                      tooltip: 'Refresh mail',
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh),
                    ),
          ),
        ],
      ),
    );
  }
}

class _MessageSectionHeader extends StatelessWidget {
  const _MessageSectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Rounded, inset row background used by message and bundle rows.
class _MessageRowFrame extends StatelessWidget {
  const _MessageRowFrame({
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.highlighted = false,
    this.onHover,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool highlighted;
  final ValueChanged<bool>? onHover;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color:
            selected
                ? colorScheme.primaryContainer
                : highlighted
                ? colorScheme.surfaceContainer
                : Colors.transparent,
        borderRadius: BorderRadius.circular(kNyaRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onHover: onHover,
          child: child,
        ),
      ),
    );
  }
}

class _MessageListTile extends StatefulWidget {
  const _MessageListTile({
    required this.message,
    required this.accountLabel,
    required this.accountColor,
    required this.selected,
    required this.selectedForBatch,
    required this.selecting,
    required this.pinned,
    required this.multiSelectEnabled,
    required this.showHoverActions,
    required this.inBundle,
    required this.onTap,
    required this.onLongPress,
    required this.onSelectionChanged,
    required this.onAction,
  });

  final MailMessage message;
  final String accountLabel;
  final Color? accountColor;
  final bool selected;
  final bool selectedForBatch;
  final bool selecting;
  final bool pinned;
  final bool multiSelectEnabled;
  final bool showHoverActions;
  final bool inBundle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final ValueChanged<bool> onSelectionChanged;
  final Future<void> Function(MailListActionPreference action) onAction;

  @override
  State<_MessageListTile> createState() => _MessageListTileState();
}

class _MessageListTileState extends State<_MessageListTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;
    final secondary = colorScheme.onSurfaceVariant;
    final unread = !message.read;
    final subjectLabel = mailMessageSubjectLabel(message.subject);
    final preview = message.preview.trim();
    final showActions =
        widget.showHoverActions && _hovered && !widget.selecting;
    final avatarSize = widget.inBundle ? 30.0 : 38.0;

    final Widget leading;
    if (widget.selecting) {
      leading = SizedBox.square(
        dimension: avatarSize,
        child: Checkbox(
          value: widget.selectedForBatch,
          shape: const CircleBorder(),
          onChanged:
              widget.multiSelectEnabled
                  ? (value) => widget.onSelectionChanged(value ?? false)
                  : null,
        ),
      );
    } else {
      final avatar = _SenderAvatar(
        from: message.from,
        size: avatarSize,
        accountColor: widget.accountColor,
      );
      leading = Tooltip(
        message: widget.accountLabel,
        waitDuration: const Duration(milliseconds: 700),
        child:
            widget.multiSelectEnabled
                ? GestureDetector(
                  onTap: () => widget.onSelectionChanged(true),
                  child: avatar,
                )
                : avatar,
      );
    }

    final trailingIcons = [
      if (widget.pinned) Icon(Icons.push_pin, size: 14, color: secondary),
      if (message.hasAttachments)
        Icon(Icons.attach_file, size: 14, color: secondary),
      if (message.starred) const Icon(Icons.star, size: 15, color: _starColor),
    ];

    final content = Padding(
      padding: EdgeInsets.fromLTRB(widget.inBundle ? 30 : 6, 9, 12, 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 12,
            height: avatarSize,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unread ? colorScheme.primary : Colors.transparent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _displaySender(message.from),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              unread ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    for (final icon in trailingIcons) ...[
                      const SizedBox(width: 4),
                      icon,
                    ],
                    const SizedBox(width: 8),
                    Opacity(
                      opacity: showActions ? 0 : 1,
                      child: Text(
                        mailMessageCompactDisplayDate(message.receivedAt),
                        style: textTheme.labelSmall?.copyWith(
                          color: unread ? colorScheme.primary : secondary,
                          fontWeight:
                              unread ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subjectLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                    color: unread ? colorScheme.onSurface : secondary,
                  ),
                ),
                if (preview.isNotEmpty && !widget.inBundle) ...[
                  const SizedBox(height: 1),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: secondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return _MessageRowFrame(
      selected: widget.selected || widget.selectedForBatch,
      highlighted: _hovered && widget.showHoverActions,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onHover:
          widget.showHoverActions
              ? (hovered) {
                if (hovered != _hovered) setState(() => _hovered = hovered);
              }
              : null,
      child: Stack(
        children: [
          content,
          if (showActions)
            Positioned(
              top: 4,
              right: 6,
              child: _MessageHoverActions(
                message: message,
                pinned: widget.pinned,
                onAction: widget.onAction,
              ),
            ),
        ],
      ),
    );
  }
}

/// Quick actions shown over a row while the pointer is on it (desktop).
class _MessageHoverActions extends StatelessWidget {
  const _MessageHoverActions({
    required this.message,
    required this.pinned,
    required this.onAction,
  });

  final MailMessage message;
  final bool pinned;
  final Future<void> Function(MailListActionPreference action) onAction;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final quick = [
      MailListActionPreference.toggleRead,
      if (_mailListActionAppliesToMessage(
        MailListActionPreference.archive,
        message,
      ))
        MailListActionPreference.archive,
      if (_mailListActionAppliesToMessage(
        MailListActionPreference.delete,
        message,
      ))
        MailListActionPreference.delete,
    ];
    return Material(
      color: colorScheme.surface,
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in quick)
            IconButton(
              tooltip: _mailListActionLabel(
                action,
                message: message,
                pinned: pinned,
              ),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => unawaited(onAction(action)),
              icon: Icon(
                _mailListActionIcon(action, message: message, pinned: pinned),
              ),
            ),
          _MessageOverflowMenu(
            message: message,
            pinned: pinned,
            onAction: onAction,
          ),
        ],
      ),
    );
  }
}

class _MessageBundleTile extends StatelessWidget {
  const _MessageBundleTile({
    super.key,
    required this.bundle,
    required this.onTap,
    required this.onMarkRead,
  });

  final _MailListBundleEntry bundle;
  final VoidCallback onTap;
  final VoidCallback? onMarkRead;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final accent = _colorForMailCategory(bundle.category, colorScheme);
    final unread = bundle.unreadCount;
    final senders = <String>[];
    for (final message in bundle.messages) {
      final sender = _displaySender(message.from);
      if (!senders.contains(sender)) senders.add(sender);
      if (senders.length == 4) break;
    }
    return _MessageRowFrame(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 9, 4, 9),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              child: Center(
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: unread > 0 ? colorScheme.primary : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _iconForMailCategory(bundle.category),
                color: accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        flex: 4,
                        child: Text(
                          _labelForMailCategory(bundle.category),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight:
                                unread > 0 ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color:
                              unread > 0
                                  ? accent.withValues(alpha: 0.16)
                                  : colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          unread > 0
                              ? '$unread new'
                              : '${bundle.messages.length}',
                          style: textTheme.labelSmall?.copyWith(
                            color:
                                unread > 0
                                    ? accent
                                    : colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Icon(
                        bundle.expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const Spacer(),
                      Text(
                        mailMessageCompactDisplayDate(bundle.newest.receivedAt),
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    senders.join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    mailMessageSubjectLabel(bundle.newest.subject),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onMarkRead != null)
              IconButton(
                tooltip: 'Mark all as read',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onMarkRead,
                icon: const Icon(Icons.done_all),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
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
    required this.groupBundles,
    required this.onMarkMessagesRead,
    this.onPullToRefresh,
  });

  final bool groupBundles;
  final ValueChanged<List<MailMessage>> onMarkMessagesRead;
  final Future<void> Function()? onPullToRefresh;
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
      groupBundles: groupBundles,
      onMarkMessagesRead: onMarkMessagesRead,
      onPullToRefresh: onPullToRefresh,
    );
  }
}
