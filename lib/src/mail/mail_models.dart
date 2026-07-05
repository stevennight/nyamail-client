import 'dart:convert';

enum MailboxKind { inbox, sent, drafts, archive, spam, trash, custom }

const standardMailboxKinds = [
  MailboxKind.inbox,
  MailboxKind.sent,
  MailboxKind.drafts,
  MailboxKind.archive,
  MailboxKind.spam,
  MailboxKind.trash,
];

enum MailSmartFolder { allIncoming, inbox, sent, drafts, archive, spam, trash }

extension MailSmartFolderMailbox on MailSmartFolder {
  MailboxKind? get mailbox {
    return switch (this) {
      MailSmartFolder.allIncoming => null,
      MailSmartFolder.inbox => MailboxKind.inbox,
      MailSmartFolder.sent => MailboxKind.sent,
      MailSmartFolder.drafts => MailboxKind.drafts,
      MailSmartFolder.archive => MailboxKind.archive,
      MailSmartFolder.spam => MailboxKind.spam,
      MailSmartFolder.trash => MailboxKind.trash,
    };
  }
}

class MailFolder {
  const MailFolder({
    required this.accountId,
    required this.path,
    required this.displayName,
    this.displayPath = '',
    this.kind = MailboxKind.custom,
    this.delimiter = '/',
    this.selectable = true,
  });

  final String accountId;
  final String path;
  final String displayName;
  final String displayPath;
  final MailboxKind kind;
  final String delimiter;
  final bool selectable;

  String get key => '$accountId:$path';
  String get effectiveDisplayPath {
    final display = displayPath.trim();
    return display.isEmpty ? displayName : display;
  }

  bool get isIncoming {
    return selectable &&
        !const {
          MailboxKind.sent,
          MailboxKind.drafts,
          MailboxKind.archive,
          MailboxKind.spam,
          MailboxKind.trash,
        }.contains(kind);
  }
}

class MailboxView {
  const MailboxView.smart(this.smartFolder) : folder = null;
  const MailboxView.folder(this.folder) : smartFolder = null;

  final MailSmartFolder? smartFolder;
  final MailFolder? folder;

  bool get isSmart => smartFolder != null;

  String get key {
    final smart = smartFolder;
    if (smart != null) return 'smart:${smart.name}';
    final folder = this.folder!;
    return 'folder:${folder.accountId}:${folder.path}';
  }
}

class MailAccount {
  const MailAccount({
    required this.id,
    required this.address,
    required this.displayName,
    required this.provider,
    this.mailboxId,
  });

  final String id;
  final String address;
  final String displayName;
  final String provider;
  final String? mailboxId;
}

class MailMessage {
  const MailMessage({
    required this.id,
    required this.accountId,
    required this.from,
    required this.subject,
    required this.preview,
    required this.body,
    required this.receivedAt,
    this.htmlBody = '',
    this.to = const [],
    this.cc = const [],
    this.replyTo = const [],
    this.mailbox = MailboxKind.inbox,
    this.folderPath = '',
    this.folderDisplayName = '',
    this.read = false,
    this.starred = false,
    this.hasAttachments = false,
    this.attachments = const [],
    this.bodyLoaded = true,
  });

  final String id;
  final String accountId;
  final String from;
  final String subject;
  final String preview;
  final String body;
  final String htmlBody;
  final DateTime receivedAt;
  final List<String> to;
  final List<String> cc;
  final List<String> replyTo;
  final MailboxKind mailbox;
  final String folderPath;
  final String folderDisplayName;
  final bool read;
  final bool starred;
  final bool hasAttachments;
  final List<MailAttachment> attachments;
  final bool bodyLoaded;

  MailMessage copyWith({
    String? id,
    String? accountId,
    String? from,
    String? subject,
    String? preview,
    String? body,
    String? htmlBody,
    DateTime? receivedAt,
    List<String>? to,
    List<String>? cc,
    List<String>? replyTo,
    MailboxKind? mailbox,
    String? folderPath,
    String? folderDisplayName,
    bool? read,
    bool? starred,
    bool? hasAttachments,
    List<MailAttachment>? attachments,
    bool? bodyLoaded,
  }) {
    return MailMessage(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      from: from ?? this.from,
      subject: subject ?? this.subject,
      preview: preview ?? this.preview,
      body: body ?? this.body,
      htmlBody: htmlBody ?? this.htmlBody,
      receivedAt: receivedAt ?? this.receivedAt,
      to: to ?? this.to,
      cc: cc ?? this.cc,
      replyTo: replyTo ?? this.replyTo,
      mailbox: mailbox ?? this.mailbox,
      folderPath: folderPath ?? this.folderPath,
      folderDisplayName: folderDisplayName ?? this.folderDisplayName,
      read: read ?? this.read,
      starred: starred ?? this.starred,
      hasAttachments: hasAttachments ?? this.hasAttachments,
      attachments: attachments ?? this.attachments,
      bodyLoaded: bodyLoaded ?? this.bodyLoaded,
    );
  }

  String get effectiveFolderPath {
    final path = folderPath.trim();
    return path.isEmpty ? mailbox.name : path;
  }

