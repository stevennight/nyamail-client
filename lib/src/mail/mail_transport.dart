import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'imap_body_structure.dart';
import 'mail_charset.dart';
import 'mail_models.dart';

const _messagePreviewFetchBytes = 8 * 1024;

/// Messages up to this size are fetched whole when opened; one round trip is
/// cheaper than structure + sections. Larger ones (usually attachments) only
/// fetch their text parts.
const _wholeMessageFetchThreshold = 256 * 1024;
const _rfc822BackgroundParseThreshold = 48 * 1024;
const _uidSearchBackgroundParseThreshold = 48 * 1024;
const _uidPageBackgroundSelectionThreshold = 4096;
const _incrementalPreviewPageMultiplier = 4;

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

class MailMoveResult {
  const MailMoveResult({this.destinationUid});

  final int? destinationUid;
}

/// Server-side read/starred state of a message that is already cached.
class MailFlagState {
  const MailFlagState({required this.read, required this.starred});

  final bool read;
  final bool starred;
}

class MailPreviewPage extends IterableBase<MailMessage> {
  const MailPreviewPage({
    required this.messages,
    this.selectedUids = const [],
    this.remoteUids,
    this.hasMore = false,
    this.complete = true,
    this.flagUpdates = const {},
  });

  factory MailPreviewPage.fromMessages(
    List<MailMessage> messages, {
    int? limit,
    int? beforeUid,
    bool complete = true,
  }) {
    final selectedUids = [
      for (final message in messages)
        if (_uidFromMessageId(message.id) case final uid?) uid,
    ];
    final ordered = [...selectedUids]..sort((a, b) => b.compareTo(a));
    final visible =
        beforeUid == null
            ? ordered
            : ordered.where((uid) => uid < beforeUid).toList(growable: false);
    final effectiveLimit = limit ?? messages.length;
    return MailPreviewPage(
      messages: messages,
      selectedUids: selectedUids,
      remoteUids: selectedUids,
      hasMore: visible.length > effectiveLimit,
      complete: complete,
    );
  }

  final List<MailMessage> messages;
  final List<int> selectedUids;
  final List<int>? remoteUids;
  final bool hasMore;
  final bool complete;

  /// Current flags for messages the caller already had cached, keyed by
  /// message id. Those messages are not re-downloaded into [messages].
  final Map<String, MailFlagState> flagUpdates;

  @override
  Iterator<MailMessage> get iterator => messages.iterator;
}

abstract class MailTransport {
  Future<void> validateCredential({required MailboxCredential credential});

  Future<List<MailFolder>> listFolders({required MailboxCredential credential});

  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  });

  Future<MailPreviewPage> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  });

  Future<MailPreviewPage> fetchFolderMessagePreviews({
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

  Future<MailMoveResult> moveMessage({
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

abstract class IncrementalMailTransport {
  Future<MailPreviewPage> fetchNewFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    required int afterUid,
    int limit = 30,
  });
}

/// A transport that can skip downloading previews the caller already has and
/// only refresh their flags.
abstract class CacheAwareMailTransport {
  /// Like [MailTransport.fetchFolderMessagePreviews] (or, with [afterUid],
  /// [IncrementalMailTransport.fetchNewFolderMessagePreviews]), but messages
  /// whose ids are in [knownMessageIds] only get a cheap FLAGS fetch that is
  /// reported through [MailPreviewPage.flagUpdates].
  Future<MailPreviewPage> syncFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    required Set<String> knownMessageIds,
    int limit = 30,
    int? beforeUid,
    int? afterUid,
  });
}

