import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../security/local_cache_crypto.dart';
import 'mail_cache.dart';
import 'mail_models.dart';
import 'mail_transport.dart';

class MailMessagePage {
  const MailMessagePage({required this.messages, required this.hasMore});

  final List<MailMessage> messages;
  final bool hasMore;
}

abstract class MailRepository {
  Future<List<MailAccount>> accounts();
  Future<List<MailFolder>> folders({String? accountId});
  Future<MailMessagePage> cachedViewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  });
  Future<MailMessagePage> viewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  });
  Future<MailMessagePage> loadOlderViewMessages({
    required MailboxView view,
    String? query,
    required int visibleCount,
    int limit = 30,
  });
  Future<MailMessagePage> cachedMessagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  });
  Future<MailMessagePage> messagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  });
  Future<MailMessagePage> loadOlderMessages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    required int visibleCount,
    int limit = 30,
  });
  Future<MailMessage> loadMessageBody(MailMessage message);
  Future<List<MailMessage>> messages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  });
  Future<void> sendReply({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  });
  Future<void> sendReplyAll({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  });
  Future<void> sendMessage({
    required String accountId,
    required String to,
    required String subject,
    required String textBody,
    String htmlBody = '',
    String cc = '',
    String bcc = '',
    List<OutgoingAttachment> attachments = const [],
  });
  Future<MailMessage> setRead({
    required MailMessage message,
    required bool read,
  });
  Future<MailMessage> setStarred({
    required MailMessage message,
    required bool starred,
  });
  Future<void> moveToMailbox({
    required MailMessage message,
    required MailboxKind destination,
  });
  Future<void> archive(MailMessage message);
  Future<void> delete(MailMessage message);
  Future<void> moveToInbox(MailMessage message);
  Future<File> downloadAttachment({
    required MailMessage message,
    required MailAttachment attachment,
  });
}

class DemoMailRepository implements MailRepository {
  const DemoMailRepository();

  @override
  Future<List<MailAccount>> accounts() async {
    return const [
      MailAccount(
        id: 'all',
        address: 'all inboxes',
        displayName: 'All inboxes',
        provider: 'nyamail',
      ),
    ];
  }

  @override
  Future<List<MailFolder>> folders({String? accountId}) async {
    return const [
      MailFolder(
        accountId: 'all',
        path: 'INBOX',
        displayName: 'Inbox',
        kind: MailboxKind.inbox,
      ),
    ];
  }

