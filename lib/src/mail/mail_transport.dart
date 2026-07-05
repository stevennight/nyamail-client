import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mail_models.dart';

const _messagePreviewFetchBytes = 32 * 1024;

class MailboxCredential {
  const MailboxCredential({
    required this.accountId,
    required this.address,
    required this.displayName,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.username,
    required this.secret,
    this.authType = MailboxAuthType.password,
    this.useTls = true,
  });

  final String accountId;
  final String address;
  final String displayName;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final String username;
  final String secret;
  final MailboxAuthType authType;
  final bool useTls;
}

enum MailboxAuthType { password, oauth2 }

extension _MailboxCredentialTlsMode on MailboxCredential {
  bool get usesImplicitSmtpTls => useTls && smtpPort == 465;
  bool get usesStartTlsSmtp => useTls && !usesImplicitSmtpTls;
}

class OutgoingMessage {
  const OutgoingMessage({
    required this.from,
    required this.to,
    required this.subject,
    required this.textBody,
    this.htmlBody = '',
    this.cc = const [],
    this.bcc = const [],
    this.attachments = const [],
    this.date,
  });

  final String from;
  final List<String> to;
  final List<String> cc;
  final List<String> bcc;
  final String subject;
  final String textBody;
  final String htmlBody;
  final List<OutgoingAttachment> attachments;
  final DateTime? date;

  List<String> get envelopeRecipients => [...to, ...cc, ...bcc];
}

class OutgoingAttachment {
  const OutgoingAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  final String filename;
  final String contentType;
  final List<int> bytes;
}

class DownloadedAttachment {
  const DownloadedAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  final String filename;
  final String contentType;
  final List<int> bytes;
}

abstract class MailTransport {
  Future<void> validateCredential({required MailboxCredential credential});

  Future<List<MailFolder>> listFolders({required MailboxCredential credential});

  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  });

  Future<List<MailMessage>> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  });

  Future<List<MailMessage>> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  });

  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  });

  Future<List<MailMessage>> fetchInbox({
    required MailboxCredential credential,
    int limit = 30,
  });

  Future<void> send({
    required MailboxCredential credential,
    required OutgoingMessage message,
  });

  Future<void> setSeen({
    required MailboxCredential credential,
    required String messageId,
    required bool seen,
  });

  Future<void> setFlagged({
    required MailboxCredential credential,
    required String messageId,
    required bool flagged,
  });

  Future<void> moveMessage({
    required MailboxCredential credential,
    required String messageId,
    required MailboxKind destination,
  });

  Future<DownloadedAttachment> downloadAttachment({
    required MailboxCredential credential,
    required String messageId,
    required MailAttachment attachment,
  });
}

class SocketMailTransport implements MailTransport {
  const SocketMailTransport();

  @override
  Future<void> validateCredential({
    required MailboxCredential credential,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      await imap.listMailboxes();
    } finally {
      await imap.close();
    }

    final smtp = await _SmtpConnection.connect(credential);
    try {
      await smtp.login();
    } finally {
      await smtp.close();
    }
  }

  @override
  Future<List<MailFolder>> listFolders({
    required MailboxCredential credential,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final mailboxes = await imap.listMailboxes();
      return _foldersFromList(credential, mailboxes);
    } finally {
      await imap.close();
    }
  }

