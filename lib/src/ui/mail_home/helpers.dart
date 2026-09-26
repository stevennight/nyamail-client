part of '../mail_home_page.dart';

class _LoginPasswordMemory {
  static String? _password;

  static Future<void> write(String password) async {
    _password = password;
  }

  static Future<void> clear() async {
    _password = null;
  }

  static Future<String?> read() async => _password;
}

IconData _iconForMailbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.inbox => Icons.inbox_outlined,
    MailboxKind.sent => Icons.send_outlined,
    MailboxKind.drafts => Icons.drafts_outlined,
    MailboxKind.archive => Icons.archive_outlined,
    MailboxKind.spam => Icons.report_gmailerrorred_outlined,
    MailboxKind.trash => Icons.delete_outline,
    MailboxKind.custom => Icons.folder_outlined,
  };
}

String _labelForMailbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.inbox => 'Inbox',
    MailboxKind.sent => 'Sent',
    MailboxKind.drafts => 'Drafts',
    MailboxKind.archive => 'Archive',
    MailboxKind.spam => 'Spam',
    MailboxKind.trash => 'Trash',
    MailboxKind.custom => 'Folder',
  };
}

String _localFolderPathFor(MailboxKind mailbox) {
  return switch (mailbox) {
    MailboxKind.inbox => 'INBOX',
    MailboxKind.sent => 'Sent',
    MailboxKind.drafts => 'Drafts',
    MailboxKind.archive => 'Archive',
    MailboxKind.spam => 'Spam',
    MailboxKind.trash => 'Trash',
    MailboxKind.custom => 'Folder',
  };
}

bool _canMoveToInbox(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.archive ||
    MailboxKind.spam ||
    MailboxKind.trash ||
    MailboxKind.custom => true,
    MailboxKind.inbox || MailboxKind.sent || MailboxKind.drafts => false,
  };
}

bool _mailListActionAppliesToMessage(
  MailListActionPreference action,
  MailMessage message,
) {
  final mailbox = message.effectiveMailbox;
  return switch (action) {
    MailListActionPreference.archive => mailbox != MailboxKind.archive,
    MailListActionPreference.delete => mailbox != MailboxKind.trash,
    MailListActionPreference.moveToInbox => _canMoveToInbox(mailbox),
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.toggleStar => true,
  };
}

IconData _mailListActionIcon(
  MailListActionPreference action, {
  MailMessage? message,
  bool? read,
  bool? starred,
  bool? pinned,
}) {
  final effectiveRead = read ?? message?.read;
  final effectiveStarred = starred ?? message?.starred;
  final effectivePinned = pinned ?? false;
  return switch (action) {
    MailListActionPreference.pin =>
      effectivePinned ? Icons.push_pin : Icons.push_pin_outlined,
    MailListActionPreference.delete => Icons.delete_outline,
    MailListActionPreference.toggleRead =>
      effectiveRead == true
          ? Icons.mark_email_unread_outlined
          : Icons.mark_email_read_outlined,
    MailListActionPreference.toggleStar =>
      effectiveStarred == true ? Icons.star : Icons.star_border,
    MailListActionPreference.archive => Icons.archive_outlined,
    MailListActionPreference.moveToInbox => Icons.move_to_inbox_outlined,
  };
}

String _mailListActionLabel(
  MailListActionPreference action, {
  MailMessage? message,
  bool? read,
  bool? starred,
  bool? pinned,
}) {
  final effectiveRead = read ?? message?.read;
  final effectiveStarred = starred ?? message?.starred;
  final effectivePinned = pinned ?? false;
  return switch (action) {
    MailListActionPreference.pin => effectivePinned ? 'Unpin' : 'Pin',
    MailListActionPreference.delete => 'Delete',
    MailListActionPreference.toggleRead =>
      effectiveRead == true ? 'Mark unread' : 'Mark read',
    MailListActionPreference.toggleStar =>
      effectiveStarred == true ? 'Unstar' : 'Star',
    MailListActionPreference.archive => 'Archive',
    MailListActionPreference.moveToInbox => 'Move to inbox',
  };
}