  @override
  Future<MailMessagePage> cachedViewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) {
    return viewPage(view: view, query: query, limit: limit);
  }

  @override
  Future<MailMessagePage> viewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) async {
    final messages = await _messagesForView(view, query: query);
    return MailMessagePage(
      messages: messages.take(limit).toList(),
      hasMore: messages.length > limit,
    );
  }

  @override
  Future<MailMessagePage> loadOlderViewMessages({
    required MailboxView view,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) {
    return viewPage(view: view, query: query, limit: visibleCount + limit);
  }

  @override
  Future<MailMessagePage> cachedMessagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) {
    return messagePage(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
      limit: limit,
    );
  }

  @override
  Future<MailMessagePage> messagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async {
    final page = await messages(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
      limit: limit,
    );
    final all = await messages(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
      limit: 1000000,
    );
    return MailMessagePage(messages: page, hasMore: all.length > page.length);
  }

  @override
  Future<MailMessagePage> loadOlderMessages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) {
    return messagePage(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
      limit: visibleCount + limit,
    );
  }

  @override
  Future<MailMessage> loadMessageBody(MailMessage message) async {
    return message;
  }

  @override
  Future<List<MailMessage>> messages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async {
    final now = DateTime.now();
    final messages = [
      MailMessage(
        id: 'welcome',
        accountId: 'all',
        from: 'NyaMail',
        subject: 'Welcome to your private synced inbox',
        preview: 'Connect a mailbox to start receiving mail on every device.',
        body: 'Connect a mailbox to start receiving mail on every device.',
        receivedAt: now.subtract(const Duration(minutes: 4)),
        hasAttachments: false,
      ),
      MailMessage(
        id: 'security',
        accountId: 'all',
        from: 'Security center',
        subject: 'Encrypted account vault is enabled',
        preview:
            'Mailbox credentials are synced as ciphertext and unlocked only on trusted devices.',
        body:
            'Mailbox credentials are synced as ciphertext and unlocked only on trusted devices.',
        receivedAt: now.subtract(const Duration(hours: 2)),
        read: true,
        starred: true,
      ),
      MailMessage(
        id: 'release',
        accountId: 'all',
        from: 'Release channel',
        subject: 'Self-hosted updates are ready',
        preview:
            'This build checks the backend release manifest for platform-specific updates.',
        body:
            'This build checks the backend release manifest for platform-specific updates.',
        receivedAt: now.subtract(const Duration(days: 1)),
        read: true,
        hasAttachments: true,
      ),
    ];
    if (query == null || query.trim().isEmpty) {
      return messages.take(limit).toList();
    }
    return messages
        .where((message) => mailMessageMatchesQuery(message, query))
        .take(limit)
        .toList();
  }

  Future<List<MailMessage>> _messagesForView(
    MailboxView view, {
    String? query,
  }) async {
    final all = await messages(mailbox: MailboxKind.inbox, limit: 1000000);
    final scoped =
        all.where((message) {
          final smart = view.smartFolder;
          if (smart != null) {
            return mailMessageMatchesSmartFolder(message, smart);
          }
          return mailMessageMatchesFolder(message, view.folder!);
        }).toList();
    if (query == null || query.trim().isEmpty) return scoped;
    return scoped
        .where((message) => mailMessageMatchesQuery(message, query))
        .toList();
  }

  @override
  Future<void> sendReply({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  }) async {
    throw const MailTransportException(
      'Connect a mailbox before sending mail.',
    );
  }

  @override
  Future<void> sendReplyAll({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  }) async {
    throw const MailTransportException(
      'Connect a mailbox before sending mail.',
    );
  }

  @override
  Future<void> sendMessage({
    required String accountId,
    required String to,
    required String subject,
    required String textBody,
    String htmlBody = '',
    String cc = '',
    String bcc = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {
    throw const MailTransportException(
      'Connect a mailbox before sending mail.',
    );
  }

  @override
  Future<MailMessage> setRead({
    required MailMessage message,
    required bool read,
  }) async {
    return message.copyWith(read: read);
  }

  @override
  Future<MailMessage> setStarred({
    required MailMessage message,
    required bool starred,
  }) async {
    return message.copyWith(starred: starred);
  }

  @override
  Future<void> moveToMailbox({
    required MailMessage message,
    required MailboxKind destination,
  }) async {}

  @override
  Future<void> archive(MailMessage message) async {}

  @override
  Future<void> delete(MailMessage message) async {}

  @override
  Future<void> moveToInbox(MailMessage message) async {}

  @override
  Future<File> downloadAttachment({
    required MailMessage message,
    required MailAttachment attachment,
  }) async {
    throw const MailTransportException(
      'Connect a mailbox before downloading attachments.',
    );
  }
}

class CachedTransportMailRepository implements MailRepository {
  const CachedTransportMailRepository({
    required MailMessageCache cache,
    required MailTransport transport,
    List<MailboxCredential> credentials = const [],
    String? cacheNamespace,
    String? localCacheSecret,
    bool backgroundIndexing = false,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _cache = cache,
       _transport = transport,
       _credentials = credentials,
       _cacheNamespace = cacheNamespace,
       _localCacheSecret = localCacheSecret,
       _backgroundIndexingEnabled = backgroundIndexing,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  final MailMessageCache _cache;
  final MailTransport _transport;
  final List<MailboxCredential> _credentials;
  final String? _cacheNamespace;
  final String? _localCacheSecret;
  final bool _backgroundIndexingEnabled;
  final Future<Directory> Function() _supportDirectoryProvider;
  static final Set<String> _backgroundIndexing = <String>{};

  @override
  Future<List<MailAccount>> accounts() async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().accounts();
    }
    return _credentials
        .map(
          (credential) => MailAccount(
            id: credential.accountId,
            address: credential.address,
            displayName: credential.displayName,
            provider: 'imap',
          ),
        )
        .toList();
  }

  @override
  Future<List<MailFolder>> folders({String? accountId}) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().folders(accountId: accountId);
    }
    final folders = <MailFolder>[];
    for (final credential in _scopedCredentials(accountId)) {
      folders.addAll(await _foldersForCredential(credential));
    }
    return folders;
  }

  @override
  Future<MailMessagePage> cachedViewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().cachedViewPage(
        view: view,
        query: query,
        limit: limit,
      );
    }
    final cached = await _scopedCachedMessagesForView(view: view, query: query);
    return MailMessagePage(
      messages: cached.take(limit).toList(),
      hasMore: cached.length > limit,
    );
  }

  @override
  Future<MailMessagePage> viewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().viewPage(
        view: view,
        query: query,
        limit: limit,
      );
    }
    var hasFullRemotePage = false;
    for (final folder in await _foldersForView(view)) {
      final credential = _credentialForAccount(folder.accountId);
      if (credential == null) continue;
      final fetched = await _fetchPreviewPageForFolder(
        credential: credential,
        folder: folder,
        limit: limit,
      );
      hasFullRemotePage = hasFullRemotePage || fetched.hasMore;
    }
    final cached = await _scopedCachedMessagesForView(view: view, query: query);
    _scheduleBackgroundIndexForView(view: view, pageSize: limit);
    return MailMessagePage(
      messages: cached.take(limit).toList(),
      hasMore: cached.length > limit || hasFullRemotePage,
    );
  }

  @override
  Future<MailMessagePage> loadOlderViewMessages({
    required MailboxView view,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().loadOlderViewMessages(
        view: view,
        query: query,
        visibleCount: visibleCount,
        limit: limit,
      );
    }
    final targetLimit = visibleCount + limit;
    var cached = await _scopedCachedMessagesForView(view: view, query: query);
    var hasFullRemotePage = false;
    if (cached.length < targetLimit) {
      for (final folder in await _foldersForView(view)) {
        final credential = _credentialForAccount(folder.accountId);
        if (credential == null) continue;
        final beforeUid = await _oldestCachedUidForFolder(folder);
        final fetched = await _fetchPreviewPageForFolder(
          credential: credential,
          folder: folder,
          limit: limit,
          beforeUid: beforeUid,
        );
        hasFullRemotePage = hasFullRemotePage || fetched.hasMore;
      }
      cached = await _scopedCachedMessagesForView(view: view, query: query);
    }
    _scheduleBackgroundIndexForView(view: view, pageSize: limit);
    return MailMessagePage(
      messages: cached.take(targetLimit).toList(),
      hasMore: cached.length > targetLimit || hasFullRemotePage,
    );
  }

  @override
  Future<MailMessagePage> cachedMessagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().cachedMessagePage(
        mailbox: mailbox,
        accountId: accountId,
        query: query,
        limit: limit,
      );
    }
    final cached = await _scopedCachedMessages(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
    );
    return MailMessagePage(
      messages: cached.take(limit).toList(),
      hasMore: cached.length > limit,
    );
  }

  @override
  Future<MailMessagePage> messagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().messagePage(
        mailbox: mailbox,
        accountId: accountId,
        query: query,
        limit: limit,
      );
    }
    var hasFullRemotePage = false;
    for (final credential in _scopedCredentials(accountId)) {
      final fetched = await _fetchPreviewPage(
        credential: credential,
        mailbox: mailbox,
        limit: limit,
      );
      hasFullRemotePage = hasFullRemotePage || fetched.hasMore;
    }
    final cached = await _scopedCachedMessages(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
    );
    _scheduleBackgroundIndex(
      mailbox: mailbox,
      accountId: accountId,
      pageSize: limit,
    );
    return MailMessagePage(
      messages: cached.take(limit).toList(),
      hasMore: cached.length > limit || hasFullRemotePage,
    );
  }

  @override
  Future<MailMessagePage> loadOlderMessages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) async {
    if (_credentials.isEmpty) {
      return const DemoMailRepository().loadOlderMessages(
        mailbox: mailbox,
        accountId: accountId,
        query: query,
        visibleCount: visibleCount,
        limit: limit,
      );
    }
    final targetLimit = visibleCount + limit;
    var cached = await _scopedCachedMessages(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
    );
    var hasFullRemotePage = false;
    if (cached.length < targetLimit) {
      for (final credential in _scopedCredentials(accountId)) {
        final beforeUid = await _oldestCachedUid(
          accountId: credential.accountId,
          mailbox: mailbox,
        );
        final fetched = await _fetchPreviewPage(
          credential: credential,
          mailbox: mailbox,
          limit: limit,
          beforeUid: beforeUid,
        );
        hasFullRemotePage = hasFullRemotePage || fetched.hasMore;
      }
      cached = await _scopedCachedMessages(
        mailbox: mailbox,
        accountId: accountId,
        query: query,
      );
    }
    _scheduleBackgroundIndex(
      mailbox: mailbox,
      accountId: accountId,
      pageSize: limit,
    );
    return MailMessagePage(
      messages: cached.take(targetLimit).toList(),
      hasMore: cached.length > targetLimit || hasFullRemotePage,
    );
  }

  @override
  Future<MailMessage> loadMessageBody(MailMessage message) async {
    if (_credentials.isEmpty || message.bodyLoaded) return message;
    final credential = _credentialFor(message);
    if (credential == null) return message;
    final loaded = await _transport.fetchMessageBody(
      credential: credential,
      message: message,
    );
    await _cache.updateMessage(loaded);
    return loaded;
  }

  @override
  Future<List<MailMessage>> messages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async {
    return (await messagePage(
      mailbox: mailbox,
      accountId: accountId,
      query: query,
      limit: limit,
    )).messages;
  }

  @override
  Future<void> sendReply({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  }) async {
    final credential =
        _credentials
            .where((item) => item.accountId == original.accountId)
            .firstOrNull;
    if (credential == null) {
      throw const MailTransportException(
        'No sending credential is available for this message.',
      );
    }
    final recipients = _replyRecipients(original, credential);
    if (recipients.isEmpty) {
      throw const MailTransportException(
        'No reply recipient is available for this message.',
      );
    }
    await _transport.send(
      credential: credential,
      message: OutgoingMessage(
        from: credential.address,
        to: recipients,
        subject: _replySubject(original.subject),
        textBody: textBody,
        htmlBody: htmlBody,
      ),
    );
    await _cache.saveMessages([
      _sentCacheMessage(
        credential: credential,
        to: recipients.join(', '),
        subject: _replySubject(original.subject),
        textBody: textBody,
        htmlBody: htmlBody,
      ),
    ]);
  }

  @override
  Future<void> sendReplyAll({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
  }) async {
    final credential =
        _credentials
            .where((item) => item.accountId == original.accountId)
            .firstOrNull;
    if (credential == null) {
      throw const MailTransportException(
        'No sending credential is available for this message.',
      );
    }
    final replyAll = _replyAllRecipients(original, credential);
    if (replyAll.to.isEmpty && replyAll.cc.isEmpty) {
      throw const MailTransportException(
        'No reply-all recipient is available for this message.',
      );
    }
    await _transport.send(
      credential: credential,
      message: OutgoingMessage(
        from: credential.address,
        to: replyAll.to,
        cc: replyAll.cc,
        subject: _replySubject(original.subject),
        textBody: textBody,
        htmlBody: htmlBody,
      ),
    );
    await _cache.saveMessages([
      _sentCacheMessage(
        credential: credential,
        to: _recipientSummary(to: replyAll.to, cc: replyAll.cc),
        subject: _replySubject(original.subject),
        textBody: textBody,
        htmlBody: htmlBody,
      ),
    ]);
  }

  @override
  Future<void> sendMessage({
    required String accountId,
    required String to,
    required String subject,
    required String textBody,
    String htmlBody = '',
    String cc = '',
    String bcc = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {
    final credential =
        _credentials.where((item) => item.accountId == accountId).firstOrNull;
    if (credential == null) {
      throw const MailTransportException(
        'No sending credential is available for this account.',
      );
    }
    final recipients = _parseRecipients(to);
    final ccRecipients = _parseRecipients(cc);
    final bccRecipients = _parseRecipients(bcc);
    if ([...recipients, ...ccRecipients, ...bccRecipients].isEmpty) {
      throw const MailTransportException('At least one recipient is required.');
    }
    final outgoing = OutgoingMessage(
      from: credential.address,
      to: recipients,
      cc: ccRecipients,
      bcc: bccRecipients,
      subject: subject.trim().isEmpty ? '(no subject)' : subject.trim(),
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: attachments,
    );
    await _transport.send(credential: credential, message: outgoing);
    await _cache.saveMessages([
      _sentCacheMessage(
        credential: credential,
        to: _recipientSummary(to: recipients, cc: ccRecipients),
        subject: outgoing.subject,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: attachments,
      ),
    ]);
  }

  @override
  Future<MailMessage> setRead({
    required MailMessage message,
    required bool read,
  }) async {
    final credential = _credentialFor(message);
    if (credential != null) {
      await _transport.setSeen(
        credential: credential,
        messageId: message.id,
        seen: read,
      );
    }
    final updated = message.copyWith(read: read);
    await _cache.updateMessage(updated);
    return updated;
  }

  @override
  Future<MailMessage> setStarred({
    required MailMessage message,
    required bool starred,
  }) async {
    final credential = _credentialFor(message);
    if (credential != null) {
      await _transport.setFlagged(
        credential: credential,
        messageId: message.id,
        flagged: starred,
      );
    }
    final updated = message.copyWith(starred: starred);
    await _cache.updateMessage(updated);
    return updated;
  }

  @override
  Future<void> archive(MailMessage message) async {
    await moveToMailbox(message: message, destination: MailboxKind.archive);
  }

  @override
  Future<void> delete(MailMessage message) async {
    await moveToMailbox(message: message, destination: MailboxKind.trash);
  }

  @override
  Future<void> moveToInbox(MailMessage message) async {
    await moveToMailbox(message: message, destination: MailboxKind.inbox);
  }

  @override
  Future<void> moveToMailbox({
    required MailMessage message,
    required MailboxKind destination,
  }) async {
    if (message.mailbox == destination) return;
    final credential = _credentialFor(message);
    if (credential != null) {
      await _transport.moveMessage(
        credential: credential,
        messageId: message.id,
        destination: destination,
      );
    }
    await _cache.updateMessage(
      message.copyWith(
        mailbox: destination,
        folderPath: '',
        folderDisplayName: '',
      ),
    );
  }

  @override
  Future<File> downloadAttachment({
    required MailMessage message,
    required MailAttachment attachment,
  }) async {
    final credential = _credentialFor(message);
    if (credential == null) {
      throw const MailTransportException(
        'No credential is available for this attachment.',
      );
    }
    final supportDir = await _supportDirectoryProvider();
    final namespace = _safeOptionalPathSegment(_cacheNamespace);
    final attachmentRoot =
        namespace == null
            ? '${supportDir.path}/mail-attachments'
            : '${supportDir.path}/mail-attachments/$namespace';
    final attachmentDir = Directory(
      '$attachmentRoot/'
      '${_safePathSegment(message.id)}/'
      '${_attachmentCacheKey(attachment)}',
    );
    await attachmentDir.create(recursive: true);
    final cipher = _localCacheCipher;
    if (cipher != null) {
      await _clearOpenAttachmentFiles(attachmentDir);
    }
    await _deleteStaleAttachmentTemps(attachmentDir);

    final cached = await _cachedAttachmentFile(
      attachmentDir,
      attachment.size,
      cipher: cipher,
    );
    if (cached != null) return cached;

    final downloaded = await _transport.downloadAttachment(
      credential: credential,
      messageId: message.id,
      attachment: attachment,
    );
    if (cipher == null) {
      final file = File(
        '${attachmentDir.path}/${_safeFilename(downloaded.filename)}',
      );
      await _writeAttachmentAtomically(file, downloaded.bytes);
      return file;
    }
    await _writeEncryptedAttachmentAtomically(
      dir: attachmentDir,
      filename: downloaded.filename,
      contentType: downloaded.contentType,
      bytes: downloaded.bytes,
      cipher: cipher,
    );
    return _writeOpenAttachmentFile(
      dir: attachmentDir,
      filename: downloaded.filename,
      bytes: downloaded.bytes,
    );
  }

  List<MailboxCredential> _scopedCredentials(String? accountId) {
    return _credentials
        .where(
          (credential) =>
              accountId == null || credential.accountId == accountId,
        )
        .toList(growable: false);
  }

  Future<_PreviewFetchResult> _fetchPreviewPage({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    required int limit,
    int? beforeUid,
  }) async {
    try {
      final fetched = await _transport.fetchMessagePreviews(
        credential: credential,
        mailbox: mailbox,
        limit: limit,
        beforeUid: beforeUid,
      );
      await _cache.saveMessages(fetched);
      await _reconcileFetchedPreviewWindow(
        credential: credential,
        mailbox: mailbox,
        messages: fetched,
        limit: limit,
        beforeUid: beforeUid,
      );
      return _PreviewFetchResult(messages: fetched, requestedLimit: limit);
    } catch (_) {
      // Keep cached mail available when the provider is offline or credentials need attention.
      return const _PreviewFetchResult(messages: [], requestedLimit: 0);
    }
  }

  Future<_PreviewFetchResult> _fetchPreviewPageForFolder({
    required MailboxCredential credential,
    required MailFolder folder,
    required int limit,
    int? beforeUid,
  }) async {
    try {
      final fetched = await _transport.fetchFolderMessagePreviews(
        credential: credential,
        folder: folder,
        limit: limit,
        beforeUid: beforeUid,
      );
      await _cache.saveMessages(fetched);
      await _reconcileFetchedPreviewWindowForFolder(
        credential: credential,
        folder: folder,
        messages: fetched,
        limit: limit,
        beforeUid: beforeUid,
      );
      return _PreviewFetchResult(messages: fetched, requestedLimit: limit);
    } catch (_) {
      return const _PreviewFetchResult(messages: [], requestedLimit: 0);
    }
  }

  Future<void> _reconcileFetchedPreviewWindow({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    required List<MailMessage> messages,
    required int limit,
    int? beforeUid,
  }) async {
    final fetchedUids = <int>{
      for (final message in messages)
        if (_messageUid(message.id) case final uid?) uid,
    };
    final fetchedIds = {for (final message in messages) message.id};
    final fetchedAllRemaining = messages.length < limit;
    final minFetchedUid =
        fetchedUids.isEmpty
            ? null
            : fetchedUids.reduce((a, b) => a < b ? a : b);
    final cached = await _cache.loadMessages(mailbox: mailbox);
    for (final message in cached) {
      if (message.accountId != credential.accountId) continue;
      final uid = _messageUid(message.id);
      if (uid == null) continue;
      final inFetchedWindow =
          beforeUid == null
              ? (fetchedAllRemaining ||
                  minFetchedUid == null ||
                  uid >= minFetchedUid)
              : uid < beforeUid &&
                  (fetchedAllRemaining ||
                      minFetchedUid == null ||
                      uid >= minFetchedUid);
      if (!inFetchedWindow) continue;
      if (fetchedUids.contains(uid)) {
        if (!fetchedIds.contains(message.id)) {
          await _cache.deleteMessage(message.id);
        }
        continue;
      }
      await _cache.deleteMessage(message.id);
    }
  }

  Future<void> _reconcileFetchedPreviewWindowForFolder({
    required MailboxCredential credential,
    required MailFolder folder,
    required List<MailMessage> messages,
    required int limit,
    int? beforeUid,
  }) async {
    final fetchedUids = <int>{
      for (final message in messages)
        if (_messageUid(message.id) case final uid?) uid,
    };
    final fetchedIds = {for (final message in messages) message.id};
    final fetchedAllRemaining = messages.length < limit;
    final minFetchedUid =
        fetchedUids.isEmpty
            ? null
            : fetchedUids.reduce((a, b) => a < b ? a : b);
    final cached = await _cache.loadMessages(
      mailbox: folder.kind,
      accountId: credential.accountId,
      folderPath: folder.path,
    );
    for (final message in cached) {
      final uid = _messageUid(message.id);
      if (uid == null) continue;
      final inFetchedWindow =
          beforeUid == null
              ? (fetchedAllRemaining ||
                  minFetchedUid == null ||
                  uid >= minFetchedUid)
              : uid < beforeUid &&
                  (fetchedAllRemaining ||
                      minFetchedUid == null ||
                      uid >= minFetchedUid);
      if (!inFetchedWindow) continue;
      if (fetchedUids.contains(uid)) {
        if (!fetchedIds.contains(message.id)) {
          await _cache.deleteMessage(message.id);
        }
        continue;
      }
      await _cache.deleteMessage(message.id);
    }
  }

  Future<List<MailMessage>> _scopedCachedMessages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
  }) async {
    final cached = await _cache.loadMessages(mailbox: mailbox, query: query);
    final activeAccountIds =
        _credentials.map((credential) => credential.accountId).toSet();
    final scoped =
        cached
            .where(
              (message) =>
                  activeAccountIds.contains(message.accountId) &&
                  (accountId == null || message.accountId == accountId),
            )
            .toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return scoped;
  }

  Future<List<MailMessage>> _scopedCachedMessagesForView({
    required MailboxView view,
    String? query,
  }) async {
    final cached = await _cache.loadMessages(query: query);
    final activeAccountIds =
        _credentials.map((credential) => credential.accountId).toSet();
    final scoped =
        _dedupeCachedMessages(
            cached.where((message) {
              if (!activeAccountIds.contains(message.accountId)) return false;
              final smart = view.smartFolder;
              if (smart != null) {
                return mailMessageMatchesSmartFolder(message, smart);
              }
              return mailMessageMatchesFolder(message, view.folder!);
            }),
          ).toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return scoped;
  }

  List<MailMessage> _dedupeCachedMessages(Iterable<MailMessage> messages) {
    final byRemoteLocation = <String, MailMessage>{};
    for (final message in messages) {
      final key = _remoteLocationKey(message);
      final existing = byRemoteLocation[key];
      byRemoteLocation[key] =
          existing == null ? message : _preferredCachedMessage(existing, message);
    }
    return byRemoteLocation.values.toList();
  }

  String _remoteLocationKey(MailMessage message) {
    final uid = _messageUid(message.id);
    if (uid == null) return 'id:${message.id}';
    final folderPath = message.effectiveFolderPath;
    if (folderPath.trim().isNotEmpty && folderPath != message.mailbox.name) {
      return '${message.accountId}:folder:$folderPath:$uid';
    }
    return '${message.accountId}:mailbox:${message.effectiveMailbox.name}:$uid';
  }

  MailMessage _preferredCachedMessage(MailMessage a, MailMessage b) {
    return _cachedMessageScore(b) > _cachedMessageScore(a) ? b : a;
  }

  int _cachedMessageScore(MailMessage message) {
    var score = 0;
    if (message.mailbox == message.effectiveMailbox) score += 4;
    if (message.bodyLoaded) score += 2;
    if (message.hasAttachments) score += 1;
    return score;
  }

  Future<int?> _oldestCachedUid({
    required String accountId,
    required MailboxKind mailbox,
  }) async {
    final cached = await _cache.loadMessages(mailbox: mailbox);
    int? oldest;
    for (final message in cached) {
      if (message.accountId != accountId) continue;
      final uid = _messageUid(message.id);
      if (uid == null) continue;
      if (oldest == null || uid < oldest) oldest = uid;
    }
    return oldest;
  }

  Future<int?> _oldestCachedUidForFolder(MailFolder folder) async {
    final cached = await _cache.loadMessages(
      mailbox: folder.kind,
      accountId: folder.accountId,
      folderPath: folder.path,
    );
    int? oldest;
    for (final message in cached) {
      final uid = _messageUid(message.id);
      if (uid == null) continue;
      if (oldest == null || uid < oldest) oldest = uid;
    }
    return oldest;
  }

  Future<List<MailFolder>> _foldersForView(MailboxView view) async {
    final folder = view.folder;
    if (folder != null) return [folder];
    final smart = view.smartFolder!;
    final folders = <MailFolder>[];
    for (final credential in _credentials) {
      final accountFolders = await _foldersForCredential(credential);
      folders.addAll(
        accountFolders.where((folder) {
          if (!folder.selectable) return false;
          if (smart == MailSmartFolder.allIncoming) return folder.isIncoming;
          return folder.kind == smart.mailbox;
        }),
      );
    }
    return folders;
  }

  Future<List<MailFolder>> _foldersForCredential(
    MailboxCredential credential,
  ) async {
    try {
      final folders = await _transport.listFolders(credential: credential);
      if (folders.isNotEmpty) return folders;
    } catch (_) {
      // Fall back to common folders so cached mail and basic providers stay usable.
    }
    return [
      for (final mailbox in standardMailboxKinds)
        MailFolder(
          accountId: credential.accountId,
          path:
              mailbox == MailboxKind.inbox
                  ? 'INBOX'
                  : _fallbackFolderPath(mailbox),
          displayName: _fallbackFolderPath(mailbox),
          kind: mailbox,
        ),
    ];
  }

  void _scheduleBackgroundIndex({
    required MailboxKind mailbox,
    String? accountId,
    required int pageSize,
  }) {
    if (!_backgroundIndexingEnabled) return;
    for (final credential in _scopedCredentials(accountId)) {
      final key = '${credential.accountId}:${mailbox.name}';
      if (!_backgroundIndexing.add(key)) continue;
      unawaited(
        _indexOlderCredential(
          credential: credential,
          mailbox: mailbox,
          pageSize: pageSize,
        ).whenComplete(() => _backgroundIndexing.remove(key)),
      );
    }
  }

  void _scheduleBackgroundIndexForView({
    required MailboxView view,
    required int pageSize,
  }) {
    if (!_backgroundIndexingEnabled) return;
    unawaited(
      _scheduleBackgroundIndexForViewAsync(view: view, pageSize: pageSize),
    );
  }

  Future<void> _scheduleBackgroundIndexForViewAsync({
    required MailboxView view,
    required int pageSize,
  }) async {
    for (final folder in await _foldersForView(view)) {
      final credential = _credentialForAccount(folder.accountId);
      if (credential == null) continue;
      final key = '${folder.accountId}:${folder.path}';
      if (!_backgroundIndexing.add(key)) continue;
      unawaited(
        _indexOlderCredentialFolder(
          credential: credential,
          folder: folder,
          pageSize: pageSize,
        ).whenComplete(() => _backgroundIndexing.remove(key)),
      );
    }
  }

  Future<void> _indexOlderCredential({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    required int pageSize,
  }) async {
    final beforeUid = await _oldestCachedUid(
      accountId: credential.accountId,
      mailbox: mailbox,
    );
    if (beforeUid == null) return;
    await _fetchPreviewPage(
      credential: credential,
      mailbox: mailbox,
      limit: pageSize,
      beforeUid: beforeUid,
    );
  }

  Future<void> _indexOlderCredentialFolder({
    required MailboxCredential credential,
    required MailFolder folder,
    required int pageSize,
  }) async {
    final beforeUid = await _oldestCachedUidForFolder(folder);
    if (beforeUid == null) return;
    await _fetchPreviewPageForFolder(
      credential: credential,
      folder: folder,
      limit: pageSize,
      beforeUid: beforeUid,
    );
  }

  int? _messageUid(String messageId) {
    final raw = messageId.contains(':') ? messageId.split(':').last : messageId;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  MailboxCredential? _credentialFor(MailMessage message) {
    return _credentials
        .where((item) => item.accountId == message.accountId)
        .firstOrNull;
  }

  MailboxCredential? _credentialForAccount(String accountId) {
    return _credentials
        .where((item) => item.accountId == accountId)
        .firstOrNull;
  }

  LocalCacheCipher? get _localCacheCipher {
    final secret = _localCacheSecret?.trim();
    if (secret == null || secret.isEmpty) return null;
    return LocalCacheCipher(secret);
  }
}