  @override
  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      final folder = _standardFolderForMailbox(
        credential: credential,
        mailbox: mailbox,
        path: resolver.nameFor(mailbox),
      );
      await imap.selectMailbox(folder.path);
      final uids = await imap.uidSearchAll();
      final messages = <MailMessage>[];
      for (final uid in _selectUidPage(uids, limit: limit)) {
        final fetched = await imap.uidFetchMessage(uid);
        messages.add(
          parseRfc822Message(
            fetched.raw,
            id: _messageId(credential.accountId, mailbox, uid),
            accountId: credential.accountId,
            mailbox: mailbox,
            folderPath: folder.path,
            folderDisplayName: folder.displayName,
            read: fetched.flags.contains(r'\Seen'),
            starred: fetched.flags.contains(r'\Flagged'),
          ),
        );
      }
      return messages;
    } finally {
      await imap.close();
    }
  }

  @override
  Future<List<MailMessage>> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      final folder = _standardFolderForMailbox(
        credential: credential,
        mailbox: mailbox,
        path: resolver.nameFor(mailbox),
      );
      await imap.selectMailbox(folder.path);
      final uids = await imap.uidSearchAll();
      final messages = <MailMessage>[];
      for (final uid in _selectUidPage(
        uids,
        limit: limit,
        beforeUid: beforeUid,
      )) {
        final fetched = await imap.uidFetchMessagePreview(uid);
        final parsed = parseRfc822Message(
          fetched.raw,
          id: _messageId(credential.accountId, mailbox, uid),
          accountId: credential.accountId,
          mailbox: mailbox,
          folderPath: folder.path,
          folderDisplayName: folder.displayName,
          read: fetched.flags.contains(r'\Seen'),
          starred: fetched.flags.contains(r'\Flagged'),
          bodyLoaded: false,
        );
        messages.add(
          parsed.copyWith(
            body: '',
            htmlBody: '',
            hasAttachments: false,
            attachments: const [],
            bodyLoaded: false,
          ),
        );
      }
      return messages;
    } finally {
      await imap.close();
    }
  }

  @override
  Future<List<MailMessage>> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      await imap.selectMailbox(folder.path);
      final uids = await imap.uidSearchAll();
      final messages = <MailMessage>[];
      for (final uid in _selectUidPage(
        uids,
        limit: limit,
        beforeUid: beforeUid,
      )) {
        final fetched = await imap.uidFetchMessagePreview(uid);
        final parsed = parseRfc822Message(
          fetched.raw,
          id: _messageIdForFolder(credential.accountId, folder, uid),
          accountId: credential.accountId,
          mailbox: folder.kind,
          folderPath: folder.path,
          folderDisplayName: folder.displayName,
          read: fetched.flags.contains(r'\Seen'),
          starred: fetched.flags.contains(r'\Flagged'),
          bodyLoaded: false,
        );
        messages.add(
          parsed.copyWith(
            body: '',
            htmlBody: '',
            hasAttachments: false,
            attachments: const [],
            bodyLoaded: false,
          ),
        );
      }
      return messages;
    } finally {
      await imap.close();
    }
  }

  @override
  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  }) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      final folderName = _folderNameForMessage(resolver, message);
      await imap.selectMailbox(folderName);
      final fetched = await imap.uidFetchMessage(_imapUid(message.id));
      return parseRfc822Message(
        fetched.raw,
        id: message.id,
        accountId: credential.accountId,
        mailbox: message.mailbox,
        folderPath: folderName,
        folderDisplayName: message.folderDisplayName,
        read: fetched.flags.contains(r'\Seen'),
        starred: fetched.flags.contains(r'\Flagged'),
        bodyLoaded: true,
      );
    } finally {
      await imap.close();
    }
  }

  @override
  Future<List<MailMessage>> fetchInbox({
    required MailboxCredential credential,
    int limit = 30,
  }) {
    return fetchMessages(
      credential: credential,
      mailbox: MailboxKind.inbox,
      limit: limit,
    );
  }

  @override
  Future<void> send({
    required MailboxCredential credential,
    required OutgoingMessage message,
  }) async {
    final smtp = await _SmtpConnection.connect(credential);
    final rawMessage = _formatOutgoingMessage(message);
    try {
      await smtp.login();
      await smtp.send(message, rawMessage: rawMessage);
    } finally {
      await smtp.close();
    }
    await _appendToSent(credential, rawMessage);
  }

  @override
  Future<void> setSeen({
    required MailboxCredential credential,
    required String messageId,
    required bool seen,
  }) {
    return _withImap(credential, messageId, (imap) {
      return imap.uidStoreFlag(_imapUid(messageId), r'\Seen', seen);
    });
  }

  @override
  Future<void> setFlagged({
    required MailboxCredential credential,
    required String messageId,
    required bool flagged,
  }) {
    return _withImap(credential, messageId, (imap) {
      return imap.uidStoreFlag(_imapUid(messageId), r'\Flagged', flagged);
    });
  }

  @override
  Future<void> moveMessage({
    required MailboxCredential credential,
    required String messageId,
    required MailboxKind destination,
  }) {
    return _withImap(credential, messageId, (imap) {
      final resolver = _ImapMailboxResolver.current(imap);
      return imap.uidMoveMessage(
        _imapUid(messageId),
        resolver.nameFor(destination),
      );
    });
  }

  @override
  Future<DownloadedAttachment> downloadAttachment({
    required MailboxCredential credential,
    required String messageId,
    required MailAttachment attachment,
  }) async {
    if (attachment.partId.isEmpty) {
      throw const MailTransportException(
        'Attachment part id is unavailable for this message.',
      );
    }
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      await imap.selectMailbox(_folderNameFromMessageId(resolver, messageId));
      final body = await imap.uidFetchBodyPartBytes(
        _imapUid(messageId),
        attachment.partId,
      );
      return DownloadedAttachment(
        filename: attachment.filename,
        contentType: attachment.contentType,
        bytes: _decodeTransferBytes(body, attachment.transferEncoding),
      );
    } finally {
      await imap.close();
    }
  }

  Future<void> _withImap(
    MailboxCredential credential,
    String messageId,
    Future<void> Function(_ImapConnection imap) action,
  ) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      imap.mailboxResolver = resolver;
      await imap.selectMailbox(_folderNameFromMessageId(resolver, messageId));
      await action(imap);
    } finally {
      await imap.close();
    }
  }

  Future<void> _appendToSent(
    MailboxCredential credential,
    String rawMessage,
  ) async {
    final imap = await _ImapConnection.connect(credential);
    try {
      await imap.login();
      final resolver = await _ImapMailboxResolver.discover(imap);
      await imap.appendMessage(
        resolver.nameFor(MailboxKind.sent),
        rawMessage,
        flags: const [r'\Seen'],
      );
    } finally {
      await imap.close();
    }
  }
}

MailMessage parseRfc822Message(
  String raw, {
  required String id,
  required String accountId,
  MailboxKind mailbox = MailboxKind.inbox,
  String folderPath = '',
  String folderDisplayName = '',
  bool read = false,
  bool starred = false,
  bool bodyLoaded = true,
}) {
  final parsed = _parseMimeEntity(raw);
  final headers = parsed.headers;
  final date = _parseMailDate(headers['date'] ?? '') ?? DateTime.now();
  final body = parsed.bestBody.replaceAll('\r\n', '\n').trim();
  final htmlBody = parsed.htmlBody.replaceAll('\r\n', '\n').trim();
  final preview = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return MailMessage(
    id: id,
    accountId: accountId,
    from: _decodeHeader(headers['from'] ?? 'Unknown sender'),
    to: _parseAddressHeader(headers['to'] ?? ''),
    cc: _parseAddressHeader(headers['cc'] ?? ''),
    replyTo: _parseAddressHeader(headers['reply-to'] ?? ''),
    subject: _decodeHeader(headers['subject'] ?? '(no subject)'),
    preview:
        preview.length <= 180 ? preview : '${preview.substring(0, 180)}...',
    body: body,
    htmlBody: htmlBody,
    receivedAt: date,
    mailbox: mailbox,
    folderPath: folderPath,
    folderDisplayName: folderDisplayName,
    read: read,
    starred: starred,
    hasAttachments: parsed.attachments.isNotEmpty,
    attachments: parsed.attachments,
    bodyLoaded: bodyLoaded,
  );
}

_ParsedMimeEntity _parseMimeEntity(String raw, {String partId = ''}) {
  final split = raw.split(RegExp(r'\r?\n\r?\n'));
  final headers = _parseHeaders(split.isEmpty ? '' : split.first);
  final body = split.length > 1 ? split.sublist(1).join('\n\n') : '';
  final contentType = _parseHeaderValue(
    headers['content-type'] ?? 'text/plain',
  );
  final disposition = _parseHeaderValue(headers['content-disposition'] ?? '');
  final transferEncoding =
      (headers['content-transfer-encoding'] ?? '').toLowerCase();

  if (contentType.value.toLowerCase().startsWith('multipart/')) {
    final boundary = contentType.params['boundary'];
    if (boundary == null || boundary.isEmpty) {
      return _ParsedMimeEntity(headers: headers, body: body);
    }
    final parts = _splitMultipart(body, boundary);
    final children = [
      for (var i = 0; i < parts.length; i++)
        _parseMimeEntity(
          parts[i],
          partId: partId.isEmpty ? '${i + 1}' : '$partId.${i + 1}',
        ),
    ];
    final plain =
        children
            .where((child) => child.contentType.startsWith('text/plain'))
            .map((child) => child.bestBody)
            .where((text) => text.trim().isNotEmpty)
            .firstOrNull;
    final html =
        children
            .map((child) => child.htmlBody)
            .where((text) => text.trim().isNotEmpty)
            .firstOrNull;
    final nested =
        children
            .map((child) => child.bestBody)
            .where((text) => text.trim().isNotEmpty)
            .firstOrNull;
    return _ParsedMimeEntity(
      headers: headers,
      body: plain ?? nested ?? (html == null ? '' : _htmlToText(html)),
      htmlBody: html ?? '',
      attachments: children.expand((child) => child.attachments).toList(),
      contentType: contentType.value.toLowerCase(),
    );
  }

  final decodedBody = _decodeBody(body, transferEncoding);
  final filename =
      disposition.params['filename'] ?? contentType.params['name'] ?? '';
  final lowerContentType = contentType.value.toLowerCase();
  final lowerDisposition = disposition.value.toLowerCase();
  final isAttachment =
      lowerDisposition == 'attachment' ||
      (filename.isNotEmpty && lowerDisposition != 'inline');
  return _ParsedMimeEntity(
    headers: headers,
    body:
        isAttachment
            ? ''
            : lowerContentType.startsWith('text/html')
            ? _htmlToText(decodedBody)
            : decodedBody,
    htmlBody:
        isAttachment || !lowerContentType.startsWith('text/html')
            ? ''
            : decodedBody,
    attachments:
        isAttachment
            ? [
              MailAttachment(
                filename: _decodeHeader(
                  filename.isEmpty ? 'attachment' : filename,
                ),
                contentType: lowerContentType,
                partId: partId,
                transferEncoding: transferEncoding,
                size: _decodedSize(body, transferEncoding),
              ),
            ]
            : const [],
    contentType: lowerContentType,
  );
}