class SocketMailTransport
    implements
        MailTransport,
        IncrementalMailTransport,
        CacheAwareMailTransport {
  const SocketMailTransport();

  /// Shared pool of logged-in IMAP connections.
  ///
  /// Every operation used to open a fresh TCP+TLS connection, log in, list the
  /// folders and select a mailbox before doing any work. The pool keeps a small
  /// number of authenticated connections per account and reuses them, so a
  /// mailbox switch or a flag toggle is a single command round trip.
  static final _ImapConnectionPool _pool = _ImapConnectionPool();

  /// Closes every pooled IMAP connection. Call on sign-out or app shutdown;
  /// connections are recreated lazily on the next request.
  static Future<void> disposeConnections() => _pool.disposeAll();

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
  }) {
    return _pool.run(
      credential,
      action: (imap) async {
        final mailboxes = await imap.listMailboxes();
        _pool.updateResolver(
          credential,
          _ImapMailboxResolver.fromList(mailboxes),
        );
        return _foldersFromList(credential, mailboxes);
      },
    );
  }

  @override
  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  }) async {
    final resolver = await _pool.resolver(credential);
    final folder = _standardFolderForMailbox(
      credential: credential,
      mailbox: mailbox,
      path: resolver.nameFor(mailbox),
    );
    return _pool.run(
      credential,
      selectMailbox: folder.path,
      action: (imap) async {
        final uids = await imap.uidSearchAll();
        final messages = <MailMessage>[];
        for (final uid in await _selectUidPageInBackground(
          uids,
          limit: limit,
        )) {
          final fetched = await imap.uidFetchMessage(uid);
          messages.add(
            await _parseFetchedRfc822Message(
              _Rfc822ParseRequest(
                raw: fetched.raw,
                id: _messageId(credential.accountId, mailbox, uid),
                accountId: credential.accountId,
                mailbox: mailbox,
                folderPath: folder.path,
                folderDisplayName: folder.displayName,
                read: fetched.flags.contains(r'\Seen'),
                starred: fetched.flags.contains(r'\Flagged'),
                receivedAt: fetched.internalDate,
              ),
            ),
          );
        }
        return messages;
      },
    );
  }

  @override
  Future<MailPreviewPage> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  }) async {
    final resolver = await _pool.resolver(credential);
    final folder = _standardFolderForMailbox(
      credential: credential,
      mailbox: mailbox,
      path: resolver.nameFor(mailbox),
    );
    return _pool.run(
      credential,
      selectMailbox: folder.path,
      action: (imap) async {
        final uids = await imap.uidSearchAll();
        final selectedUids = await _selectUidPageInBackground(
          uids,
          limit: limit,
          beforeUid: beforeUid,
        );
        final messages = <MailMessage>[];
        var complete = true;
        Map<int, _FetchedImapMessage> fetchedByUid;
        try {
          fetchedByUid = await imap.uidFetchMessagePreviews(selectedUids);
        } catch (_) {
          complete = false;
          fetchedByUid = const <int, _FetchedImapMessage>{};
        }
        final requests = <_Rfc822ParseRequest>[];
        for (final uid in selectedUids) {
          final fetched = fetchedByUid[uid];
          if (fetched == null) {
            complete = false;
            continue;
          }
          requests.add(
            _Rfc822ParseRequest(
              raw: fetched.raw,
              id: _messageId(credential.accountId, mailbox, uid),
              accountId: credential.accountId,
              mailbox: mailbox,
              folderPath: folder.path,
              folderDisplayName: folder.displayName,
              read: fetched.flags.contains(r'\Seen'),
              starred: fetched.flags.contains(r'\Flagged'),
              bodyLoaded: false,
              receivedAt: fetched.internalDate,
            ),
          );
        }
        for (final result in await _parseFetchedRfc822Previews(requests)) {
          final parsed = result.message;
          if (parsed == null) {
            complete = false;
            continue;
          }
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
        return MailPreviewPage(
          messages: messages,
          selectedUids: selectedUids,
          remoteUids: uids,
          hasMore: _hasMoreUidPage(uids, limit: limit, beforeUid: beforeUid),
          complete: complete,
        );
      },
    );
  }

  @override
  Future<MailPreviewPage> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  }) {
    return _fetchFolderMessagePreviews(
      credential: credential,
      folder: folder,
      limit: limit,
      beforeUid: beforeUid,
    );
  }

  @override
  Future<MailPreviewPage> fetchNewFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    required int afterUid,
    int limit = 30,
  }) {
    return _fetchFolderMessagePreviews(
      credential: credential,
      folder: folder,
      limit: limit,
      afterUid: afterUid,
    );
  }

  @override
  Future<MailPreviewPage> syncFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    required Set<String> knownMessageIds,
    int limit = 30,
    int? beforeUid,
    int? afterUid,
  }) {
    return _fetchFolderMessagePreviews(
      credential: credential,
      folder: folder,
      limit: limit,
      beforeUid: beforeUid,
      afterUid: afterUid,
      knownMessageIds: knownMessageIds,
    );
  }

  Future<MailPreviewPage> _fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    required int limit,
    int? beforeUid,
    int? afterUid,
    Set<String> knownMessageIds = const {},
  }) {
    return _pool.run(
      credential,
      selectMailbox: folder.path,
      action: (imap) async {
        final uids =
            afterUid == null
                ? await imap.uidSearchAll()
                : await imap.uidSearchAfter(afterUid);
        final selectedUids =
            afterUid == null
                ? await _selectUidPageInBackground(
                  uids,
                  limit: limit,
                  beforeUid: beforeUid,
                )
                : await _selectNewUidPageInBackground(
                  uids,
                  afterUid: afterUid,
                  limit: limit * _incrementalPreviewPageMultiplier,
                );
        String idFor(int uid) =>
            _messageIdForFolder(credential.accountId, folder, uid);
        final newUids = [
          for (final uid in selectedUids)
            if (!knownMessageIds.contains(idFor(uid))) uid,
        ];
        // Cached messages only need their flags checked. On a full refresh
        // that is the known part of the selected page; on an incremental one
        // the caller passes its newest cached ids for this folder.
        final flagUids =
            afterUid == null
                ? [
                  for (final uid in selectedUids)
                    if (knownMessageIds.contains(idFor(uid))) uid,
                ]
                : [
                  for (final id in knownMessageIds)
                    if (_uidFromMessageId(id) case final uid?)
                      if (idFor(uid) == id) uid,
                ];
        final flagUpdates = <String, MailFlagState>{};
        if (flagUids.isNotEmpty) {
          try {
            final flagsByUid = await imap.uidFetchFlags(flagUids);
            for (final entry in flagsByUid.entries) {
              flagUpdates[idFor(entry.key)] = MailFlagState(
                read: entry.value.contains(r'\Seen'),
                starred: entry.value.contains(r'\Flagged'),
              );
            }
          } catch (_) {
            // Flags are a best-effort refresh; new previews still count.
          }
        }
        final messages = <MailMessage>[];
        var complete = true;
        Map<int, _FetchedImapMessage> fetchedByUid;
        try {
          fetchedByUid = await imap.uidFetchMessagePreviews(newUids);
        } catch (_) {
          complete = false;
          fetchedByUid = const <int, _FetchedImapMessage>{};
        }
        final requests = <_Rfc822ParseRequest>[];
        for (final uid in newUids) {
          final fetched = fetchedByUid[uid];
          if (fetched == null) {
            complete = false;
            continue;
          }
          requests.add(
            _Rfc822ParseRequest(
              raw: fetched.raw,
              id: _messageIdForFolder(credential.accountId, folder, uid),
              accountId: credential.accountId,
              mailbox: folder.kind,
              folderPath: folder.path,
              folderDisplayName: folder.displayName,
              read: fetched.flags.contains(r'\Seen'),
              starred: fetched.flags.contains(r'\Flagged'),
              bodyLoaded: false,
              receivedAt: fetched.internalDate,
            ),
          );
        }
        for (final result in await _parseFetchedRfc822Previews(requests)) {
          final parsed = result.message;
          if (parsed == null) {
            complete = false;
            continue;
          }
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
        return MailPreviewPage(
          messages: messages,
          selectedUids: selectedUids,
          remoteUids: afterUid == null ? uids : null,
          hasMore:
              afterUid == null
                  ? _hasMoreUidPage(uids, limit: limit, beforeUid: beforeUid)
                  : uids.where((uid) => uid > afterUid).length >
                      selectedUids.length,
          complete: complete,
          flagUpdates: flagUpdates,
        );
      },
    );
  }

  @override
  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  }) async {
    final resolver = await _pool.resolver(credential);
    final folderName = _folderNameForMessage(resolver, message);
    return _pool.run(
      credential,
      selectMailbox: folderName,
      action: (imap) async {
        final uid = _imapUid(message.id);
        Future<MailMessage> parseWhole(
          String raw,
          Set<String> flags,
          DateTime? internalDate,
        ) {
          return _parseFetchedRfc822Message(
            _Rfc822ParseRequest(
              raw: raw,
              id: message.id,
              accountId: credential.accountId,
              mailbox: message.mailbox,
              folderPath: folderName,
              folderDisplayName: message.folderDisplayName,
              read: flags.contains(r'\Seen'),
              starred: flags.contains(r'\Flagged'),
              bodyLoaded: true,
              receivedAt: internalDate,
              fallbackReceivedAt: message.receivedAt,
            ),
          );
        }

        _FetchedStructure? head;
        try {
          head = await imap.uidFetchStructure(
            uid,
            prefixBytes: _wholeMessageFetchThreshold,
          );
        } on MailTransportException {
          head = null;
        }
        if (head != null && head.isComplete) {
          return parseWhole(
            latin1.decode(head.prefix!),
            head.flags,
            head.internalDate,
          );
        }
        final structure = head?.structure;
        if (head == null || structure == null || !structure.isMultipart) {
          final fetched = await imap.uidFetchMessage(uid);
          return parseWhole(fetched.raw, fetched.flags, fetched.internalDate);
        }

        // Large multipart message: fetch only the header and the text parts;
        // attachments come from the structure and download on demand.
        final textParts = structure.leaves
            .where((part) => part.isText)
            .toList(growable: false);
        final sections = await imap.uidFetchSections(uid, [
          'HEADER',
          for (final part in textParts) ...['${part.partId}.MIME', part.partId],
        ]);
        // Binary strings, like whole raw messages; the MIME parser decodes
        // each part with its own charset.
        String sectionText(String name) =>
            latin1.decode(sections[name.toUpperCase()] ?? const <int>[]);
        var plain = '';
        var html = '';
        for (final part in textParts) {
          var mime = sectionText('${part.partId}.MIME');
          if (!mime.endsWith('\r\n\r\n') && !mime.endsWith('\n\n')) {
            mime = '${mime.trimRight()}\r\n\r\n';
          }
          final entity = _parseMimeEntity(
            '$mime${sectionText(part.partId)}',
            partId: part.partId,
          );
          if (part.subtype == 'plain' && plain.trim().isEmpty) {
            plain = entity.body;
          } else if (part.subtype == 'html' && html.trim().isEmpty) {
            html = entity.htmlBody;
          }
        }
        return _mailMessageFromParts(
          headers: _parseHeaders(sectionText('HEADER')),
          body: plain.trim().isNotEmpty ? plain : _htmlToText(html),
          htmlBody: html,
          attachments: [
            for (final part in structure.leaves)
              if (part.isAttachment ||
                  (part.type == 'message' && part.subtype == 'rfc822'))
                MailAttachment(
                  filename: _decodeHeader(
                    part.filename.isEmpty
                        ? (part.type == 'message'
                            ? 'message.eml'
                            : 'attachment')
                        : part.filename,
                  ),
                  contentType: part.mimeType,
                  partId: part.partId,
                  transferEncoding: part.encoding,
                  size: part.decodedSize,
                ),
          ],
          id: message.id,
          accountId: credential.accountId,
          mailbox: message.mailbox,
          folderPath: folderName,
          folderDisplayName: message.folderDisplayName,
          read: head.flags.contains(r'\Seen'),
          starred: head.flags.contains(r'\Flagged'),
          bodyLoaded: true,
          receivedAt: head.internalDate,
          fallbackReceivedAt: message.receivedAt,
        );
      },
    );
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
    return _withImap(credential, messageId, (imap, _) {
      return imap.uidStoreFlag(_imapUid(messageId), r'\Seen', seen);
    });
  }

  @override
  Future<void> setFlagged({
    required MailboxCredential credential,
    required String messageId,
    required bool flagged,
  }) {
    return _withImap(credential, messageId, (imap, _) {
      return imap.uidStoreFlag(_imapUid(messageId), r'\Flagged', flagged);
    });
  }

  @override
  Future<MailMoveResult> moveMessage({
    required MailboxCredential credential,
    required String messageId,
    required MailboxKind destination,
  }) {
    return _withImap(credential, messageId, (imap, resolver) {
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
    final resolver = await _pool.resolver(credential);
    final folderName = _folderNameFromMessageId(resolver, messageId);
    return _pool.run(
      credential,
      selectMailbox: folderName,
      action: (imap) async {
        final body = await imap.uidFetchBodyPartBytes(
          _imapUid(messageId),
          attachment.partId,
        );
        return DownloadedAttachment(
          filename: attachment.filename,
          contentType: attachment.contentType,
          bytes: _decodeTransferBytes(body, attachment.transferEncoding),
        );
      },
    );
  }

  Future<T> _withImap<T>(
    MailboxCredential credential,
    String messageId,
    Future<T> Function(_ImapConnection imap, _ImapMailboxResolver resolver)
    action,
  ) async {
    final resolver = await _pool.resolver(credential);
    final folderName = _folderNameFromMessageId(resolver, messageId);
    return _pool.run(
      credential,
      selectMailbox: folderName,
      action: (imap) => action(imap, resolver),
    );
  }

  Future<void> _appendToSent(
    MailboxCredential credential,
    String rawMessage,
  ) async {
    final resolver = await _pool.resolver(credential);
    await _pool.run(
      credential,
      action:
          (imap) => imap.appendMessage(
            resolver.nameFor(MailboxKind.sent),
            rawMessage,
            flags: const [r'\Seen'],
          ),
    );
  }
}

/// Supplies the latest credential for an account, refreshing OAuth tokens
/// first when needed. Returns null when the account is gone.
typedef MailboxCredentialProvider = Future<MailboxCredential?> Function();

enum ImapIdleState { connecting, idling, unsupported, retrying, stopped }

/// Keeps one dedicated IMAP connection per account in IDLE on the inbox and
/// calls [onMailboxChanged] as soon as the server reports new or changed
/// mail, so the app no longer waits for its next polling tick.
///
/// The connection is separate from the command pool because an idling
/// connection cannot run other commands. It reconnects with backoff and,
/// after every reconnect, reports a change so mail that arrived while the
/// connection was down is picked up.
class ImapIdleWatcher {
  ImapIdleWatcher({
    required this.accountId,
    required MailboxCredentialProvider credential,
    required void Function() onMailboxChanged,
    void Function(ImapIdleState state)? onStateChanged,
    this.mailbox = 'INBOX',
    this.idleCycle = const Duration(minutes: 8),
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ],
  }) : _credential = credential,
       _onMailboxChanged = onMailboxChanged,
       _onStateChanged = onStateChanged;

  final String accountId;
  final String mailbox;
  final Duration idleCycle;
  final List<Duration> retryDelays;
  final MailboxCredentialProvider _credential;
  final void Function() _onMailboxChanged;
  final void Function(ImapIdleState state)? _onStateChanged;

  ImapIdleState _state = ImapIdleState.stopped;
  bool _running = false;
  Completer<void> _cancel = Completer<void>();
  _ImapConnection? _connection;

  ImapIdleState get state => _state;

  void start() {
    if (_running) return;
    _running = true;
    _cancel = Completer<void>();
    unawaited(_run());
  }

  void stop() {
    if (!_running) return;
    _running = false;
    if (!_cancel.isCompleted) _cancel.complete();
    _connection?.destroy();
    _connection = null;
    _setState(ImapIdleState.stopped);
  }

  void _setState(ImapIdleState state) {
    if (_state == state) return;
    _state = state;
    _onStateChanged?.call(state);
  }

  Future<void> _run() async {
    var failures = 0;
    var connectedBefore = false;
    final cancel = _cancel;
    while (_running && !cancel.isCompleted) {
      _setState(ImapIdleState.connecting);
      _ImapConnection? connection;
      try {
        final credential = await _credential();
        if (credential == null || !_running) break;
        connection = await _ImapConnection.connect(credential);
        _connection = connection;
        await connection.login();
        final capabilities = await connection.capabilities();
        if (!capabilities.contains('IDLE')) {
          _setState(ImapIdleState.unsupported);
          _running = false;
          break;
        }
        await connection.examineMailbox(mailbox);
        if (connectedBefore) _onMailboxChanged();
        connectedBefore = true;
        failures = 0;
        _setState(ImapIdleState.idling);
        while (_running && !cancel.isCompleted) {
          final changed = await connection.idle(
            maxDuration: idleCycle,
            cancel: cancel.future,
          );
          if (changed && _running) _onMailboxChanged();
        }
      } catch (error) {
        if (!_running) break;
        _setState(ImapIdleState.retrying);
        final delay = retryDelays[math.min(failures, retryDelays.length - 1)];
        failures++;
        await Future.any([Future<void>.delayed(delay), cancel.future]);
      } finally {
        if (identical(_connection, connection)) _connection = null;
        connection?.destroy();
      }
    }
  }
}