class _PreviewFetchResult {
  const _PreviewFetchResult({
    required this.messages,
    required this.requestedLimit,
  });

  final List<MailMessage> messages;
  final int requestedLimit;

  bool get hasMore => messages.length >= requestedLimit && requestedLimit > 0;
}

const _encryptedAttachmentExtension = '.nyacache';
const _openAttachmentDirName = '.nyamail-open';

Future<File?> _cachedAttachmentFile(
  Directory dir,
  int? expectedSize, {
  LocalCacheCipher? cipher,
}) async {
  if (cipher != null) {
    final encrypted = await _cachedEncryptedAttachmentFile(
      dir,
      expectedSize,
      cipher,
    );
    if (encrypted != null) return encrypted;
    final legacy = await _cachedPlainAttachmentFile(dir, expectedSize);
    if (legacy == null) return null;
    final bytes = await legacy.readAsBytes();
    final filename = _filename(legacy.path);
    await _writeEncryptedAttachmentAtomically(
      dir: dir,
      filename: filename,
      contentType: 'application/octet-stream',
      bytes: bytes,
      cipher: cipher,
    );
    try {
      await legacy.delete();
    } catch (_) {
      // A viewer may still hold the legacy file. It will be cleaned on sign-out.
    }
    return _writeOpenAttachmentFile(dir: dir, filename: filename, bytes: bytes);
  }
  return _cachedPlainAttachmentFile(dir, expectedSize);
}