Map<String, String> _parseHeaders(String rawHeaders) {
  final headers = <String, String>{};
  String? currentName;
  for (final line in rawHeaders.split(RegExp(r'\r?\n'))) {
    if ((line.startsWith(' ') || line.startsWith('\t')) &&
        currentName != null) {
      headers[currentName] = '${headers[currentName]} ${line.trim()}';
      continue;
    }
    final index = line.indexOf(':');
    if (index <= 0) continue;
    currentName = line.substring(0, index).toLowerCase();
    headers[currentName] = line.substring(index + 1).trim();
  }
  return headers;
}

_HeaderValue _parseHeaderValue(String value) {
  final parts = value.split(';');
  final params = <String, String>{};
  for (final part in parts.skip(1)) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    final name = part.substring(0, index).trim().toLowerCase();
    var paramValue = part.substring(index + 1).trim();
    if (paramValue.startsWith('"') && paramValue.endsWith('"')) {
      paramValue = paramValue.substring(1, paramValue.length - 1);
    }
    params[name] = paramValue;
  }
  return _HeaderValue(
    value: parts.first.trim().isEmpty ? 'text/plain' : parts.first.trim(),
    params: params,
  );
}

List<String> _splitMultipart(String body, String boundary) {
  final delimiter = '--$boundary';
  final parts = <String>[];
  final buffer = StringBuffer();
  var inside = false;
  for (final line in body.split(RegExp(r'\r?\n'))) {
    if (line == delimiter || line == '$delimiter--') {
      if (inside && buffer.isNotEmpty) {
        parts.add(buffer.toString().trimRight());
        buffer.clear();
      }
      inside = line == delimiter;
      continue;
    }
    if (inside) {
      buffer.writeln(line);
    }
  }
  if (inside && buffer.isNotEmpty) {
    parts.add(buffer.toString().trimRight());
  }
  return parts;
}

String _decodeBody(String body, String transferEncoding) {
  final normalized = transferEncoding.toLowerCase();
  if (normalized == 'base64') {
    try {
      return utf8.decode(_decodeBase64Body(body), allowMalformed: true);
    } on FormatException {
      return body;
    }
  }
  if (normalized == 'quoted-printable') {
    return _decodeQuotedPrintable(body);
  }
  return body;
}

List<int> _decodeTransferBytes(List<int> body, String transferEncoding) {
  final normalized = transferEncoding.toLowerCase();
  if (normalized == 'base64') {
    try {
      final encoded = ascii.decode(body, allowInvalid: true);
      return _decodeBase64Body(encoded);
    } on FormatException {
      return body;
    }
  }
  if (normalized == 'quoted-printable') {
    return _decodeQuotedPrintableBytes(ascii.decode(body, allowInvalid: true));
  }
  return body;
}

int? _decodedSize(String body, String transferEncoding) {
  if (transferEncoding.toLowerCase() == 'base64') {
    try {
      return _decodeBase64Body(body).length;
    } on FormatException {
      return null;
    }
  }
  return utf8.encode(body).length;
}

List<int> _decodeBase64Body(String value) {
  var normalized = value.replaceAll(RegExp(r'\s+'), '');
  while (normalized.isNotEmpty) {
    var candidate = normalized;
    final remainder = candidate.length % 4;
    if (remainder == 1) {
      candidate = candidate.substring(0, candidate.length - 1);
    } else if (remainder > 0) {
      candidate = candidate.padRight(candidate.length + 4 - remainder, '=');
    }
    try {
      return base64.decode(candidate);
    } on FormatException {
      normalized = normalized.substring(0, normalized.length - 1);
    }
  }
  throw const FormatException('Invalid base64 body');
}

String _decodeQuotedPrintable(String value) {
  return utf8.decode(_decodeQuotedPrintableBytes(value), allowMalformed: true);
}

List<int> _decodeQuotedPrintableBytes(String value) {
  final bytes = <int>[];
  for (var i = 0; i < value.length; i++) {
    final char = value.codeUnitAt(i);
    if (char == 61 && i + 2 < value.length) {
      if (value.codeUnitAt(i + 1) == 13 || value.codeUnitAt(i + 1) == 10) {
        while (i + 1 < value.length &&
            (value.codeUnitAt(i + 1) == 13 || value.codeUnitAt(i + 1) == 10)) {
          i++;
        }
        continue;
      }
      final hex = value.substring(i + 1, i + 3);
      final decoded = int.tryParse(hex, radix: 16);
      if (decoded != null) {
        bytes.add(decoded);
        i += 2;
        continue;
      }
    }
    bytes.add(char);
  }
  return bytes;
}