class _Rfc822ParseRequest {
  const _Rfc822ParseRequest({
    required this.raw,
    required this.id,
    required this.accountId,
    required this.mailbox,
    required this.folderPath,
    required this.folderDisplayName,
    required this.read,
    required this.starred,
    this.bodyLoaded = true,
    this.receivedAt,
    this.fallbackReceivedAt,
  });

  final String raw;
  final String id;
  final String accountId;
  final MailboxKind mailbox;
  final String folderPath;
  final String folderDisplayName;
  final bool read;
  final bool starred;
  final bool bodyLoaded;
  final DateTime? receivedAt;
  final DateTime? fallbackReceivedAt;
}

class _Rfc822PreviewParseResult {
  const _Rfc822PreviewParseResult.success(this.message);
  const _Rfc822PreviewParseResult.failure() : message = null;

  final MailMessage? message;
}

Future<MailMessage> _parseFetchedRfc822Message(
  _Rfc822ParseRequest request,
) async {
  if (request.raw.length < _rfc822BackgroundParseThreshold) {
    return _parseRfc822Request(request);
  }
  try {
    return await Isolate.run(() => _parseRfc822Request(request));
  } catch (_) {
    return _parseRfc822Request(request);
  }
}

Future<List<_Rfc822PreviewParseResult>> _parseFetchedRfc822Previews(
  List<_Rfc822ParseRequest> requests,
) async {
  if (requests.isEmpty) return const [];
  final totalLength = requests.fold<int>(
    0,
    (total, request) => total + request.raw.length,
  );
  if (totalLength < _rfc822BackgroundParseThreshold) {
    return _parseRfc822PreviewRequests(requests);
  }
  try {
    return await Isolate.run(() => _parseRfc822PreviewRequests(requests));
  } catch (_) {
    return _parseRfc822PreviewRequests(requests);
  }
}