Future<File?> _cachedEncryptedAttachmentFile(
  Directory dir,
  int? expectedSize,
  LocalCacheCipher cipher,
) async {
  if (!await dir.exists()) return null;
  final files =
      await dir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .where(
            (file) =>
                _filename(file.path).endsWith(_encryptedAttachmentExtension),
          )
          .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final payload = await cipher.tryDecryptPayload(
      await file.readAsString(encoding: utf8),
    );
    if (payload == null) continue;
    if (expectedSize != null && payload.bytes.length != expectedSize) continue;
    final filename =
        payload.metadata['filename'] as String? ??
        _filename(file.path).replaceFirst(
          RegExp('${RegExp.escape(_encryptedAttachmentExtension)}\$'),
          '',
        );
    return _writeOpenAttachmentFile(
      dir: dir,
      filename: filename,
      bytes: payload.bytes,
    );
  }
  return null;
}

Future<File?> _cachedPlainAttachmentFile(
  Directory dir,
  int? expectedSize,
) async {
  if (!await dir.exists()) return null;
  final files =
      await dir.list().where((entity) => entity is File).cast<File>().where((
        file,
      ) {
        final name = _filename(file.path);
        return !name.startsWith('.nyamail-download-') &&
            !name.endsWith('.download') &&
            !name.endsWith(_encryptedAttachmentExtension);
      }).toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (expectedSize == null) return file;
    if (await file.length() == expectedSize) return file;
  }
  return null;
}