String _htmlToText(String value) {
  return value
      .replaceAll(RegExp(r'<(br|/p|/div)\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'<style.*?</style>', caseSensitive: false, dotAll: true),
        '',
      )
      .replaceAll(
        RegExp(r'<script.*?</script>', caseSensitive: false, dotAll: true),
        '',
      )
      .replaceAll(RegExp(r'<[^>]+>', dotAll: true), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
}

class _ParsedMimeEntity {
  const _ParsedMimeEntity({
    required this.headers,
    this.body = '',
    this.htmlBody = '',
    this.attachments = const [],
    this.contentType = 'text/plain',
  });

  final Map<String, String> headers;
  final String body;
  final String htmlBody;
  final List<MailAttachment> attachments;
  final String contentType;

  String get bestBody => body;
}

class _HeaderValue {
  const _HeaderValue({required this.value, required this.params});

  final String value;
  final Map<String, String> params;
}

String _decodeHeader(String value) {
  return decodeMailHeader(value);
}

String decodeMailHeader(String value) {
  final compactedEncodedWords = value.replaceAll(RegExp(r'\?=\s+=\?'), '?==?');
  final decoded = compactedEncodedWords.replaceAllMapped(
    RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?='),
    (match) {
      final charset = match.group(1) ?? 'utf-8';
      final encoding = (match.group(2) ?? '').toUpperCase();
      final encoded = match.group(3) ?? '';
      final bytes =
          encoding == 'B'
              ? _decodeHeaderBase64(encoded)
              : _decodeHeaderQuotedPrintable(encoded);
      if (bytes == null) return match.group(0) ?? '';
      return _decodeHeaderBytes(bytes, charset);
    },
  );
  return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<int>? _decodeHeaderBase64(String value) {
  try {
    return base64.decode(value.replaceAll(RegExp(r'\s+'), ''));
  } on FormatException {
    return null;
  }
}

List<int> _decodeHeaderQuotedPrintable(String value) {
  return _decodeQuotedPrintableBytes(value.replaceAll('_', ' '));
}

String _decodeHeaderBytes(List<int> bytes, String charset) {
  final normalized = charset.trim().toLowerCase();
  if (normalized == 'utf-8' || normalized == 'utf8') {
    return utf8.decode(bytes, allowMalformed: true);
  }
  if (normalized == 'us-ascii' || normalized == 'ascii') {
    return ascii.decode(bytes, allowInvalid: true);
  }
  if (normalized == 'iso-8859-1' || normalized == 'latin1') {
    return latin1.decode(bytes, allowInvalid: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

List<String> _parseAddressHeader(String value) {
  final angleMatches = RegExp(r'<([^>]+)>').allMatches(value).toList();
  if (angleMatches.isNotEmpty) {
    return [
      for (final match in angleMatches)
        if (match.group(1)!.trim().isNotEmpty) match.group(1)!.trim(),
    ];
  }
  return value
      .split(RegExp(r'[;,]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

DateTime? _parseMailDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed;
  final cleaned = value.replaceFirst(RegExp(r'^[A-Za-z]{3},\s*'), '').trim();
  final match = RegExp(
    r'^(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4})',
  ).firstMatch(cleaned);
  if (match == null) return null;
  const months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };
  final month = months[match.group(2)];
  if (month == null) return null;
  final offset = match.group(7)!;
  final offsetSign = offset.startsWith('-') ? -1 : 1;
  final offsetHours = int.parse(offset.substring(1, 3));
  final offsetMinutes = int.parse(offset.substring(3, 5));
  final local = DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6) ?? '0'),
  );
  return local.subtract(
    Duration(minutes: offsetSign * (offsetHours * 60 + offsetMinutes)),
  );
}

class _ImapConnection {
  _ImapConnection(this._socket, this._credential, this._reader);

  final Socket _socket;
  final MailboxCredential _credential;
  final _SocketLineReader _reader;
  _ImapMailboxResolver? mailboxResolver;
  int _tag = 0;

  static Future<_ImapConnection> connect(MailboxCredential credential) async {
    final socket =
        credential.useTls
            ? await SecureSocket.connect(
              credential.imapHost,
              credential.imapPort,
              timeout: const Duration(seconds: 20),
            )
            : await Socket.connect(
              credential.imapHost,
              credential.imapPort,
              timeout: const Duration(seconds: 20),
            );
    final connection = _ImapConnection(
      socket,
      credential,
      _SocketLineReader(socket),
    );
    await connection._readGreeting();
    return connection;
  }

  Future<void> login() {
    if (_credential.authType == MailboxAuthType.oauth2) {
      return _command(
        'AUTHENTICATE XOAUTH2 ${_oauth2InitialClientResponse(_credential)}',
      );
    }
    return _command(
      'LOGIN "${_escape(_credential.username)}" "${_escape(_credential.secret)}"',
    );
  }

  Future<void> selectInbox() {
    return selectMailbox('INBOX');
  }

  Future<void> selectMailbox(String mailbox) {
    return _command('SELECT "${_escape(mailbox)}"');
  }

  Future<List<_ImapMailboxInfo>> listMailboxes() async {
    final lines = await _commandLines('LIST "" "*"');
    return [
      for (final line in lines)
        if (line.startsWith('* LIST')) _parseListLine(line),
    ];
  }

  Future<List<int>> searchAll() async {
    return uidSearchAll();
  }

  Future<List<int>> uidSearchAll() async {
    final lines = await _commandLines('UID SEARCH ALL');
    for (final line in lines) {
      if (line.startsWith('* SEARCH')) {
        return line
            .substring('* SEARCH'.length)
            .trim()
            .split(' ')
            .where((part) => part.trim().isNotEmpty)
            .map(int.parse)
            .toList();
      }
    }
    return const [];
  }

  Future<String> fetchRfc822(int id) async {
    return (await uidFetchMessage(id)).raw;
  }

  Future<_FetchedImapMessage> fetchMessage(int id) async {
    return uidFetchMessage(id);
  }

  Future<_FetchedImapMessage> uidFetchMessage(int uid) async {
    final response = await _fetchLiteralBytes(
      'UID FETCH $uid (FLAGS BODY.PEEK[])',
    );
    return _FetchedImapMessage(
      raw: response.chunks
          .map((bytes) => utf8.decode(bytes, allowMalformed: true))
          .join('\n'),
      flags: _parseFetchFlags(response.lines),
    );
  }

  Future<_FetchedImapMessage> uidFetchMessagePreview(int uid) async {
    final response = await _fetchLiteralBytes(
      'UID FETCH $uid (FLAGS BODY.PEEK[]<0.$_messagePreviewFetchBytes>)',
    );
    return _FetchedImapMessage(
      raw: response.chunks
          .map((bytes) => utf8.decode(bytes, allowMalformed: true))
          .join('\n'),
      flags: _parseFetchFlags(response.lines),
    );
  }

  Future<List<int>> fetchBodyPartBytes(int id, String partId) async {
    return uidFetchBodyPartBytes(id, partId);
  }

  Future<List<int>> uidFetchBodyPartBytes(int uid, String partId) async {
    final normalizedPartId = partId.trim();
    if (!RegExp(r'^\d+(?:\.\d+)*$').hasMatch(normalizedPartId)) {
      throw MailTransportException('Invalid IMAP body part id: $partId');
    }
    final response = await _fetchLiteralBytes(
      'UID FETCH $uid BODY.PEEK[$normalizedPartId]',
    );
    final chunks = response.chunks;
    if (chunks.length == 1) return chunks.single;
    return [for (final chunk in chunks) ...chunk];
  }

  Future<_FetchLiteralResponse> _fetchLiteralBytes(String command) async {
    final tag = _nextTag();
    final chunks = <List<int>>[];
    final lines = <String>[];
    _socket.write('$tag $command\r\n');
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      lines.add(line);
      if (line.startsWith('$tag OK')) {
        return _FetchLiteralResponse(lines: lines, chunks: chunks);
      }
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP fetch failed: $line');
      }
      final literal = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (literal != null) {
        final length = int.parse(literal.group(1)!);
        final bytes = await _reader
            .readBytes(length)
            .timeout(const Duration(seconds: 30));
        chunks.add(bytes);
      }
    }
  }

  Future<void> storeFlag(int id, String flag, bool enabled) {
    return uidStoreFlag(id, flag, enabled);
  }

  Future<void> uidStoreFlag(int uid, String flag, bool enabled) {
    final operation = enabled ? '+FLAGS.SILENT' : '-FLAGS.SILENT';
    return _command('UID STORE $uid $operation ($flag)');
  }

  Future<void> moveMessage(int id, String mailbox) async {
    return uidMoveMessage(id, mailbox);
  }

  Future<void> uidMoveMessage(int uid, String mailbox) async {
    try {
      await _command('UID MOVE $uid "${_escape(mailbox)}"');
    } on MailTransportException {
      await _command('UID COPY $uid "${_escape(mailbox)}"');
      await uidStoreFlag(uid, r'\Deleted', true);
      await _command('EXPUNGE');
    }
  }

  Future<void> appendMessage(
    String mailbox,
    String rawMessage, {
    List<String> flags = const [],
  }) async {
    final tag = _nextTag();
    final bytes = utf8.encode(rawMessage);
    final flagsPart = flags.isEmpty ? '' : ' (${flags.join(' ')})';
    _socket.write(
      '$tag APPEND "${_escape(mailbox)}"$flagsPart {${bytes.length}}\r\n',
    );
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (line.startsWith('+')) break;
      if (line.startsWith('$tag OK')) return;
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP append failed: $line');
      }
    }
    _socket.add(bytes);
    _socket.write('\r\n');
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (line.startsWith('$tag OK')) return;
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP append failed: $line');
      }
    }
  }

  Future<void> close() async {
    try {
      await _command('LOGOUT');
    } catch (_) {
      // Ignore logout failures; the socket is closing anyway.
    }
    await _reader.close();
    await _socket.close();
  }

  Future<void> _readGreeting() async {
    final line = await _reader.readLine().timeout(const Duration(seconds: 20));
    if (!line.contains('OK')) {
      throw MailTransportException('IMAP greeting failed: $line');
    }
  }

  Future<void> _command(String command) async {
    await _commandLines(command);
  }

  Future<List<String>> _commandLines(String command) async {
    final tag = _nextTag();
    final lines = <String>[];
    _socket.write('$tag $command\r\n');
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      lines.add(line);
      if (line.startsWith('$tag OK')) return lines;
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP command failed: $line');
      }
    }
  }

  String _nextTag() => 'A${(++_tag).toString().padLeft(4, '0')}';

  String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

