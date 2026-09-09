/// How new-mail notifications are grouped in the system tray.
enum NotificationGrouping {
  /// Every account's new mail collapses into one expandable stack.
  stack,

  /// Each mailbox gets its own channel and its own stack.
  perAccount,

  /// Every message is a standalone notification with no grouping.
  individual,
}

extension NotificationGroupingDetails on NotificationGrouping {
  String get storageValue {
    return switch (this) {
      NotificationGrouping.stack => 'stack',
      NotificationGrouping.perAccount => 'per_account',
      NotificationGrouping.individual => 'individual',
    };
  }

  String get label {
    return switch (this) {
      NotificationGrouping.stack => 'Stack into one group',
      NotificationGrouping.perAccount => 'One group per account',
      NotificationGrouping.individual => 'One notification each',
    };
  }

  String get description {
    return switch (this) {
      NotificationGrouping.stack =>
        'New mail from every account collapses into a single expandable stack.',
      NotificationGrouping.perAccount =>
        'Each mailbox gets its own notification channel and stack, so you can '
            'tune or mute them separately.',
      NotificationGrouping.individual =>
        'Every message shows as a separate notification with no grouping.',
    };
  }
}

NotificationGrouping notificationGroupingFromStorage(String? value) {
  return switch (value?.trim()) {
    'per_account' => NotificationGrouping.perAccount,
    'individual' => NotificationGrouping.individual,
    _ => NotificationGrouping.stack,
  };
}