Future<void> _writeAttachmentAtomically(File target, List<int> bytes) async {
  final parent = target.parent;
  await parent.create(recursive: true);
  await _deleteStaleAttachmentTemps(parent);
  final temp = File(
    '${parent.path}/.nyamail-download-${DateTime.now().microsecondsSinceEpoch}.download',
  );
  try {
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
  } catch (_) {
    if (await temp.exists()) {
      await temp.delete();
    }
    rethrow;
  }
}

Future<void> _writeEncryptedAttachmentAtomically({
  required Directory dir,
  required String filename,
  required String contentType,
  required List<int> bytes,
  required LocalCacheCipher cipher,
}) async {
  await dir.create(recursive: true);
  await _deleteStaleAttachmentTemps(dir);
  final target = File(
    '${dir.path}/${_safeFilename(filename)}$_encryptedAttachmentExtension',
  );
  final temp = File(
    '${dir.path}/.nyamail-download-${DateTime.now().microsecondsSinceEpoch}.download',
  );
  try {
    final encrypted = await cipher.encryptBytesToText(
      bytes,
      metadata: {'filename': filename, 'content_type': contentType},
    );
    await temp.writeAsString(encrypted, encoding: utf8, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
  } catch (_) {
    if (await temp.exists()) {
      await temp.delete();
    }
    rethrow;
  }
}

Future<File> _writeOpenAttachmentFile({
  required Directory dir,
  required String filename,
  required List<int> bytes,
}) async {
  final openDir = Directory('${dir.path}/$_openAttachmentDirName');
  if (await openDir.exists()) {
    await openDir.delete(recursive: true);
  }
  await openDir.create(recursive: true);
  final file = File('${openDir.path}/${_safeFilename(filename)}');
  await _writeAttachmentAtomically(file, bytes);
  return file;
}

Future<void> _clearOpenAttachmentFiles(Directory dir) async {
  final openDir = Directory('${dir.path}/$_openAttachmentDirName');
  if (await openDir.exists()) {
    await openDir.delete(recursive: true);
  }
}

Future<void> _deleteStaleAttachmentTemps(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final name = _filename(entity.path);
    if (name.startsWith('.nyamail-download-') && name.endsWith('.download')) {
      try {
        await entity.delete();
      } catch (_) {
        // A concurrent download may still own this file.
      }
    }
  }
}