class _ImapMailboxResolver {
  const _ImapMailboxResolver(this._names);

  final Map<MailboxKind, String> _names;

  static Future<_ImapMailboxResolver> discover(_ImapConnection imap) async {
    if (imap.mailboxResolver != null) return imap.mailboxResolver!;
    final resolver = _ImapMailboxResolver.fromList(await imap.listMailboxes());
    imap.mailboxResolver = resolver;
    return resolver;
  }

  static _ImapMailboxResolver current(_ImapConnection imap) {
    return imap.mailboxResolver ?? _ImapMailboxResolver.fallback();
  }

  factory _ImapMailboxResolver.fromList(List<_ImapMailboxInfo> mailboxes) {
    final names = <MailboxKind, String>{MailboxKind.inbox: 'INBOX'};
    for (final mailbox in mailboxes) {
      final kind = _kindFromAttributes(mailbox.attributes);
      if (kind != null) names.putIfAbsent(kind, () => mailbox.name);
    }
    for (final mailbox in mailboxes) {
      final kind = inferMailboxKindFromFolderName(mailbox.name);
      if (kind != null) names.putIfAbsent(kind, () => mailbox.name);
    }
    for (final kind in standardMailboxKinds) {
      names.putIfAbsent(kind, () => _fallbackName(kind));
    }
    return _ImapMailboxResolver(names);
  }

  factory _ImapMailboxResolver.fallback() {
    return _ImapMailboxResolver({
      for (final kind in standardMailboxKinds) kind: _fallbackName(kind),
    });
  }

  String nameFor(MailboxKind kind) => _names[kind] ?? _fallbackName(kind);
}

class _ImapMailboxInfo {
  const _ImapMailboxInfo({
    required this.attributes,
    required this.name,
    this.delimiter = '/',
  });

  final Set<String> attributes;
  final String name;
  final String delimiter;
}

MailboxKind? _kindFromAttributes(Set<String> attributes) {
  final lowered = attributes.map((item) => item.toLowerCase()).toSet();
  if (lowered.contains(r'\all') || lowered.contains(r'\archive')) {
    return MailboxKind.archive;
  }
  if (lowered.contains(r'\sent')) return MailboxKind.sent;
  if (lowered.contains(r'\drafts')) return MailboxKind.drafts;
  if (lowered.contains(r'\junk')) return MailboxKind.spam;
  if (lowered.contains(r'\trash')) return MailboxKind.trash;
  return null;
}

String _normalizeMailboxName(String value) {
  return normalizeMailboxFolderName(value);
}

String _fallbackName(MailboxKind kind) {
  return switch (kind) {
    MailboxKind.inbox => 'INBOX',
    MailboxKind.sent => 'Sent',
    MailboxKind.drafts => 'Drafts',
    MailboxKind.archive => 'Archive',
    MailboxKind.spam => 'Spam',
    MailboxKind.trash => 'Trash',
    MailboxKind.custom => 'Folder',
  };
}