MailMessage _parseRfc822Request(_Rfc822ParseRequest request) {
  return parseRfc822Message(
    request.raw,
    id: request.id,
    accountId: request.accountId,
    mailbox: request.mailbox,
    folderPath: request.folderPath,
    folderDisplayName: request.folderDisplayName,
    read: request.read,
    starred: request.starred,
    bodyLoaded: request.bodyLoaded,
    receivedAt: request.receivedAt,
    fallbackReceivedAt: request.fallbackReceivedAt,
  );
}

List<_Rfc822PreviewParseResult> _parseRfc822PreviewRequests(
  List<_Rfc822ParseRequest> requests,
) {
  final results = <_Rfc822PreviewParseResult>[];
  for (final request in requests) {
    try {
      results.add(
        _Rfc822PreviewParseResult.success(_parseRfc822Request(request)),
      );
    } catch (_) {
      results.add(const _Rfc822PreviewParseResult.failure());
    }
  }
  return results;
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
  DateTime? receivedAt,
  DateTime? fallbackReceivedAt,
}) {
  final parsed = _parseMimeEntity(raw);
  return _mailMessageFromParts(
    headers: parsed.headers,
    body: parsed.bestBody,
    htmlBody: parsed.htmlBody,
    attachments: parsed.attachments,
    id: id,
    accountId: accountId,
    mailbox: mailbox,
    folderPath: folderPath,
    folderDisplayName: folderDisplayName,
    read: read,
    starred: starred,
    bodyLoaded: bodyLoaded,
    receivedAt: receivedAt,
    fallbackReceivedAt: fallbackReceivedAt,
  );
}

MailMessage _mailMessageFromParts({
  required Map<String, String> headers,
  required String body,
  required String htmlBody,
  required List<MailAttachment> attachments,
  required String id,
  required String accountId,
  required MailboxKind mailbox,
  required String folderPath,
  required String folderDisplayName,
  required bool read,
  required bool starred,
  required bool bodyLoaded,
  DateTime? receivedAt,
  DateTime? fallbackReceivedAt,
}) {
  final date =
      receivedAt?.toUtc() ??
      _parseMailDate(headers['date'] ?? '') ??
      fallbackReceivedAt?.toUtc() ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  body = body.replaceAll('\r\n', '\n').trim();
  htmlBody = htmlBody.replaceAll('\r\n', '\n').trim();
  final preview = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  return MailMessage(
    id: id,
    accountId: accountId,
    from: _decodeHeader(headers['from'] ?? 'Unknown sender'),
    to: _parseAddressHeader(headers['to'] ?? ''),
    cc: _parseAddressHeader(headers['cc'] ?? ''),
    replyTo: _parseAddressHeader(headers['reply-to'] ?? ''),
    subject: _decodeHeader(headers['subject'] ?? '(no subject)'),
    messageIdHeader: _normalizedMessageIdHeader(headers['message-id']),
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
    hasAttachments: attachments.isNotEmpty,
    attachments: attachments,
    bodyLoaded: bodyLoaded,
  );
}

/// Interior of a `Message-ID:` header with the enclosing `<...>` stripped, or
/// '' when the header is missing or empty.
String _normalizedMessageIdHeader(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return '';
  final stripped =
      value.startsWith('<') && value.endsWith('>')
          ? value.substring(1, value.length - 1).trim()
          : value;
  return stripped;
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

  final filename =
      disposition.params['filename'] ?? contentType.params['name'] ?? '';
  final lowerContentType = contentType.value.toLowerCase();
  final lowerDisposition = disposition.value.toLowerCase();
  final isAttachment =
      lowerDisposition == 'attachment' ||
      (filename.isNotEmpty && lowerDisposition != 'inline');
  final decodedBody =
      isAttachment
          ? ''
          : _decodeBody(
            body,
            transferEncoding,
            charset: contentType.params['charset'],
          );
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
  return headers.map(
    (name, value) => MapEntry(name, decodeRawHeaderText(value)),
  );
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

/// Decodes a text part. [body] is normally a latin1 binary string of the raw
/// bytes; text that is already decoded (code units above 0xFF) is kept.
String _decodeBody(String body, String transferEncoding, {String? charset}) {
  final normalized = transferEncoding.toLowerCase();
  final List<int> bytes;
  if (normalized == 'base64') {
    try {
      bytes = _decodeBase64Body(body);
    } on FormatException {
      return body;
    }
  } else if (normalized == 'quoted-printable') {
    if (binaryStringBytes(body) == null) return _decodeQuotedPrintable(body);
    bytes = _decodeQuotedPrintableBytes(body);
  } else {
    final raw = binaryStringBytes(body);
    if (raw == null) return body;
    bytes = raw;
  }
  return decodeMailText(bytes, charset);
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
  return binaryStringBytes(body)?.length ?? utf8.encode(body).length;
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
  // RFC 2231 language suffix: =?UTF-8*en?...
  return decodeMailText(bytes, charset.split('*').first);
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
  if (parsed != null) return parsed.toUtc();
  final cleaned =
      value
          .replaceFirst(RegExp(r'^[A-Za-z]{3,9},\s*'), '')
          .replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '')
          .trim();
  final match = RegExp(
    r'^(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|UT|UTC|GMT|Z)',
    caseSensitive: false,
  ).firstMatch(cleaned);
  if (match == null) return null;
  final month = _monthFromName(match.group(2)!);
  if (month == null) return null;
  final year = _normalizedDateYear(match.group(3)!);
  if (year == null) return null;
  return _dateTimeFromOffsetParts(
    year: year,
    month: month,
    day: int.parse(match.group(1)!),
    hour: int.parse(match.group(4)!),
    minute: int.parse(match.group(5)!),
    second: int.parse(match.group(6) ?? '0'),
    offset: match.group(7)!,
  );
}

