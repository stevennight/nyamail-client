part of '../mail_home_page.dart';

/// One row of the message list: a section header, a message, or a Smart
/// Inbox bundle that stands for several automated messages.
sealed class _MailListEntry {
  const _MailListEntry();
}

class _MailListHeaderEntry extends _MailListEntry {
  const _MailListHeaderEntry(this.label);

  final String label;
}

class _MailListMessageEntry extends _MailListEntry {
  const _MailListMessageEntry(this.message, {this.inBundle = false});

  final MailMessage message;
  final bool inBundle;
}

class _MailListBundleEntry extends _MailListEntry {
  const _MailListBundleEntry({
    required this.category,
    required this.messages,
    required this.expanded,
  });

  final MailCategory category;

  /// Newest first.
  final List<MailMessage> messages;
  final bool expanded;

  int get unreadCount => messages.where((message) => !message.read).length;
  MailMessage get newest => messages.first;
}

/// Whether [view] is an incoming view where Smart Inbox bundles make sense.
bool _viewSupportsSmartInbox(MailboxView view) {
  final folder = view.folder;
  if (folder != null) return folder.kind == MailboxKind.inbox;
  return switch (view.smartFolder) {
    MailSmartFolder.allIncoming ||
    MailSmartFolder.inbox ||
    MailSmartFolder.unread => true,
    _ => false,
  };
}

/// Lays out [messages] (already in display order, pinned first) as list rows:
/// a Pinned section, then date sections. With [groupBundles], notifications
/// and newsletters collapse into one bundle row each, placed where their
/// newest message would have been.
List<_MailListEntry> _buildMailListEntries({
  required List<MailMessage> messages,
  required Set<String> pinnedMessageIds,
  required bool groupBundles,
  Set<MailCategory> expandedBundles = const {},
  DateTime? now,
}) {
  final entries = <_MailListEntry>[];
  final reference = (now ?? DateTime.now()).toLocal();
  final pinned = [
    for (final message in messages)
      if (pinnedMessageIds.contains(message.id)) message,
  ];
  if (pinned.isNotEmpty) {
    entries.add(const _MailListHeaderEntry('Pinned'));
    for (final message in pinned) {
      entries.add(_MailListMessageEntry(message));
    }
  }

  final bundled = <MailCategory, List<MailMessage>>{};
  if (groupBundles) {
    for (final message in messages) {
      if (pinnedMessageIds.contains(message.id)) continue;
      final category = message.effectiveCategory;
      if (category == MailCategory.people) continue;
      bundled.putIfAbsent(category, () => []).add(message);
    }
    // A lone automated message reads better as a normal row.
    bundled.removeWhere((_, members) => members.length < 2);
  }

  String? currentSection;
  void startSection(DateTime date) {
    final label = _mailListSectionLabel(date, reference);
    if (label == currentSection) return;
    currentSection = label;
    entries.add(_MailListHeaderEntry(label));
  }

  final emittedBundles = <MailCategory>{};
  for (final message in messages) {
    if (pinnedMessageIds.contains(message.id)) continue;
    final bundle = bundled[message.effectiveCategory];
    if (bundle == null) {
      startSection(message.receivedAt);
      entries.add(_MailListMessageEntry(message));
      continue;
    }
    final category = message.effectiveCategory;
    if (!emittedBundles.add(category)) continue;
    startSection(message.receivedAt);
    final expanded = expandedBundles.contains(category);
    entries.add(
      _MailListBundleEntry(
        category: category,
        messages: bundle,
        expanded: expanded,
      ),
    );
    if (expanded) {
      for (final member in bundle) {
        entries.add(_MailListMessageEntry(member, inBundle: true));
      }
    }
  }
  return entries;
}

/// Message order as the list shows it with every bundle expanded; used for
/// keyboard navigation so Up/Down follow what is on screen.
List<MailMessage> _mailListNavigationOrder({
  required List<MailMessage> messages,
  required Set<String> pinnedMessageIds,
  required bool groupBundles,
}) {
  if (!groupBundles) return messages;
  return [
    for (final entry in _buildMailListEntries(
      messages: messages,
      pinnedMessageIds: pinnedMessageIds,
      groupBundles: true,
      expandedBundles: MailCategory.values.toSet(),
    ))
      if (entry is _MailListMessageEntry) entry.message,
  ];
}

String _mailListSectionLabel(DateTime date, DateTime reference) {
  final local = date.toLocal();
  final today = DateTime(reference.year, reference.month, reference.day);
  final day = DateTime(local.year, local.month, local.day);
  final age = today.difference(day).inDays;
  if (age <= 0) return 'Today';
  if (age == 1) return 'Yesterday';
  if (age < 7) return 'Last 7 days';
  if (local.year == reference.year && local.month == reference.month) {
    return 'Earlier this month';
  }
  if (local.year == reference.year) return _monthNames[local.month - 1];
  return '${_monthNames[local.month - 1]} ${local.year}';
}

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _labelForMailCategory(MailCategory category) {
  return switch (category) {
    MailCategory.people => 'People',
    MailCategory.notification => 'Notifications',
    MailCategory.newsletter => 'Newsletters',
  };
}

IconData _iconForMailCategory(MailCategory category) {
  return switch (category) {
    MailCategory.people => Icons.person_outline,
    MailCategory.notification => Icons.notifications_none,
    MailCategory.newsletter => Icons.newspaper_outlined,
  };
}

Color _colorForMailCategory(MailCategory category, ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (category) {
    MailCategory.people => scheme.primary,
    MailCategory.notification =>
      dark ? const Color(0xFFF2B35B) : const Color(0xFFD9822B),
    MailCategory.newsletter =>
      dark ? const Color(0xFF5CC8A8) : const Color(0xFF1E9E7A),
  };
}

/// Round initial avatar for a sender, with an optional account colour dot.
class _SenderAvatar extends StatelessWidget {
  const _SenderAvatar({required this.from, this.size = 38, this.accountColor});

  final String from;
  final double size;
  final Color? accountColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final name = _displaySender(from);
    final address = _senderAddress(from);
    final color = _senderAvatarColor(
      address.isNotEmpty ? address : name,
      colorScheme,
    );
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black;
    final avatar = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        _senderInitial(name.isNotEmpty ? name : address),
        style: TextStyle(
          color: onColor,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.42,
          height: 1,
        ),
      ),
    );
    final dotColor = accountColor;
    if (dotColor == null) return avatar;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