List<MailFolder> _foldersFromList(
  MailboxCredential credential,
  List<_ImapMailboxInfo> mailboxes,
) {
  final resolver = _ImapMailboxResolver.fromList(mailboxes);
  final standardByNormalizedName = {
    for (final kind in standardMailboxKinds)
      _normalizeMailboxName(resolver.nameFor(kind)): kind,
  };
  final folders = <MailFolder>[];
  for (final mailbox in mailboxes) {
    final normalized = _normalizeMailboxName(mailbox.name);
    final kind =
        standardByNormalizedName[normalized] ??
        _kindFromAttributes(mailbox.attributes) ??
        inferMailboxKindFromFolderName(mailbox.name) ??
        MailboxKind.custom;
    folders.add(
      MailFolder(
        accountId: credential.accountId,
        path: mailbox.name,
        displayName: _displayNameForMailbox(mailbox.name, mailbox.delimiter),
        displayPath: _displayPathForMailbox(mailbox.name, mailbox.delimiter),
        kind: kind,
        delimiter: mailbox.delimiter,
        selectable:
            !mailbox.attributes
                .map((item) => item.toLowerCase())
                .contains(r'\noselect'),
      ),
    );
  }
  if (!folders.any((folder) => _normalizeMailboxName(folder.path) == 'inbox')) {
    folders.insert(
      0,
      _standardFolderForMailbox(
        credential: credential,
        mailbox: MailboxKind.inbox,
        path: 'INBOX',
      ),
    );
  }
  folders.sort((a, b) {
    final aIndex = _folderSortIndex(a.kind);
    final bIndex = _folderSortIndex(b.kind);
    if (aIndex != bIndex) return aIndex.compareTo(bIndex);
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });
  return folders;
}

MailFolder _standardFolderForMailbox({
  required MailboxCredential credential,
  required MailboxKind mailbox,
  required String path,
}) {
  return MailFolder(
    accountId: credential.accountId,
    path: path,
    displayName: _displayNameForMailbox(path, '/'),
    displayPath: _displayPathForMailbox(path, '/'),
    kind: mailbox,
  );
}

int _folderSortIndex(MailboxKind kind) {
  final index = standardMailboxKinds.indexOf(kind);
  return index == -1 ? standardMailboxKinds.length : index;
}

String _displayNameForMailbox(String name, String delimiter) {
  final normalizedDelimiter = delimiter.trim().isEmpty ? '/' : delimiter;
  final parts = name.split(normalizedDelimiter);
  final displayName = parts.isEmpty ? name : parts.last;
  return decodeImapMailboxName(displayName);
}

String _displayPathForMailbox(String name, String delimiter) {
  final normalizedDelimiter = delimiter.trim().isEmpty ? '/' : delimiter;
  return name
      .split(normalizedDelimiter)
      .map(decodeImapMailboxName)
      .join(normalizedDelimiter);
}

_ImapMailboxInfo _parseListLine(String line) {
  final attributesMatch = RegExp(r'\(([^)]*)\)').firstMatch(line);
  final attributes =
      attributesMatch == null
          ? <String>{}
          : attributesMatch
              .group(1)!
              .split(RegExp(r'\s+'))
              .where((item) => item.isNotEmpty)
              .toSet();
  final delimiterMatch = RegExp(
    r'\)\s+(?:"([^"]*)"|NIL)\s+',
    caseSensitive: false,
  ).firstMatch(line);
  final nameMatch = RegExp(r'(?:"([^"]*)"|([^\s]+))\s*$').firstMatch(line);
  final name = nameMatch?.group(1) ?? nameMatch?.group(2) ?? 'INBOX';
  return _ImapMailboxInfo(
    attributes: attributes,
    delimiter: delimiterMatch?.group(1) ?? '/',
    name: name.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'),
  );
}

class _FetchedImapMessage {
  const _FetchedImapMessage({required this.raw, required this.flags});

  final String raw;
  final Set<String> flags;
}

class _FetchLiteralResponse {
  const _FetchLiteralResponse({required this.lines, required this.chunks});

  final List<String> lines;
  final List<List<int>> chunks;
}

Set<String> _parseFetchFlags(List<String> lines) {
  final flags = <String>{};
  for (final line in lines) {
    final match = RegExp(
      r'FLAGS \(([^)]*)\)',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) continue;
    for (final flag in match.group(1)!.split(RegExp(r'\s+'))) {
      if (flag.isNotEmpty) flags.add(flag);
    }
  }
  return flags;
}

List<int> _selectUidPage(List<int> uids, {required int limit, int? beforeUid}) {
  final selected = [...uids]..sort((a, b) => b.compareTo(a));
  return selected
      .where((uid) => beforeUid == null || uid < beforeUid)
      .take(limit)
      .toList(growable: false);
}

String _messageId(String accountId, MailboxKind mailbox, int uid) {
  return '$accountId:${mailbox.name}:$uid';
}

String _messageIdForFolder(String accountId, MailFolder folder, int uid) {
  if (folder.kind != MailboxKind.custom) {
    return _messageId(accountId, folder.kind, uid);
  }
  final encoded = base64UrlEncode(utf8.encode(folder.path)).replaceAll('=', '');
  return '$accountId:folder:$encoded:$uid';
}

int _imapUid(String messageId) {
  final raw = messageId.contains(':') ? messageId.split(':').last : messageId;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw MailTransportException('Invalid IMAP UID in message id: $messageId');
  }
  return parsed;
}

String _folderNameForMessage(
  _ImapMailboxResolver resolver,
  MailMessage message,
) {
  final encodedFolderPath = _folderPathFromMessageId(message.id);
  if (encodedFolderPath != null) return encodedFolderPath;
  if (message.folderPath.trim().isNotEmpty) return message.folderPath;
  return resolver.nameFor(
    _mailboxFromMessageId(message.id, fallback: message.mailbox),
  );
}

String _folderNameFromMessageId(
  _ImapMailboxResolver resolver,
  String messageId,
) {
  final encodedFolderPath = _folderPathFromMessageId(messageId);
  if (encodedFolderPath != null) return encodedFolderPath;
  return resolver.nameFor(
    _mailboxFromMessageId(messageId, fallback: MailboxKind.inbox),
  );
}

String? _folderPathFromMessageId(String messageId) {
  final parts = messageId.split(':');
  if (parts.length < 4 || parts[parts.length - 3] != 'folder') return null;
  final encoded = parts[parts.length - 2];
  final padded = encoded.padRight(
    encoded.length + (4 - encoded.length % 4) % 4,
    '=',
  );
  try {
    return utf8.decode(base64Url.decode(padded));
  } on FormatException {
    return null;
  }
}