DateTime? _parseImapInternalDate(String value) {
  final match = RegExp(
    r'"?(\d{1,2})-([A-Za-z]{3})-(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s+([+-]\d{4}|UT|UTC|GMT|Z)"?',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final month = _monthFromName(match.group(2)!);
  if (month == null) return null;
  return _dateTimeFromOffsetParts(
    year: int.parse(match.group(3)!),
    month: month,
    day: int.parse(match.group(1)!),
    hour: int.parse(match.group(4)!),
    minute: int.parse(match.group(5)!),
    second: int.parse(match.group(6)!),
    offset: match.group(7)!,
  );
}

int? _monthFromName(String value) {
  return const {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  }[value.trim().toLowerCase()];
}

int? _normalizedDateYear(String value) {
  final parsed = int.tryParse(value);
  if (parsed == null) return null;
  if (value.length != 2) return parsed;
  return parsed >= 70 ? 1900 + parsed : 2000 + parsed;
}

DateTime? _dateTimeFromOffsetParts({
  required int year,
  required int month,
  required int day,
  required int hour,
  required int minute,
  required int second,
  required String offset,
}) {
  final local = DateTime.utc(year, month, day, hour, minute, second);
  final normalizedOffset = offset.toUpperCase();
  if (const {'UT', 'UTC', 'GMT', 'Z'}.contains(normalizedOffset)) {
    return local;
  }
  if (!RegExp(r'^[+-]\d{4}$').hasMatch(normalizedOffset)) return null;
  final offsetSign = normalizedOffset.startsWith('-') ? -1 : 1;
  final offsetHours = int.parse(normalizedOffset.substring(1, 3));
  final offsetMinutes = int.parse(normalizedOffset.substring(3, 5));
  return local.subtract(
    Duration(minutes: offsetSign * (offsetHours * 60 + offsetMinutes)),
  );
}

/// Keeps a handful of authenticated IMAP connections per account alive and
/// hands them out one command at a time, so callers skip the TCP + TLS + LOGIN
/// + LIST + SELECT dance that every request used to pay for.
class _ImapConnectionPool {
  _ImapConnectionPool();

  static const _maxConnectionsPerEndpoint = 3;
  static const _healthCheckIdleThreshold = Duration(seconds: 10);
  static const _idleEvictionThreshold = Duration(minutes: 5);
  static const _sweepInterval = Duration(minutes: 1);

  final Map<String, _PooledEndpoint> _endpoints = <String, _PooledEndpoint>{};
  Timer? _sweepTimer;

  Future<T> run<T>(
    MailboxCredential credential, {
    String? selectMailbox,
    required Future<T> Function(_ImapConnection imap) action,
  }) {
    _ensureSweepTimer();
    return _endpointFor(
      credential,
    ).run(selectMailbox: selectMailbox, action: action);
  }

  Future<_ImapMailboxResolver> resolver(MailboxCredential credential) {
    _ensureSweepTimer();
    return _endpointFor(credential).resolver();
  }

  void updateResolver(
    MailboxCredential credential,
    _ImapMailboxResolver resolver,
  ) {
    _endpoints[_keyFor(credential)]?.cacheResolver(resolver);
  }

  Future<void> disposeAll() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    final endpoints = _endpoints.values.toList(growable: false);
    _endpoints.clear();
    for (final endpoint in endpoints) {
      await endpoint.closeAll();
    }
  }

  _PooledEndpoint _endpointFor(MailboxCredential credential) {
    return _endpoints.putIfAbsent(
      _keyFor(credential),
      () => _PooledEndpoint(credential),
    );
  }

  String _keyFor(MailboxCredential credential) {
    return [
      credential.accountId,
      credential.imapHost,
      credential.imapPort.toString(),
      credential.username,
      credential.authType.name,
    ].join('\u0000');
  }

  void _ensureSweepTimer() {
    _sweepTimer ??= Timer.periodic(_sweepInterval, (_) => _sweep());
  }

  void _sweep() {
    final now = DateTime.now();
    _endpoints.removeWhere((_, endpoint) {
      endpoint.evictIdle(now, _idleEvictionThreshold);
      return endpoint.isEmpty;
    });
    if (_endpoints.isEmpty) {
      _sweepTimer?.cancel();
      _sweepTimer = null;
    }
  }
}

class _PooledEndpoint {
  _PooledEndpoint(this._credential);

  final MailboxCredential _credential;
  final List<_PooledConnection> _connections = <_PooledConnection>[];
  final List<Completer<_PooledConnection>> _waiters =
      <Completer<_PooledConnection>>[];

  _ImapMailboxResolver? _resolver;
  Future<_ImapMailboxResolver>? _pendingResolver;

  bool get isEmpty => _connections.isEmpty;

  void cacheResolver(_ImapMailboxResolver resolver) {
    _resolver = resolver;
  }

  Future<_ImapMailboxResolver> resolver() {
    final cached = _resolver;
    if (cached != null) return Future.value(cached);
    return _pendingResolver ??= _loadResolver().whenComplete(() {
      _pendingResolver = null;
    });
  }

  Future<_ImapMailboxResolver> _loadResolver() async {
    final resolver = await run(
      selectMailbox: null,
      action:
          (imap) async =>
              _ImapMailboxResolver.fromList(await imap.listMailboxes()),
    );
    _resolver = resolver;
    return resolver;
  }

  Future<T> run<T>({
    required String? selectMailbox,
    required Future<T> Function(_ImapConnection imap) action,
  }) async {
    final connection = await _acquire();
    var attemptedFresh = false;
    try {
      while (true) {
        try {
          final reused = await connection.ensureConnected(_credential);
          attemptedFresh = !reused;
          if (selectMailbox != null) {
            await connection.ensureSelected(selectMailbox);
          }
          connection.markUsed();
          final result = await action(connection.imap!);
          connection.markUsed();
          return result;
        } catch (error) {
          if (_isConnectionFailure(error)) {
            await connection.discard();
            // A stale pooled connection can fail before the command reaches the
            // server; retry once against a guaranteed-fresh connection.
            if (!attemptedFresh) {
              attemptedFresh = true;
              continue;
            }
          }
          rethrow;
        }
      }
    } finally {
      _release(connection);
    }
  }