Color _mailListActionColor(
  MailListActionPreference action,
  ColorScheme colorScheme,
) {
  return switch (action) {
    MailListActionPreference.delete => colorScheme.errorContainer,
    MailListActionPreference.toggleStar => colorScheme.tertiaryContainer,
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.archive ||
    MailListActionPreference.moveToInbox => colorScheme.primaryContainer,
  };
}

Color _mailListActionForegroundColor(
  MailListActionPreference action,
  ColorScheme colorScheme,
) {
  return switch (action) {
    MailListActionPreference.delete => colorScheme.onErrorContainer,
    MailListActionPreference.toggleStar => colorScheme.onTertiaryContainer,
    MailListActionPreference.pin ||
    MailListActionPreference.toggleRead ||
    MailListActionPreference.archive ||
    MailListActionPreference.moveToInbox => colorScheme.onPrimaryContainer,
  };
}

IconData _iconForSmartFolder(MailSmartFolder folder) {
  return switch (folder) {
    MailSmartFolder.allIncoming => Icons.all_inbox_outlined,
    MailSmartFolder.unread => Icons.mark_email_unread_outlined,
    MailSmartFolder.inbox => Icons.inbox_outlined,
    MailSmartFolder.sent => Icons.send_outlined,
    MailSmartFolder.drafts => Icons.drafts_outlined,
    MailSmartFolder.archive => Icons.archive_outlined,
    MailSmartFolder.spam => Icons.report_gmailerrorred_outlined,
    MailSmartFolder.trash => Icons.delete_outline,
  };
}

String _labelForSmartFolder(MailSmartFolder folder) {
  return switch (folder) {
    MailSmartFolder.allIncoming => 'All incoming',
    MailSmartFolder.unread => 'Unread',
    MailSmartFolder.inbox => 'Inbox',
    MailSmartFolder.sent => 'Sent',
    MailSmartFolder.drafts => 'Drafts',
    MailSmartFolder.archive => 'Archive',
    MailSmartFolder.spam => 'Spam',
    MailSmartFolder.trash => 'Trash',
  };
}

String _labelForMailboxView(MailboxView view, List<MailAccount> accounts) {
  final smart = view.smartFolder;
  if (smart != null) return _labelForSmartFolder(smart);
  final folder = view.folder;
  if (folder == null) return 'Mail';
  MailAccount? account;
  for (final item in accounts) {
    if (item.id == folder.accountId) {
      account = item;
      break;
    }
  }
  final accountLabel =
      account == null
          ? folder.accountId
          : account.displayName.trim().isEmpty
          ? account.address
          : account.displayName;
  return '$accountLabel / ${folder.displayName}';
}

String _mailboxContextLabelForMessage(
  MailMessage? message,
  List<MailAccount> accounts,
) {
  if (message == null) return '';
  MailAccount? account;
  for (final item in accounts) {
    if (item.id == message.accountId) {
      account = item;
      break;
    }
  }
  final accountLabel =
      account == null
          ? message.accountId
          : account.displayName.trim().isEmpty
          ? account.address
          : account.displayName;
  final folderLabel =
      message.folderDisplayName.trim().isNotEmpty
          ? message.folderDisplayName.trim()
          : message.folderPath.trim().isNotEmpty
          ? message.folderPath.trim()
          : _labelForMailbox(message.effectiveMailbox);
  return accountLabel.trim().isEmpty
      ? folderLabel
      : '$accountLabel / $folderLabel';
}

String _defaultUsernameForAddress(String address) {
  return address.trim();
}

bool _providerSupportsOAuth(String provider) {
  return switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' || 'outlook' || 'microsoft' => true,
    _ => false,
  };
}