MailboxKind _mailboxFromMessageId(
  String messageId, {
  required MailboxKind fallback,
}) {
  final parts = messageId.split(':');
  if (parts.length >= 3) {
    for (final kind in standardMailboxKinds) {
      if (kind.name == parts[parts.length - 2]) return kind;
    }
  }
  return fallback;
}

String _oauth2InitialClientResponse(MailboxCredential credential) {
  return base64Encode(
    utf8.encode(
      'user=${credential.username}\x01auth=Bearer ${credential.secret}\x01\x01',
    ),
  );
}

class _SmtpConnection {
  _SmtpConnection(this._socket, this._credential, this._lines);

  Socket _socket;
  final MailboxCredential _credential;
  _SocketLineReader _lines;

  static Future<_SmtpConnection> connect(MailboxCredential credential) async {
    final socket =
        credential.usesImplicitSmtpTls
            ? await SecureSocket.connect(
              credential.smtpHost,
              credential.smtpPort,
              timeout: const Duration(seconds: 20),
            )
            : await Socket.connect(
              credential.smtpHost,
              credential.smtpPort,
              timeout: const Duration(seconds: 20),
            );
    final lines = _SocketLineReader(socket);
    final connection = _SmtpConnection(socket, credential, lines);
    await connection._expect(220);
    return connection;
  }

  Future<void> login() async {
    final greeting = await _ehlo();
    if (_credential.usesStartTlsSmtp) {
      if (!greeting.supportsCapability('STARTTLS')) {
        throw MailTransportException(
          'SMTP server does not advertise STARTTLS: '
          '${_credential.smtpHost}:${_credential.smtpPort}',
        );
      }
      await _command('STARTTLS', 220);
      await _upgradeToTls();
      await _ehlo();
    }
    if (_credential.authType == MailboxAuthType.oauth2) {
      await _command(
        'AUTH XOAUTH2 ${_oauth2InitialClientResponse(_credential)}',
        235,
      );
      return;
    }
    await _command('AUTH LOGIN', 334);
    await _command(base64Encode(utf8.encode(_credential.username)), 334);
    await _command(base64Encode(utf8.encode(_credential.secret)), 235);
  }

  Future<void> send(
    OutgoingMessage message, {
    required String rawMessage,
  }) async {
    await _command('MAIL FROM:<${message.from}>', 250);
    for (final recipient in message.envelopeRecipients) {
      await _command('RCPT TO:<$recipient>', 250);
    }
    await _command('DATA', 354);
    final data = '${rawMessage.replaceAll('\n.', '\n..')}\r\n.\r\n';
    _socket.write(data);
    await _expect(250);
  }

  Future<void> close() async {
    try {
      await _command('QUIT', 221);
    } catch (_) {
      // Ignore quit failures; the socket is closing anyway.
    }
    await _lines.close();
    await _socket.close();
  }

  Future<_SmtpResponse> _ehlo() {
    return _command('EHLO nyamail.local', 250);
  }

  Future<_SmtpResponse> _command(String command, int expected) async {
    _socket.write('$command\r\n');
    return _expect(expected);
  }

  Future<void> _upgradeToTls() async {
    final plainReader = _lines;
    plainReader.pause();
    final secureSocket = await SecureSocket.secure(
      _socket,
      host: _credential.smtpHost,
    ).timeout(const Duration(seconds: 20));
    _socket = secureSocket;
    _lines = _SocketLineReader(secureSocket);
  }

  Future<_SmtpResponse> _expect(int expected) async {
    final response = await _readResponse();
    if (response.code != expected) {
      throw MailTransportException(
        'SMTP command failed: ${response.lines.last}',
      );
    }
    return response;
  }

  Future<_SmtpResponse> _readResponse() async {
    final lines = <String>[];
    while (true) {
      final line = await _lines.readLine().timeout(const Duration(seconds: 30));
      final code = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
      if (code == null) continue;
      lines.add(line);
      if (line.length < 4 || line[3] != '-') {
        if (code >= 400) {
          throw MailTransportException('SMTP command failed: $line');
        }
        return _SmtpResponse(code: code, lines: lines);
      }
      if (code >= 400) {
        throw MailTransportException('SMTP command failed: $line');
      }
    }
  }
}

class _SmtpResponse {
  const _SmtpResponse({required this.code, required this.lines});

  final int code;
  final List<String> lines;

  bool supportsCapability(String name) {
    final upperName = name.toUpperCase();
    return lines.any((line) {
      if (line.length < 4) return false;
      final capability = line.substring(4).trim().toUpperCase();
      return capability == upperName || capability.startsWith('$upperName ');
    });
  }
}

String _formatOutgoingMessage(OutgoingMessage message) {
  final date = (message.date ?? DateTime.now().toUtc()).toUtc();
  final subject =
      message.subject.trim().isEmpty
          ? '(no subject)'
          : _sanitizeHeaderValue(message.subject.trim());
  final toHeader =
      message.to.isEmpty
          ? 'undisclosed-recipients:;'
          : message.to.map(_sanitizeHeaderValue).join(', ');
  final headers = [
    'From: ${_sanitizeHeaderValue(message.from)}',
    'To: $toHeader',
    if (message.cc.isNotEmpty)
      'Cc: ${message.cc.map(_sanitizeHeaderValue).join(', ')}',
    'Subject: $subject',
    'Date: ${_formatRfc2822Date(date)}',
    'MIME-Version: 1.0',
  ];
  final hasHtmlBody = message.htmlBody.trim().isNotEmpty;
  if (message.attachments.isEmpty && !hasHtmlBody) {
    final plainHeaders = [
      ...headers,
      'Content-Type: text/plain; charset=utf-8',
      'Content-Transfer-Encoding: 8bit',
    ];
    return '${plainHeaders.join('\r\n')}\r\n\r\n'
        '${_normalizeToCrlf(message.textBody)}';
  }

  if (message.attachments.isEmpty) {
    final boundary = _mimeBoundaryFor(message, date, 'alternative');
    final body = _alternativeBody(message, boundary);
    final multipartHeaders = [
      ...headers,
      'Content-Type: multipart/alternative; boundary="$boundary"',
    ];
    return '${multipartHeaders.join('\r\n')}\r\n\r\n'
        '${_normalizeToCrlf(body)}';
  }

  final boundary = _mimeBoundaryFor(message, date, 'mixed');
  final body = StringBuffer();
  if (hasHtmlBody) {
    final alternativeBoundary = _mimeBoundaryFor(message, date, 'alternative');
    body
      ..writeln('--$boundary')
      ..writeln(
        'Content-Type: multipart/alternative; '
        'boundary="$alternativeBoundary"',
      )
      ..writeln()
      ..writeln(_alternativeBody(message, alternativeBoundary));
  } else {
    body
      ..writeln('--$boundary')
      ..writeln(_plainTextPart(message.textBody));
  }
  for (final attachment in message.attachments) {
    body.writeln('--$boundary');
    body.writeln(_attachmentPart(attachment));
  }
  body.writeln('--$boundary--');

  final multipartHeaders = [
    ...headers,
    'Content-Type: multipart/mixed; boundary="$boundary"',
  ];
  return '${multipartHeaders.join('\r\n')}\r\n\r\n'
      '${_normalizeToCrlf(body.toString().trimRight())}';
}