  Future<_PooledConnection> _acquire() {
    for (final connection in _connections) {
      if (!connection.busy) {
        connection.busy = true;
        return Future.value(connection);
      }
    }
    if (_connections.length < _ImapConnectionPool._maxConnectionsPerEndpoint) {
      final connection = _PooledConnection()..busy = true;
      _connections.add(connection);
      return Future.value(connection);
    }
    final completer = Completer<_PooledConnection>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release(_PooledConnection connection) {
    connection.busy = false;
    while (_waiters.isNotEmpty) {
      final next = _connections.firstWhere(
        (candidate) => !candidate.busy,
        orElse: () => connection,
      );
      if (next.busy) break;
      next.busy = true;
      _waiters.removeAt(0).complete(next);
    }
  }

  void evictIdle(DateTime now, Duration threshold) {
    _connections.removeWhere((connection) {
      if (connection.busy) return false;
      if (now.difference(connection.lastUsed) < threshold) return false;
      unawaited(connection.discard());
      return true;
    });
  }

  Future<void> closeAll() async {
    final connections = _connections.toList(growable: false);
    _connections.clear();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          const MailTransportException('IMAP connection pool closed'),
        );
      }
    }
    _waiters.clear();
    _resolver = null;
    _pendingResolver = null;
    for (final connection in connections) {
      await connection.discard();
    }
  }
}

class _PooledConnection {
  _ImapConnection? imap;
  bool busy = false;
  DateTime lastUsed = DateTime.now();
  String? _selectedMailbox;

  /// Ensures the connection is open and logged in. Returns whether an existing
  /// connection was reused (as opposed to a fresh one being established).
  Future<bool> ensureConnected(MailboxCredential credential) async {
    final existing = imap;
    if (existing != null) {
      if (DateTime.now().difference(lastUsed) >
          _ImapConnectionPool._healthCheckIdleThreshold) {
        try {
          await existing.noop();
        } catch (_) {
          await discard();
        }
      }
      if (imap != null) return true;
    }
    final connection = await _ImapConnection.connect(credential);
    try {
      await connection.login();
    } catch (error) {
      try {
        await connection.close();
      } catch (_) {
        // The login failure is the interesting error.
      }
      rethrow;
    }
    imap = connection;
    _selectedMailbox = null;
    return false;
  }

  Future<void> ensureSelected(String mailbox) async {
    if (_selectedMailbox == mailbox) return;
    _selectedMailbox = null;
    await imap!.selectMailbox(mailbox);
    _selectedMailbox = mailbox;
  }

  void markUsed() {
    lastUsed = DateTime.now();
  }

  Future<void> discard() async {
    final connection = imap;
    imap = null;
    _selectedMailbox = null;
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {
        // Already broken; nothing to clean up.
      }
    }
  }
}

bool _isConnectionFailure(Object error) {
  if (error is SocketException || error is TimeoutException) return true;
  if (error is MailTransportException) {
    final message = error.message.toLowerCase();
    return message.contains('socket closed') ||
        message.contains('connection') ||
        message.contains('greeting') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('pool closed');
  }
  return false;
}

class _ImapConnection {
  _ImapConnection(this._socket, this._credential, this._reader);

