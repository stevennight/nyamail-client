part of '../mail_home_page.dart';

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

class _MailHomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _MailHomeAppBar({
    required this.title,
    required this.onCompose,
    required this.onRefresh,
    required this.refreshing,
    required this.onSettings,
    this.showCompose = true,
  });

  final String title;
  final bool showCompose;
  final VoidCallback? onCompose;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final VoidCallback onSettings;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 2);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (showCompose)
          IconButton(
            tooltip:
                onCompose == null
                    ? 'Add a mailbox before composing'
                    : 'New message',
            onPressed: onCompose,
            icon: const Icon(Icons.edit_outlined),
          ),
        IconButton(
          tooltip: refreshing ? 'Refreshing mail…' : 'Refresh mail',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 4),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child:
            refreshing
                ? const LinearProgressIndicator(minHeight: 2)
                : const SizedBox(height: 2),
      ),
    );
  }
}

class _MailBottomNav extends StatelessWidget {
  const _MailBottomNav({
    required this.currentIndex,
    required this.onSelectView,
    required this.onOpenFolders,
  });

  final int currentIndex;
  final ValueChanged<MailSmartFolder> onSelectView;
  final VoidCallback onOpenFolders;

  static const _views = [
    MailSmartFolder.allIncoming,
    MailSmartFolder.unread,
    MailSmartFolder.inbox,
  ];

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      selectedIndex: currentIndex.clamp(0, _views.length),
      onDestinationSelected: (index) {
        if (index == _views.length) {
          onOpenFolders();
          return;
        }
        onSelectView(_views[index]);
      },
      destinations: [
        for (final view in _views)
          NavigationDestination(
            icon: Icon(_iconForSmartFolder(view)),
            label: _labelForSmartFolder(view),
          ),
        const NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder),
          label: 'Folders',
        ),
      ],
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