String _alternativeBody(OutgoingMessage message, String boundary) {
  return (StringBuffer()
        ..writeln('--$boundary')
        ..writeln(_plainTextPart(message.textBody))
        ..writeln('--$boundary')
        ..writeln(_htmlPart(message.htmlBody))
        ..writeln('--$boundary--'))
      .toString()
      .trimRight();
}

String _plainTextPart(String textBody) {
  return (StringBuffer()
        ..writeln('Content-Type: text/plain; charset=utf-8')
        ..writeln('Content-Transfer-Encoding: 8bit')
        ..writeln()
        ..writeln(_normalizeToCrlf(textBody)))
      .toString()
      .trimRight();
}

String _htmlPart(String htmlBody) {
  return (StringBuffer()
        ..writeln('Content-Type: text/html; charset=utf-8')
        ..writeln('Content-Transfer-Encoding: 8bit')
        ..writeln()
        ..writeln(_normalizeToCrlf(htmlBody)))
      .toString()
      .trimRight();
}

String _attachmentPart(OutgoingAttachment attachment) {
  final filename = _safeMimeFilename(attachment.filename);
  final escapedFilename = _escapeQuotedParam(filename);
  return (StringBuffer()
        ..writeln(
          'Content-Type: ${_safeContentType(attachment.contentType)}; '
          'name="$escapedFilename"',
        )
        ..writeln(
          'Content-Disposition: attachment; filename="$escapedFilename"',
        )
        ..writeln('Content-Transfer-Encoding: base64')
        ..writeln()
        ..writeln(_wrapBase64(base64Encode(attachment.bytes))))
      .toString()
      .trimRight();
}

String _sanitizeHeaderValue(String value) {
  return value.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
}

String _normalizeToCrlf(String value) {
  return value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', '\r\n');
}

String _mimeBoundaryFor(OutgoingMessage message, DateTime date, String kind) {
  final size = message.attachments.fold<int>(
    utf8.encode(message.textBody).length + utf8.encode(message.htmlBody).length,
    (total, attachment) => total + attachment.bytes.length,
  );
  return 'nyamail-$kind-${date.microsecondsSinceEpoch}-'
      '${message.attachments.length}-$size';
}

String _safeMimeFilename(String value) {
  final cleaned =
      _sanitizeHeaderValue(value)
          .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
          .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'attachment';
  }
  return cleaned.length <= 160 ? cleaned : cleaned.substring(0, 160);
}

String _escapeQuotedParam(String value) {
  return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

String _safeContentType(String value) {
  final normalized = _sanitizeHeaderValue(value).toLowerCase();
  if (RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
  ).hasMatch(normalized)) {
    return normalized;
  }
  return 'application/octet-stream';
}

String _wrapBase64(String value) {
  final lines = <String>[];
  for (var index = 0; index < value.length; index += 76) {
    final end = index + 76;
    lines.add(value.substring(index, end > value.length ? value.length : end));
  }
  return lines.join('\r\n');
}

String _formatRfc2822Date(DateTime date) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final weekday = weekdays[date.weekday - 1];
  final month = months[date.month - 1];
  String two(int value) => value.toString().padLeft(2, '0');
  return '$weekday, ${two(date.day)} $month ${date.year} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)} +0000';
}

class MailTransportException implements Exception {
  const MailTransportException(this.message);

  final String message;

  @override
  String toString() => 'MailTransportException: $message';
}

class _SocketLineReader {
  _SocketLineReader(Socket socket) {
    _subscription = socket.listen(
      _onData,
      onError: _pendingError,
      onDone: () {
        _closed = true;
        _flushPending();
      },
      cancelOnError: true,
    );
  }

  final _buffer = <int>[];
  final _pendingLines = <_PendingLine>[];
  final _pendingBytes = <_PendingBytes>[];
  late final StreamSubscription<List<int>> _subscription;
  bool _closed = false;

  Future<String> readLine() {
    final line = _tryReadLine();
    if (line != null) return Future.value(line);
    if (_closed) {
      return Future.error(const MailTransportException('socket closed'));
    }
    final pending = _PendingLine();
    _pendingLines.add(pending);
    return pending.completer.future;
  }

  Future<List<int>> readBytes(int length) {
    if (_buffer.length >= length) {
      return Future.value(_takeBytes(length));
    }
    if (_closed) {
      return Future.error(const MailTransportException('socket closed'));
    }
    final pending = _PendingBytes(length);
    _pendingBytes.add(pending);
    return pending.completer.future;
  }

  Future<void> close() {
    return _subscription.cancel();
  }

  void pause() {
    _subscription.pause();
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    _flushPending();
  }

  void _pendingError(Object error) {
    while (_pendingLines.isNotEmpty) {
      _pendingLines.removeAt(0).completer.completeError(error);
    }
    while (_pendingBytes.isNotEmpty) {
      _pendingBytes.removeAt(0).completer.completeError(error);
    }
  }

  void _flushPending() {
    while (_pendingBytes.isNotEmpty &&
        _buffer.length >= _pendingBytes.first.length) {
      final pending = _pendingBytes.removeAt(0);
      pending.completer.complete(_takeBytes(pending.length));
    }
    while (_pendingBytes.isEmpty && _pendingLines.isNotEmpty) {
      final line = _tryReadLine();
      if (line == null) break;
      _pendingLines.removeAt(0).completer.complete(line);
    }
    if (_closed) {
      _pendingError(const MailTransportException('socket closed'));
    }
  }

  String? _tryReadLine() {
    for (var i = 0; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
        final lineBytes = _buffer.sublist(0, i);
        _buffer.removeRange(0, i + 2);
        return utf8.decode(lineBytes, allowMalformed: true);
      }
    }
    return null;
  }

  List<int> _takeBytes(int length) {
    final bytes = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return bytes;
  }
}

class _PendingLine {
  final completer = Completer<String>();
}

class _PendingBytes {
  _PendingBytes(this.length);

  final int length;
  final completer = Completer<List<int>>();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