  final Socket _socket;
  final MailboxCredential _credential;
  final _SocketLineReader _reader;
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
    return _uidsFromSearchLines(lines);
  }

  Future<List<int>> uidSearchAfter(int uid) async {
    final firstUid = uid < 1 ? 1 : uid + 1;
    final lines = await _commandLines('UID SEARCH UID $firstUid:*');
    return [
      for (final result in await _uidsFromSearchLines(lines))
        if (result > uid) result,
    ];
  }

  Future<List<int>> _uidsFromSearchLines(List<String> lines) async {
    for (final line in lines) {
      if (line.startsWith('* SEARCH')) {
        final values = line.substring('* SEARCH'.length).trim();
        if (values.length < _uidSearchBackgroundParseThreshold) {
          return _parseUidSearchValues(values);
        }
        return Isolate.run(() => _parseUidSearchValues(values));
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
      'UID FETCH $uid (FLAGS INTERNALDATE BODY.PEEK[])',
    );
    return _FetchedImapMessage(
      raw: response.chunks.map((bytes) => latin1.decode(bytes)).join('\n'),
      flags: _parseFetchFlags(response.lines),
      internalDate: _parseFetchInternalDate(response.lines),
    );
  }

  Future<_FetchedImapMessage> uidFetchMessagePreview(int uid) async {
    final response = await _fetchLiteralBytes(
      'UID FETCH $uid (FLAGS INTERNALDATE BODY.PEEK[]<0.$_messagePreviewFetchBytes>)',
    );
    return _FetchedImapMessage(
      raw: response.chunks.map((bytes) => latin1.decode(bytes)).join('\n'),
      flags: _parseFetchFlags(response.lines),
      internalDate: _parseFetchInternalDate(response.lines),
    );
  }

  Future<Map<int, _FetchedImapMessage>> uidFetchMessagePreviews(
    Iterable<int> uids,
  ) async {
    final requested = LinkedHashSet<int>.of(
      uids.where((uid) => uid > 0),
    ).toList(growable: false);
    if (requested.isEmpty) return const <int, _FetchedImapMessage>{};

    final responses = await _fetchLiteralResponses(
      'UID FETCH ${requested.join(',')} '
      '(FLAGS INTERNALDATE BODY.PEEK[]<0.$_messagePreviewFetchBytes>)',
    );
    final requestedUids = requested.toSet();
    final fetchedByUid = <int, _FetchedImapMessage>{};
    for (final response in responses) {
      final uid = _parseFetchUid(response.lines);
      if (uid == null ||
          !requestedUids.contains(uid) ||
          response.chunks.isEmpty) {
        continue;
      }
      fetchedByUid[uid] = _FetchedImapMessage(
        raw: response.chunks.map((bytes) => latin1.decode(bytes)).join('\n'),
        flags: _parseFetchFlags(response.lines),
        internalDate: _parseFetchInternalDate(response.lines),
      );
    }
    return fetchedByUid;
  }

  /// Fetches size, flags, BODYSTRUCTURE and the first [prefixBytes] of one
  /// message in a single round trip. When the message fits in the prefix the
  /// caller already has all of it. Other literals inside the response are
  /// inlined as quoted strings so the structure parses as one line.
  Future<_FetchedStructure> uidFetchStructure(
    int uid, {
    required int prefixBytes,
  }) async {
    final tag = _nextTag();
    _socket.write(
      '$tag UID FETCH $uid (UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE '
      'BODY.PEEK[]<0.$prefixBytes>)\r\n',
    );
    final prefixPattern = RegExp(
      r'BODY\[\]<0>\s+\{\d+\}$',
      caseSensitive: false,
    );
    List<int>? prefix;
    final logical = <String>[];
    final current = StringBuffer();
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (current.isEmpty && line.startsWith('$tag OK')) break;
      if (current.isEmpty &&
          (line.startsWith('$tag NO') || line.startsWith('$tag BAD'))) {
        throw MailTransportException('IMAP fetch failed: $line');
      }
      final literal = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (literal == null) {
        current.write(line);
        logical.add(current.toString());
        current.clear();
        continue;
      }
      final bytes = await _reader
          .readBytes(int.parse(literal.group(1)!))
          .timeout(const Duration(seconds: 30));
      if (prefixPattern.hasMatch(line)) {
        prefix = bytes;
        current
          ..write(line.substring(0, literal.start))
          ..write('NIL');
        continue;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      current
        ..write(line.substring(0, literal.start))
        ..write('"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"');
    }
    for (final line in logical) {
      if (!line.startsWith('* ') || !line.toUpperCase().contains(' FETCH ')) {
        continue;
      }
      final size = RegExp(
        r'\bRFC822\.SIZE\s+(\d+)',
        caseSensitive: false,
      ).firstMatch(line);
      return _FetchedStructure(
        size: size == null ? null : int.parse(size.group(1)!),
        structure: parseBodyStructureFromFetch(line),
        flags: _parseFetchFlags([line]),
        internalDate: _parseFetchInternalDate([line]),
        prefix: prefix,
      );
    }
    throw const MailTransportException('IMAP fetch returned no structure');
  }

  /// Fetches several body sections of one message in a single round trip,
  /// keyed by upper-case section name (e.g. `HEADER`, `1.2.MIME`, `1.2`).
  Future<Map<String, List<int>>> uidFetchSections(
    int uid,
    List<String> sections,
  ) async {
    final tag = _nextTag();
    final items = sections.map((section) => 'BODY.PEEK[$section]').join(' ');
    _socket.write('$tag UID FETCH $uid ($items)\r\n');
    final result = <String, List<int>>{};
    final sectionPattern = RegExp(
      r'BODY\[([^\]]*)\](?:<\d+>)?\s+\{(\d+)\}$',
      caseSensitive: false,
    );
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (line.startsWith('$tag OK')) return result;
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP fetch failed: $line');
      }
      final literal = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (literal == null) continue;
      final bytes = await _reader
          .readBytes(int.parse(literal.group(1)!))
          .timeout(const Duration(seconds: 30));
      final section = sectionPattern.firstMatch(line)?.group(1);
      if (section != null) result[section.toUpperCase()] = bytes;
    }
  }

  /// Fetches only the flags of [uids]; keyed by UID.
  Future<Map<int, Set<String>>> uidFetchFlags(Iterable<int> uids) async {
    final requested = LinkedHashSet<int>.of(
      uids.where((uid) => uid > 0),
    ).toList(growable: false);
    if (requested.isEmpty) return const <int, Set<String>>{};
    final lines = await _commandLines(
      'UID FETCH ${_compactUidSet(requested)} (UID FLAGS)',
    );
    final requestedUids = requested.toSet();
    final flagsByUid = <int, Set<String>>{};
    for (final line in lines) {
      if (!line.startsWith('* ') || !line.toUpperCase().contains(' FETCH ')) {
        continue;
      }
      final uid = _parseFetchUid([line]);
      if (uid == null || !requestedUids.contains(uid)) continue;
      flagsByUid[uid] = _parseFetchFlags([line]);
    }
    return flagsByUid;
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

  Future<List<_FetchLiteralResponse>> _fetchLiteralResponses(
    String command,
  ) async {
    final tag = _nextTag();
    final responses = <_FetchLiteralResponse>[];
    List<String>? currentLines;
    List<List<int>>? currentChunks;

    void finishCurrentResponse() {
      final lines = currentLines;
      final chunks = currentChunks;
      if (lines == null || chunks == null) return;
      responses.add(_FetchLiteralResponse(lines: lines, chunks: chunks));
      currentLines = null;
      currentChunks = null;
    }

    _socket.write('$tag $command\r\n');
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (line.startsWith('$tag OK')) {
        finishCurrentResponse();
        return responses;
      }
      if (line.startsWith('$tag NO') || line.startsWith('$tag BAD')) {
        throw MailTransportException('IMAP fetch failed: $line');
      }

      final startsFetch =
          line.startsWith('* ') && line.toUpperCase().contains(' FETCH ');
      if (startsFetch) {
        finishCurrentResponse();
        currentLines = [line];
        currentChunks = <List<int>>[];
      } else {
        currentLines?.add(line);
      }

      final literal = RegExp(r'\{(\d+)\}$').firstMatch(line);
      if (literal != null) {
        final length = int.parse(literal.group(1)!);
        final bytes = await _reader
            .readBytes(length)
            .timeout(const Duration(seconds: 30));
        currentChunks?.add(bytes);
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

  Future<MailMoveResult> moveMessage(int id, String mailbox) async {
    return uidMoveMessage(id, mailbox);
  }

  Future<MailMoveResult> uidMoveMessage(int uid, String mailbox) async {
    try {
      final lines = await _commandLines('UID MOVE $uid "${_escape(mailbox)}"');
      return MailMoveResult(destinationUid: _copyUidDestination(lines, uid));
    } on MailTransportException {
      final lines = await _commandLines('UID COPY $uid "${_escape(mailbox)}"');
      await uidStoreFlag(uid, r'\Deleted', true);
      await _command('EXPUNGE');
      return MailMoveResult(destinationUid: _copyUidDestination(lines, uid));
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

  /// Lightweight round trip used to check a pooled connection is still alive.
  Future<void> noop() => _command('NOOP');

  Future<Set<String>> capabilities() async {
    final lines = await _commandLines('CAPABILITY');
    final capabilities = <String>{};
    for (final line in lines) {
      final upper = line.toUpperCase();
      final start = upper.indexOf('CAPABILITY ');
      if (start < 0) continue;
      final values = upper.substring(start + 'CAPABILITY '.length);
      capabilities.addAll(
        values
            .replaceAll(']', ' ')
            .split(RegExp(r'\s+'))
            .where((value) => value.isNotEmpty),
      );
    }
    return capabilities;
  }

  /// Read-only SELECT, used by the IDLE watcher so it never changes \Recent.
  Future<void> examineMailbox(String mailbox) {
    return _command('EXAMINE "${_escape(mailbox)}"');
  }

  /// Runs one IDLE cycle and returns whether the server reported a change to
  /// the selected mailbox (new, expunged or re-flagged messages).
  ///
  /// The cycle ends at the first change, after [maxDuration] (servers drop
  /// IDLE after ~30 minutes, NATs often much sooner), or when [cancel]
  /// completes.
  Future<bool> idle({
    required Duration maxDuration,
    required Future<void> cancel,
  }) async {
    final tag = _nextTag();
    var changed = false;
    _socket.write('$tag IDLE\r\n');
    while (true) {
      final line = await _reader.readLine().timeout(
        const Duration(seconds: 30),
      );
      if (line.startsWith('+')) break;
      if (line.startsWith('$tag ')) {
        throw MailTransportException('IMAP IDLE failed: $line');
      }
      changed = changed || _isMailboxChangeLine(line);
    }

    // A readLine that loses the race stays queued in the reader and receives
    // the next line, so it is carried over instead of being abandoned.
    Future<String>? pending;
    final stop = Completer<void>();
    final timer = Timer(maxDuration, () {
      if (!stop.isCompleted) stop.complete();
    });
    unawaited(
      cancel.then((_) {
        if (!stop.isCompleted) stop.complete();
      }),
    );
    try {
      while (!changed) {
        final read = pending ??= _reader.readLine();
        final stopped = await Future.any<bool>([
          read.then((_) => false),
          stop.future.then((_) => true),
        ]);
        if (stopped) break;
        final line = await read;
        pending = null;
        if (line.startsWith('$tag OK')) return changed;
        if (line.startsWith('$tag ')) {
          throw MailTransportException('IMAP IDLE ended: $line');
        }
        if (line.startsWith('* BYE')) {
          throw MailTransportException('IMAP connection closed: $line');
        }
        changed = _isMailboxChangeLine(line);
      }
    } finally {
      timer.cancel();
    }

    _socket.write('DONE\r\n');
    while (true) {
      final read = pending ?? _reader.readLine();
      pending = null;
      final line = await read.timeout(const Duration(seconds: 30));
      if (line.startsWith('$tag OK')) return changed;
      if (line.startsWith('$tag ')) {
        throw MailTransportException('IMAP IDLE failed: $line');
      }
      changed = changed || _isMailboxChangeLine(line);
    }
  }

  /// Drops the socket immediately without a LOGOUT round trip.
  void destroy() {
    _reader.abort();
    _socket.destroy();
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
  const _FetchedImapMessage({
    required this.raw,
    required this.flags,
    this.internalDate,
  });

  final String raw;
  final Set<String> flags;
  final DateTime? internalDate;
}

class _FetchedStructure {
  const _FetchedStructure({
    required this.size,
    required this.structure,
    required this.flags,
    this.internalDate,
    this.prefix,
  });

  final int? size;
  final ImapBodyPart? structure;
  final Set<String> flags;
  final DateTime? internalDate;

  /// The first bytes of the raw message; all of it when [isComplete].
  final List<int>? prefix;

  bool get isComplete {
    final bytes = prefix;
    final total = size;
    return bytes != null && total != null && bytes.length >= total;
  }
}

class _FetchLiteralResponse {
  const _FetchLiteralResponse({required this.lines, required this.chunks});

  final List<String> lines;
  final List<List<int>> chunks;
}

int? _parseFetchUid(List<String> lines) {
  for (final line in lines) {
    final match = RegExp(
      r'\bUID\s+(\d+)\b',
      caseSensitive: false,
    ).firstMatch(line);
    if (match != null) return int.tryParse(match.group(1)!);
  }
  return null;
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

DateTime? _parseFetchInternalDate(List<String> lines) {
  for (final line in lines) {
    final match = RegExp(
      r'INTERNALDATE\s+"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) continue;
    final parsed = _parseImapInternalDate(match.group(1)!);
    if (parsed != null) return parsed;
  }
  return null;
}

int? _copyUidDestination(List<String> lines, int sourceUid) {
  for (final line in lines) {
    final match = RegExp(
      r'\[COPYUID\s+\d+\s+([^\s\]]+)\s+([^\s\]]+)\]',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) continue;
    final sourceSet = _expandUidSet(match.group(1)!);
    final destinationSet = _expandUidSet(match.group(2)!);
    if (sourceSet.isEmpty || sourceSet.length != destinationSet.length) {
      return destinationSet.length == 1 ? destinationSet.single : null;
    }
    final index = sourceSet.indexOf(sourceUid);
    if (index >= 0) return destinationSet[index];
    if (sourceSet.length == 1) return destinationSet.single;
  }
  return null;
}

List<int> _expandUidSet(String value) {
  final output = <int>[];
  for (final part in value.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final range = RegExp(r'^(\d+):(\d+)$').firstMatch(trimmed);
    if (range != null) {
      final start = int.parse(range.group(1)!);
      final end = int.parse(range.group(2)!);
      final step = start <= end ? 1 : -1;
      for (var uid = start; uid != end + step; uid += step) {
        output.add(uid);
        if (output.length > 1000) return output;
      }
      continue;
    }
    final uid = int.tryParse(trimmed);
    if (uid != null) output.add(uid);
  }
  return output;
}

List<int> _parseUidSearchValues(String values) {
  if (values.isEmpty) return const [];
  return values
      .split(' ')
      .where((part) => part.trim().isNotEmpty)
      .map(int.parse)
      .toList(growable: false);
}

Future<List<int>> _selectUidPageInBackground(
  List<int> uids, {
  required int limit,
  int? beforeUid,
}) {
  if (uids.length < _uidPageBackgroundSelectionThreshold) {
    return Future.value(
      _selectUidPage(uids, limit: limit, beforeUid: beforeUid),
    );
  }
  return Isolate.run(
    () => _selectUidPage(uids, limit: limit, beforeUid: beforeUid),
  );
}

Future<List<int>> _selectNewUidPageInBackground(
  List<int> uids, {
  required int afterUid,
  required int limit,
}) {
  List<int> select() {
    final ordered = uids.where((uid) => uid > afterUid).toList()..sort();
    return ordered.take(limit).toList(growable: false);
  }

  if (uids.length < _uidPageBackgroundSelectionThreshold) {
    return Future.value(select());
  }
  return Isolate.run(select);
}

List<int> _selectUidPage(List<int> uids, {required int limit, int? beforeUid}) {
  final selected = [...uids]..sort((a, b) => b.compareTo(a));
  return selected
      .where((uid) => beforeUid == null || uid < beforeUid)
      .take(limit)
      .toList(growable: false);
}

bool _hasMoreUidPage(List<int> uids, {required int limit, int? beforeUid}) {
  if (beforeUid == null) return uids.length > limit;
  var eligibleCount = 0;
  for (final uid in uids) {
    if (uid >= beforeUid) continue;
    eligibleCount++;
    if (eligibleCount > limit) return true;
  }
  return false;
}

final _mailboxChangeLine = RegExp(
  r'^\* \d+ (EXISTS|EXPUNGE|RECENT|FETCH)\b',
  caseSensitive: false,
);

bool _isMailboxChangeLine(String line) => _mailboxChangeLine.hasMatch(line);

/// Formats UIDs as an IMAP sequence set, collapsing consecutive runs into
/// `a:b` ranges so large flag refreshes stay short on the wire.
String _compactUidSet(Iterable<int> uids) {
  final sorted = uids.toSet().toList()..sort();
  final parts = <String>[];
  var index = 0;
  while (index < sorted.length) {
    final start = sorted[index];
    var end = start;
    while (index + 1 < sorted.length && sorted[index + 1] == end + 1) {
      index++;
      end = sorted[index];
    }
    parts.add(start == end ? '$start' : '$start:$end');
    index++;
  }
  return parts.join(',');
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
  final parsed = _uidFromMessageId(messageId);
  if (parsed == null || parsed <= 0) {
    throw MailTransportException('Invalid IMAP UID in message id: $messageId');
  }
  return parsed;
}

int? _uidFromMessageId(String messageId) {
  final raw = messageId.contains(':') ? messageId.split(':').last : messageId;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) return null;
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

  /// Fails every pending read and stops listening, so awaiting callers wake up
  /// even though the socket will never deliver another line.
  void abort() {
    _closed = true;
    _pendingError(const MailTransportException('socket closed'));
    unawaited(_subscription.cancel());
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