String _oauthProgressMessage(
  OAuthAuthorizationProgress progress,
  String provider,
) {
  final label = _providerLabel(provider);
  return switch (progress) {
    OAuthAuthorizationProgress.waitingForAuthorization =>
      'Waiting for $label authorization...',
    OAuthAuthorizationProgress.callbackReceived =>
      '$label callback received. Requesting token...',
    OAuthAuthorizationProgress.exchangingToken => 'Requesting $label token...',
  };
}

String _oauthValidationMessage(String provider) {
  final label = switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' => 'Google mailbox',
    'outlook' || 'microsoft' => 'Outlook mailbox',
    _ => '${provider.trim().isEmpty ? 'OAuth' : provider.trim()} mailbox',
  };
  return 'Validating $label access...';
}

String _providerLabel(String provider) {
  return switch (provider.trim().toLowerCase()) {
    'gmail' || 'google' => 'Google OAuth',
    'outlook' || 'microsoft' => 'Outlook OAuth',
    _ => '${provider.trim().isEmpty ? 'OAuth' : provider.trim()} OAuth',
  };
}

List<MailFolder> _foldersForAccount(
  List<MailFolder> folders,
  String accountId,
) {
  return folders
      .where((folder) => folder.accountId == accountId && folder.selectable)
      .toList(growable: false);
}

IconData _iconForMailAppearance(MailAppearance appearance) {
  return switch (appearance) {
    MailAppearance.automatic => Icons.brightness_auto_outlined,
    MailAppearance.light => Icons.light_mode_outlined,
    MailAppearance.dark => Icons.dark_mode_outlined,
  };
}

_MessageAppearanceAction _messageAppearanceActionFor(
  MailAppearance appearance,
) {
  return switch (appearance) {
    MailAppearance.automatic => _MessageAppearanceAction.automatic,
    MailAppearance.light => _MessageAppearanceAction.light,
    MailAppearance.dark => _MessageAppearanceAction.dark,
  };
}

String _attachmentKey(MailAttachment attachment) {
  return '${attachment.partId}:${attachment.filename}';
}

String _outgoingAttachmentSubtitle(OutgoingAttachment attachment) {
  return '${attachment.contentType} - ${_formatBytes(attachment.bytes.length)}';
}

String _attachmentSubtitle(MailAttachment attachment) {
  final size = attachment.size;
  if (size == null) return attachment.contentType;
  return '${attachment.contentType} - ${_formatBytes(size)}';
}

String _formatBytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _syncStatusTitle(_SyncAccountStatus status) {
  if (status.hasError) return 'Sync status unavailable';
  if (!status.hasRecordVault) return 'Record vault not initialized';
  if (status.dirtyRecordCount > 0) {
    return '${status.dirtyRecordCount} pending local change${status.dirtyRecordCount == 1 ? '' : 's'}';
  }
  return 'Record vault is synced';
}

String _syncStatusSubtitle(_SyncAccountStatus status) {
  if (status.hasError) return status.error!;
  return [
    'Last sync: ${_formatSyncDateTime(status.lastSyncedAt)}',
    'Cursor: ${status.cursor}',
    'Records: ${status.recordCount}',
    'Pending: ${status.dirtyRecordCount}',
    if (status.tombstoneCount > 0) 'Tombstones: ${status.tombstoneCount}',
  ].join(' - ');
}

String _formatSyncDateTime(DateTime? value) {
  if (value == null) return 'Never';
  final local = value.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _contentTypeForFilename(String filename) {
  final parts = filename.toLowerCase().split('.');
  final extension = parts.length > 1 ? parts.last : '';
  return switch (extension) {
    'txt' || 'text' => 'text/plain',
    'csv' => 'text/csv',
    'htm' || 'html' => 'text/html',
    'json' => 'application/json',
    'pdf' => 'application/pdf',
    'zip' => 'application/zip',
    'gz' => 'application/gzip',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    _ => 'application/octet-stream',
  };
}