Future<void> clearMailAttachmentCache({
  required String cacheNamespace,
  Future<Directory> Function()? supportDirectoryProvider,
}) async {
  final namespace = _safeOptionalPathSegment(cacheNamespace);
  if (namespace == null) return;
  final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
  final supportDir = await provider();
  final dir = Directory('${supportDir.path}/mail-attachments/$namespace');
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
}

Future<void> clearLegacyMailAttachmentCache({
  Future<Directory> Function()? supportDirectoryProvider,
}) async {
  final provider = supportDirectoryProvider ?? getApplicationSupportDirectory;
  final supportDir = await provider();
  final root = Directory('${supportDir.path}/mail-attachments');
  if (!await root.exists()) return;
  await for (final entity in root.list()) {
    final name = _filename(entity.path);
    if (_isGeneratedUserNamespace(name)) continue;
    if (entity is File) {
      await entity.delete();
    } else if (entity is Directory) {
      await entity.delete(recursive: true);
    }
  }
}

String _attachmentCacheKey(MailAttachment attachment) {
  final raw =
      attachment.partId.isEmpty ? attachment.filename : attachment.partId;
  return _safePathSegment(raw);
}

String _filename(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}

String _safeFilename(String value) {
  final cleaned =
      value
          .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'attachment';
  }
  return cleaned.length <= 160 ? cleaned : cleaned.substring(0, 160);
}