  MailboxKind get effectiveMailbox {
    final folderName =
        folderPath.trim().isNotEmpty ? folderPath : folderDisplayName;
    if (folderName.trim().isEmpty) return mailbox;
    return inferMailboxKindFromFolderName(folderName) ?? mailbox;
  }
}

class MailAttachment {
  const MailAttachment({
    required this.filename,
    required this.contentType,
    required this.partId,
    this.transferEncoding = '',
    this.size,
  });

  final String filename;
  final String contentType;
  final String partId;
  final String transferEncoding;
  final int? size;
}

List<String> mailMessageDetailLines(MailMessage message) {
  final lines = <String>['From ${message.from}'];
  if (message.to.isNotEmpty) {
    lines.add('To ${message.to.join(', ')}');
  }
  if (message.cc.isNotEmpty) {
    lines.add('Cc ${message.cc.join(', ')}');
  }
  if (message.replyTo.isNotEmpty) {
    lines.add('Reply-To ${message.replyTo.join(', ')}');
  }
  lines.add('Date ${mailMessageDisplayDate(message.receivedAt)}');
  return lines;
}

String mailMessageDisplayDate(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

bool mailMessageMatchesQuery(MailMessage message, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  final haystacks = [
    message.subject,
    message.preview,
    message.from,
    message.body,
    ...message.to,
    ...message.cc,
    ...message.replyTo,
    for (final attachment in message.attachments) attachment.filename,
  ];
  return haystacks.any((value) => value.toLowerCase().contains(needle));
}

bool mailMessageMatchesSmartFolder(
  MailMessage message,
  MailSmartFolder folder,
) {
  final effectiveMailbox = message.effectiveMailbox;
  final mailbox = folder.mailbox;
  if (mailbox != null) return effectiveMailbox == mailbox;
  return !const {
    MailboxKind.sent,
    MailboxKind.drafts,
    MailboxKind.archive,
    MailboxKind.spam,
    MailboxKind.trash,
  }.contains(effectiveMailbox);
}

bool mailMessageMatchesFolder(MailMessage message, MailFolder folder) {
  if (message.accountId != folder.accountId) return false;
  if (message.folderPath.trim().isEmpty) {
    return message.effectiveMailbox == folder.kind &&
        folder.kind != MailboxKind.custom;
  }
  return message.effectiveFolderPath == folder.path;
}

MailboxKind? inferMailboxKindFromFolderName(String name) {
  final normalized = normalizeMailboxFolderName(name);
  for (final entry in _commonMailboxNames.entries) {
    for (final candidate in entry.value) {
      final normalizedCandidate = normalizeMailboxFolderName(candidate);
      if (normalized == normalizedCandidate ||
          normalized.endsWith('/$normalizedCandidate')) {
        return entry.key;
      }
    }
  }
  return null;
}

String normalizeMailboxFolderName(String value) {
  return decodeImapMailboxName(value).replaceAll('\\', '/').trim().toLowerCase();
}

String decodeImapMailboxName(String value) {
  final output = StringBuffer();
  var index = 0;
  while (index < value.length) {
    final ampersand = value.indexOf('&', index);
    if (ampersand == -1) {
      output.write(value.substring(index));
      break;
    }
    output.write(value.substring(index, ampersand));
    final end = value.indexOf('-', ampersand + 1);
    if (end == -1) {
      output.write(value.substring(ampersand));
      break;
    }
    if (end == ampersand + 1) {
      output.write('&');
      index = end + 1;
      continue;
    }
    final encoded = value.substring(ampersand + 1, end).replaceAll(',', '/');
    try {
      final padding = (4 - encoded.length % 4) % 4;
      final bytes = base64.decode(encoded + ('=' * padding));
      if (bytes.length.isOdd) {
        output.write(value.substring(ampersand, end + 1));
      } else {
        final codeUnits = <int>[];
        for (var i = 0; i < bytes.length; i += 2) {
          codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
        }
        output.write(String.fromCharCodes(codeUnits));
      }
    } on FormatException {
      output.write(value.substring(ampersand, end + 1));
    }
    index = end + 1;
  }
  return output.toString();
}

const Map<MailboxKind, List<String>> _commonMailboxNames = {
  MailboxKind.inbox: ['inbox'],
  MailboxKind.sent: [
    'sent',
    'sent mail',
    'sent messages',
    'sent items',
    '已发送',
    '已发送邮件',
    '发件箱',
  ],
  MailboxKind.drafts: ['drafts', 'draft', '草稿', '草稿箱'],
  MailboxKind.archive: [
    'archive',
    'archives',
    'all mail',
    '存档',
    '归档',
    '所有邮件',
  ],
  MailboxKind.spam: [
    'spam',
    'junk',
    'junk mail',
    'junk email',
    '垃圾邮件',
  ],
  MailboxKind.trash: [
    'trash',
    'deleted',
    'deleted mail',
    'deleted messages',
    'deleted items',
    'bin',
    '回收站',
    '已删除',
    '已删除邮件',
    '废纸篓',
    '垃圾桶',
    '垃圾箱',
  ],
};