String _safePathSegment(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'message';
  }
  return cleaned.length <= 120 ? cleaned : cleaned.substring(0, 120);
}

String? _safeOptionalPathSegment(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return null;
  return _safePathSegment(raw);
}

String _fallbackFolderPath(MailboxKind mailbox) {
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

bool _isGeneratedUserNamespace(String value) {
  return RegExp(r'^user-[0-9a-f]{24}$').hasMatch(value);
}

MailMessage _sentCacheMessage({
  required MailboxCredential credential,
  required String to,
  required String subject,
  required String textBody,
  String htmlBody = '',
  List<OutgoingAttachment> attachments = const [],
}) {
  final now = DateTime.now().toUtc();
  final normalizedSubject = subject.trim().isEmpty ? '(no subject)' : subject;
  final preview = textBody.replaceAll(RegExp(r'\s+'), ' ').trim();
  final attachmentMetadata = [
    for (final attachment in attachments)
      MailAttachment(
        filename: attachment.filename,
        contentType: attachment.contentType,
        partId: '',
        size: attachment.bytes.length,
      ),
  ];
  return MailMessage(
    id: '${credential.accountId}:sent:local-${now.microsecondsSinceEpoch}',
    accountId: credential.accountId,
    from: 'To: $to',
    subject: normalizedSubject,
    preview:
        preview.length <= 180 ? preview : '${preview.substring(0, 180)}...',
    body: textBody,
    htmlBody: htmlBody,
    receivedAt: now,
    mailbox: MailboxKind.sent,
    folderPath: _fallbackFolderPath(MailboxKind.sent),
    folderDisplayName: _fallbackFolderPath(MailboxKind.sent),
    read: true,
    hasAttachments: attachmentMetadata.isNotEmpty,
    attachments: attachmentMetadata,
  );
}

String extractEmailAddress(String value) {
  final match = RegExp(r'<([^>]+)>').firstMatch(value);
  if (match != null) return match.group(1)!.trim();
  return value.trim();
}

String forwardSubjectFor(String subject) {
  final normalized = subject.trim().isEmpty ? '(no subject)' : subject.trim();
  final lower = normalized.toLowerCase();
  if (lower.startsWith('fwd:') || lower.startsWith('fw:')) {
    return normalized;
  }
  return 'Fwd: $normalized';
}

String forwardBodyFor(MailMessage message) {
  final body = message.body.trim().isEmpty ? message.preview : message.body;
  final lines = [
    '',
    '',
    '---------- Forwarded message ---------',
    'From: ${message.from}',
    if (message.to.isNotEmpty) 'To: ${message.to.join(', ')}',
    if (message.cc.isNotEmpty) 'Cc: ${message.cc.join(', ')}',
    'Date: ${message.receivedAt.toUtc().toIso8601String()}',
    'Subject: ${message.subject}',
    '',
    body,
  ];
  return lines.join('\n');
}

String _replySubject(String subject) {
  return subject.toLowerCase().startsWith('re:') ? subject : 'Re: $subject';
}

List<String> _replyRecipients(
  MailMessage original,
  MailboxCredential credential,
) {
  final primary =
      original.replyTo.isNotEmpty
          ? original.replyTo
          : [extractEmailAddress(original.from)];
  return _withoutSelf(primary, credential).toList();
}

({List<String> to, List<String> cc}) _replyAllRecipients(
  MailMessage original,
  MailboxCredential credential,
) {
  final seen = <String>{};
  List<String> collect(Iterable<String> values) {
    final recipients = <String>[];
    for (final value in _withoutSelf(values, credential)) {
      final lower = value.toLowerCase();
      if (!seen.add(lower)) continue;
      recipients.add(value);
    }
    return recipients;
  }

  final primary =
      original.replyTo.isNotEmpty
          ? original.replyTo
          : [extractEmailAddress(original.from)];
  return (to: collect([...primary, ...original.to]), cc: collect(original.cc));
}

Iterable<String> _withoutSelf(
  Iterable<String> values,
  MailboxCredential credential,
) sync* {
  final own = credential.address.toLowerCase();
  final username = credential.username.toLowerCase();
  for (final value in values) {
    final address = extractEmailAddress(value).trim();
    if (address.isEmpty) continue;
    final lower = address.toLowerCase();
    if (lower == own || lower == username) continue;
    yield address;
  }
}

List<String> _parseRecipients(String value) {
  return value
      .split(RegExp(r'[;,]'))
      .map(extractEmailAddress)
      .where((item) => item.isNotEmpty)
      .toList();
}

String _recipientSummary({required List<String> to, required List<String> cc}) {
  final summary = to.isEmpty ? 'undisclosed recipients' : to.join(', ');
  if (cc.isEmpty) return summary;
  return '$summary  Cc: ${cc.join(', ')}';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
