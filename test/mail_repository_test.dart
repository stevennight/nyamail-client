import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_cache.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_repository.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nyamail-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('extractEmailAddress reads angle address', () {
    expect(
      extractEmailAddress('Alice <alice@example.com>'),
      'alice@example.com',
    );
  });

  test('extractEmailAddress keeps plain address', () {
    expect(extractEmailAddress('alice@example.com'), 'alice@example.com');
  });

  test('forward helpers build subject and quoted body', () {
    final original = MailMessage(
      id: 'work:inbox:forward',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      to: const ['me@example.com'],
      cc: const ['team@example.com'],
      subject: 'Planning',
      preview: 'Preview',
      body: 'Original body',
      receivedAt: DateTime.utc(2026, 7, 1, 8, 30),
    );

    expect(forwardSubjectFor('Planning'), 'Fwd: Planning');
    expect(forwardSubjectFor('Fwd: Planning'), 'Fwd: Planning');
    final body = forwardBodyFor(original);
    expect(body, contains('---------- Forwarded message ---------'));
    expect(body, contains('From: Alice <alice@example.com>'));
    expect(body, contains('To: me@example.com'));
    expect(body, contains('Cc: team@example.com'));
    expect(body, contains('Subject: Planning'));
    expect(body, contains('Original body'));
  });

  test('sendMessage uses selected account and parses recipients', () async {
    final transport = _RecordingTransport();
    final cache = _MemoryMailCache();
    final repository = CachedTransportMailRepository(
      cache: cache,
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    await repository.sendMessage(
      accountId: 'work',
      to: 'Alice <alice@example.com>; bob@example.com',
      cc: 'Carol <carol@example.com>',
      bcc: 'dave@example.com',
      subject: '',
      textBody: 'Hello',
      attachments: const [
        OutgoingAttachment(
          filename: 'plan.pdf',
          contentType: 'application/pdf',
          bytes: [1, 2, 3],
        ),
      ],
    );

    expect(transport.sentCredential?.accountId, 'work');
    expect(transport.sentMessage?.from, 'me@example.com');
    expect(transport.sentMessage?.to, ['alice@example.com', 'bob@example.com']);
    expect(transport.sentMessage?.cc, ['carol@example.com']);
    expect(transport.sentMessage?.bcc, ['dave@example.com']);
    expect(transport.sentMessage?.subject, '(no subject)');
    expect(transport.sentMessage?.textBody, 'Hello');
    expect(transport.sentMessage?.attachments, hasLength(1));
    expect(transport.sentMessage?.attachments.single.filename, 'plan.pdf');
    final sent = await cache.loadMessages(mailbox: MailboxKind.sent);
    expect(sent, hasLength(1));
    expect(
      sent.single.from,
      'To: alice@example.com, bob@example.com  Cc: carol@example.com',
    );
    expect(sent.single.subject, '(no subject)');
    expect(sent.single.body, 'Hello');
    expect(sent.single.read, isTrue);
    expect(sent.single.hasAttachments, isTrue);
    expect(sent.single.attachments.single.filename, 'plan.pdf');
    expect(sent.single.attachments.single.contentType, 'application/pdf');
    expect(sent.single.attachments.single.size, 3);
  });

  test('sendReplyAll excludes self and uses reply-to recipients', () async {
    final transport = _RecordingTransport();
    final cache = _MemoryMailCache();
    final repository = CachedTransportMailRepository(
      cache: cache,
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final original = MailMessage(
      id: 'work:inbox:reply-all',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      to: const ['me@example.com', 'team@example.com'],
      cc: const ['manager@example.com', 'team@example.com'],
      replyTo: const ['reply@example.com'],
      subject: 'Planning',
      preview: 'Planning',
      body: 'Planning',
      receivedAt: DateTime.utc(2026, 7),
    );

    await repository.sendReplyAll(
      original: original,
      textBody: 'I can make it',
      htmlBody: '<div>I can <b>make</b> it</div>',
    );

    expect(transport.sentCredential?.accountId, 'work');
    expect(transport.sentMessage?.to, [
      'reply@example.com',
      'team@example.com',
    ]);
    expect(transport.sentMessage?.cc, ['manager@example.com']);
    expect(transport.sentMessage?.bcc, isEmpty);
    expect(transport.sentMessage?.subject, 'Re: Planning');
    expect(transport.sentMessage?.htmlBody, '<div>I can <b>make</b> it</div>');
    final sent = await cache.loadMessages(mailbox: MailboxKind.sent);
    expect(sent, hasLength(1));
    expect(
      sent.single.from,
      'To: reply@example.com, team@example.com  Cc: manager@example.com',
    );
    expect(sent.single.htmlBody, '<div>I can <b>make</b> it</div>');
  });

  test(
    'message flag actions call transport with selected credential',
    () async {
      final transport = _RecordingTransport();
      final repository = CachedTransportMailRepository(
        cache: _MemoryMailCache(),
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );
      final message = MailMessage(
        id: 'work:42',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        subject: 'Hello',
        preview: 'Hello',
        body: 'Hello',
        receivedAt: DateTime.utc(2026, 7),
      );

      final read = await repository.setRead(message: message, read: true);
      final starred = await repository.setStarred(message: read, starred: true);

      expect(read.read, isTrue);
      expect(starred.starred, isTrue);
      expect(transport.seenMessageId, 'work:42');
      expect(transport.seen, isTrue);
      expect(transport.flaggedMessageId, 'work:42');
      expect(transport.flagged, isTrue);
    },
  );

  test('messages refreshes and filters the selected mailbox', () async {
    final transport =
        _RecordingTransport()
          ..messagesByMailbox[MailboxKind.archive] = [
            MailMessage(
              id: 'work:archive:7',
              accountId: 'work',
              from: 'Alice <alice@example.com>',
              subject: 'Archived',
              preview: 'Done',
              body: 'Done',
              mailbox: MailboxKind.archive,
              receivedAt: DateTime.utc(2026, 7, 1),
            ),
          ]
          ..messagesByMailbox[MailboxKind.inbox] = [
            MailMessage(
              id: 'work:inbox:8',
              accountId: 'work',
              from: 'Bob <bob@example.com>',
              subject: 'Inbox',
              preview: 'Now',
              body: 'Now',
              receivedAt: DateTime.utc(2026, 7, 2),
            ),
          ];
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    final archived = await repository.messages(mailbox: MailboxKind.archive);

    expect(transport.fetchedMailbox, MailboxKind.archive);
    expect(archived, hasLength(1));
    expect(archived.single.id, 'work:archive:7');
    expect(archived.single.mailbox, MailboxKind.archive);
  });

  test(
    'cachedMessagePage returns local mail without touching transport',
    () async {
      final transport = _RecordingTransport();
      final cache = _MemoryMailCache();
      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:42',
          accountId: 'work',
          from: 'Cached <cached@example.com>',
          subject: 'Cached',
          preview: 'Local first',
          body: 'Local first',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
      ]);
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final page = await repository.cachedMessagePage(
        mailbox: MailboxKind.inbox,
        limit: 30,
      );

      expect(page.messages.map((message) => message.id), ['work:inbox:42']);
      expect(page.hasMore, isFalse);
      expect(transport.fetchedCredentialIds, isEmpty);
    },
  );

  test(
    'all incoming view aggregates inbox and custom account folders',
    () async {
      final workInbox = MailFolder(
        accountId: 'work',
        path: 'INBOX',
        displayName: 'Inbox',
        kind: MailboxKind.inbox,
      );
      final workProjects = MailFolder(
        accountId: 'work',
        path: 'Projects',
        displayName: 'Projects',
        kind: MailboxKind.custom,
      );
      final workSent = MailFolder(
        accountId: 'work',
        path: 'Sent',
        displayName: 'Sent',
        kind: MailboxKind.sent,
      );
      final workDrafts = MailFolder(
        accountId: 'work',
        path: 'Drafts',
        displayName: 'Drafts',
        kind: MailboxKind.drafts,
      );
      final workArchive = MailFolder(
        accountId: 'work',
        path: 'Archive',
        displayName: 'Archive',
        kind: MailboxKind.archive,
      );
      final workSpam = MailFolder(
        accountId: 'work',
        path: 'Junk',
        displayName: 'Junk',
        kind: MailboxKind.spam,
      );
      final workTrash = MailFolder(
        accountId: 'work',
        path: 'Deleted Items',
        displayName: 'Deleted Items',
        kind: MailboxKind.trash,
      );
      final personalReceipts = MailFolder(
        accountId: 'personal',
        path: 'Receipts',
        displayName: 'Receipts',
        kind: MailboxKind.custom,
      );
      final transport =
          _RecordingTransport()
            ..foldersByCredential['work'] = [
              workInbox,
              workProjects,
              workSent,
              workDrafts,
              workArchive,
              workSpam,
              workTrash,
            ]
            ..foldersByCredential['personal'] = [personalReceipts]
            ..messagesByFolder[workInbox.key] = [
              MailMessage(
                id: 'work:inbox:10',
                accountId: 'work',
                from: 'Lead <lead@example.com>',
                subject: 'Inbox mail',
                preview: 'Inbox',
                body: 'Inbox',
                receivedAt: DateTime.utc(2026, 7, 3),
              ),
            ]
            ..messagesByFolder[workProjects.key] = [
              MailMessage(
                id: 'work:folder:Projects:9',
                accountId: 'work',
                from: 'Project <project@example.com>',
                subject: 'Rule-routed project mail',
                preview: 'Project',
                body: 'Project',
                receivedAt: DateTime.utc(2026, 7, 2),
              ),
            ]
            ..messagesByFolder[workSent.key] = [
              MailMessage(
                id: 'work:sent:8',
                accountId: 'work',
                from: 'Me <me@example.com>',
                subject: 'Sent mail',
                preview: 'Sent',
                body: 'Sent',
                receivedAt: DateTime.utc(2026, 7, 4),
                mailbox: MailboxKind.sent,
              ),
            ]
            ..messagesByFolder[workDrafts.key] = [
              MailMessage(
                id: 'work:drafts:6',
                accountId: 'work',
                from: 'Me <me@example.com>',
                subject: 'Draft mail',
                preview: 'Draft',
                body: 'Draft',
                receivedAt: DateTime.utc(2026, 7, 4),
                mailbox: MailboxKind.drafts,
              ),
            ]
            ..messagesByFolder[workArchive.key] = [
              MailMessage(
                id: 'work:archive:5',
                accountId: 'work',
                from: 'Archive <archive@example.com>',
                subject: 'Archive mail',
                preview: 'Archive',
                body: 'Archive',
                receivedAt: DateTime.utc(2026, 7, 4),
                mailbox: MailboxKind.archive,
              ),
            ]
            ..messagesByFolder[workSpam.key] = [
              MailMessage(
                id: 'work:spam:4',
                accountId: 'work',
                from: 'Spam <spam@example.com>',
                subject: 'Spam mail',
                preview: 'Spam',
                body: 'Spam',
                receivedAt: DateTime.utc(2026, 7, 4),
                mailbox: MailboxKind.spam,
              ),
            ]
            ..messagesByFolder[workTrash.key] = [
              MailMessage(
                id: 'work:trash:3',
                accountId: 'work',
                from: 'Trash <trash@example.com>',
                subject: 'Trash mail',
                preview: 'Trash',
                body: 'Trash',
                receivedAt: DateTime.utc(2026, 7, 4),
                mailbox: MailboxKind.trash,
              ),
            ]
            ..messagesByFolder[personalReceipts.key] = [
              MailMessage(
                id: 'personal:folder:Receipts:7',
                accountId: 'personal',
                from: 'Shop <shop@example.com>',
                subject: 'Receipt',
                preview: 'Receipt',
                body: 'Receipt',
                receivedAt: DateTime.utc(2026, 7, 1),
              ),
            ];
      final repository = CachedTransportMailRepository(
        cache: _MemoryMailCache(),
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
          MailboxCredential(
            accountId: 'personal',
            address: 'me@personal.example',
            displayName: 'Personal',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@personal.example',
            secret: 'secret',
          ),
        ],
      );

      final page = await repository.viewPage(
        view: const MailboxView.smart(MailSmartFolder.allIncoming),
        limit: 10,
      );

      expect(page.messages.map((message) => message.subject), [
        'Inbox mail',
        'Rule-routed project mail',
        'Receipt',
      ]);
      expect(
        page.messages.map((message) => message.folderDisplayName).toSet(),
        {'Inbox', 'Projects', 'Receipts'},
      );
    },
  );

  test(
    'smart views reclassify and dedupe stale cached system folder messages',
    () async {
      final cache = _MemoryMailCache();
      await cache.saveMessages([
        MailMessage(
          id: 'work:folder:trash:12',
          accountId: 'work',
          from: 'Old <old@example.com>',
          subject: 'Deleted stale custom copy',
          preview: 'Deleted',
          body: 'Deleted',
          receivedAt: DateTime.utc(2026, 7, 4),
          mailbox: MailboxKind.custom,
          folderPath: '[Gmail]/&XfJSIJZkkK5O9g-',
          folderDisplayName: '已删除邮件',
        ),
        MailMessage(
          id: 'work:trash:12',
          accountId: 'work',
          from: 'Old <old@example.com>',
          subject: 'Deleted canonical copy',
          preview: 'Deleted',
          body: 'Deleted',
          receivedAt: DateTime.utc(2026, 7, 4),
          mailbox: MailboxKind.trash,
          folderPath: '[Gmail]/&XfJSIJZkkK5O9g-',
          folderDisplayName: '已删除邮件',
        ),
        MailMessage(
          id: 'work:folder:Projects:11',
          accountId: 'work',
          from: 'Project <project@example.com>',
          subject: 'Project mail',
          preview: 'Project',
          body: 'Project',
          receivedAt: DateTime.utc(2026, 7, 3),
          mailbox: MailboxKind.custom,
          folderPath: 'Projects',
          folderDisplayName: 'Projects',
        ),
      ]);
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: _RecordingTransport(),
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final incoming = await repository.cachedViewPage(
        view: const MailboxView.smart(MailSmartFolder.allIncoming),
        limit: 10,
      );
      final trash = await repository.cachedViewPage(
        view: const MailboxView.smart(MailSmartFolder.trash),
        limit: 10,
      );

      expect(incoming.messages.map((message) => message.subject), [
        'Project mail',
      ]);
      expect(trash.messages.map((message) => message.subject), [
        'Deleted canonical copy',
      ]);
    },
  );

  test('account folder view fetches only the selected real folder', () async {
    final projects = MailFolder(
      accountId: 'work',
      path: 'Projects',
      displayName: 'Projects',
      kind: MailboxKind.custom,
    );
    final receipts = MailFolder(
      accountId: 'work',
      path: 'Receipts',
      displayName: 'Receipts',
      kind: MailboxKind.custom,
    );
    final transport =
        _RecordingTransport()
          ..foldersByCredential['work'] = [projects, receipts]
          ..messagesByFolder[projects.key] = [
            MailMessage(
              id: 'work:folder:Projects:20',
              accountId: 'work',
              from: 'Project <project@example.com>',
              subject: 'Project update',
              preview: 'Project',
              body: 'Project',
              receivedAt: DateTime.utc(2026, 7, 3),
            ),
          ]
          ..messagesByFolder[receipts.key] = [
            MailMessage(
              id: 'work:folder:Receipts:19',
              accountId: 'work',
              from: 'Shop <shop@example.com>',
              subject: 'Receipt',
              preview: 'Receipt',
              body: 'Receipt',
              receivedAt: DateTime.utc(2026, 7, 2),
            ),
          ];
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    final page = await repository.viewPage(
      view: MailboxView.folder(projects),
      limit: 10,
    );

    expect(transport.fetchedCredentialIds, ['work']);
    expect(page.messages.map((message) => message.subject), ['Project update']);
    expect(page.messages.single.folderPath, 'Projects');
  });

  test(
    'messages passes requested limit to transport and result window',
    () async {
      final transport =
          _RecordingTransport()
            ..messagesByMailbox[MailboxKind.inbox] = [
              for (var index = 0; index < 40; index++)
                MailMessage(
                  id: 'work:inbox:$index',
                  accountId: 'work',
                  from: 'Sender <sender@example.com>',
                  subject: 'Message $index',
                  preview: 'Preview $index',
                  body: 'Body $index',
                  receivedAt: DateTime.utc(
                    2026,
                    7,
                    1,
                  ).add(Duration(minutes: index)),
                ),
            ];
      final repository = CachedTransportMailRepository(
        cache: _MemoryMailCache(),
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final messages = await repository.messages(
        mailbox: MailboxKind.inbox,
        limit: 12,
      );

      expect(transport.fetchedLimit, 12);
      expect(transport.fetchedBeforeUids, [null]);
      expect(messages, hasLength(12));
      expect(messages.first.id, 'work:inbox:39');
      expect(messages.last.id, 'work:inbox:28');
      expect(messages.first.bodyLoaded, isFalse);
      expect(messages.first.body, isEmpty);
    },
  );

  test('loadOlderMessages uses the oldest cached UID as cursor', () async {
    final transport =
        _RecordingTransport()
          ..messagesByMailbox[MailboxKind.inbox] = [
            for (var uid = 1; uid <= 75; uid++)
              MailMessage(
                id: 'work:inbox:$uid',
                accountId: 'work',
                from: 'Sender <sender@example.com>',
                subject: 'Message $uid',
                preview: 'Preview $uid',
                body: 'Body $uid',
                receivedAt: DateTime.utc(
                  2026,
                  7,
                  1,
                ).add(Duration(minutes: uid)),
              ),
          ];
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    final first = await repository.messagePage(
      mailbox: MailboxKind.inbox,
      limit: 30,
    );
    final second = await repository.loadOlderMessages(
      mailbox: MailboxKind.inbox,
      visibleCount: first.messages.length,
      limit: 30,
    );

    expect(transport.fetchedBeforeUids, [null, 46]);
    expect(second.messages, hasLength(60));
    expect(second.messages.first.id, 'work:inbox:75');
    expect(second.messages.last.id, 'work:inbox:16');
    expect(second.messages.map((message) => message.id).toSet(), hasLength(60));
    expect(second.hasMore, isTrue);
  });

  test(
    'loadMessageBody fetches full MIME only when a message is opened',
    () async {
      final transport =
          _RecordingTransport()
            ..messagesByMailbox[MailboxKind.inbox] = [
              MailMessage(
                id: 'work:inbox:42',
                accountId: 'work',
                from: 'Alice <alice@example.com>',
                subject: 'Report',
                preview: 'See attached',
                body: 'Preview body',
                receivedAt: DateTime.utc(2026, 7, 2),
              ),
            ]
            ..bodyById['work:inbox:42'] = MailMessage(
              id: 'work:inbox:42',
              accountId: 'work',
              from: 'Alice <alice@example.com>',
              subject: 'Report',
              preview: 'See attached',
              body: 'Full report body',
              receivedAt: DateTime.utc(2026, 7, 2),
              hasAttachments: true,
              attachments: const [
                MailAttachment(
                  filename: 'report.pdf',
                  contentType: 'application/pdf',
                  partId: '2',
                ),
              ],
            );
      final cache = _MemoryMailCache();
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final page = await repository.messagePage(
        mailbox: MailboxKind.inbox,
        limit: 1,
      );
      final preview = page.messages.single;
      final loaded = await repository.loadMessageBody(preview);
      final cached = await cache.loadMessages(mailbox: MailboxKind.inbox);

      expect(preview.bodyLoaded, isFalse);
      expect(preview.body, isEmpty);
      expect(transport.bodyMessageId, 'work:inbox:42');
      expect(loaded.bodyLoaded, isTrue);
      expect(loaded.body, 'Full report body');
      expect(loaded.hasAttachments, isTrue);
      expect(cached.single.bodyLoaded, isTrue);
      expect(cached.single.body, 'Full report body');
    },
  );

  test(
    'messages refreshes only the selected account when accountId is set',
    () async {
      final transport =
          _RecordingTransport()
            ..messagesByCredential['work'] = [
              MailMessage(
                id: 'work:inbox:1',
                accountId: 'work',
                from: 'Work <work@example.com>',
                subject: 'Work mail',
                preview: 'Work',
                body: 'Work',
                receivedAt: DateTime.utc(2026, 7, 1),
              ),
            ]
            ..messagesByCredential['personal'] = [
              MailMessage(
                id: 'personal:inbox:1',
                accountId: 'personal',
                from: 'Friend <friend@example.com>',
                subject: 'Personal mail',
                preview: 'Personal',
                body: 'Personal',
                receivedAt: DateTime.utc(2026, 7, 2),
              ),
            ];
      final repository = CachedTransportMailRepository(
        cache: _MemoryMailCache(),
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'work@example.com',
            displayName: 'Work',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'work@example.com',
            secret: 'secret',
          ),
          MailboxCredential(
            accountId: 'personal',
            address: 'me@example.com',
            displayName: 'Personal',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final messages = await repository.messages(
        mailbox: MailboxKind.inbox,
        accountId: 'personal',
      );

      expect(transport.fetchedCredentialIds, ['personal']);
      expect(messages, hasLength(1));
      expect(messages.single.accountId, 'personal');
    },
  );

  test('messages searches body and recipient metadata', () async {
    final cache = _MemoryMailCache();
    await cache.saveMessages([
      MailMessage(
        id: 'work:inbox:body',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        to: const ['team@example.com'],
        cc: const ['manager@example.com'],
        subject: 'Planning',
        preview: 'Preview',
        body: 'The launch code is nebula.',
        receivedAt: DateTime.utc(2026, 7, 1),
      ),
      MailMessage(
        id: 'work:inbox:other',
        accountId: 'work',
        from: 'Bob <bob@example.com>',
        subject: 'Unrelated',
        preview: 'Other',
        body: 'Other',
        receivedAt: DateTime.utc(2026, 7, 2),
      ),
    ]);
    final repository = CachedTransportMailRepository(
      cache: cache,
      transport: _RecordingTransport(),
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    final bodyMatches = await repository.messages(
      mailbox: MailboxKind.inbox,
      query: 'nebula',
    );
    final recipientMatches = await repository.messages(
      mailbox: MailboxKind.inbox,
      query: 'manager@example.com',
    );

    expect(bodyMatches.map((message) => message.id), ['work:inbox:body']);
    expect(recipientMatches.map((message) => message.id), ['work:inbox:body']);
  });

  test('messages refreshes all accounts when accountId is omitted', () async {
    final transport =
        _RecordingTransport()
          ..messagesByCredential['work'] = [
            MailMessage(
              id: 'work:inbox:1',
              accountId: 'work',
              from: 'Work <work@example.com>',
              subject: 'Work mail',
              preview: 'Work',
              body: 'Work',
              receivedAt: DateTime.utc(2026, 7, 1),
            ),
          ]
          ..messagesByCredential['personal'] = [
            MailMessage(
              id: 'personal:inbox:1',
              accountId: 'personal',
              from: 'Friend <friend@example.com>',
              subject: 'Personal mail',
              preview: 'Personal',
              body: 'Personal',
              receivedAt: DateTime.utc(2026, 7, 2),
            ),
          ];
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'work@example.com',
          displayName: 'Work',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'work@example.com',
          secret: 'secret',
        ),
        MailboxCredential(
          accountId: 'personal',
          address: 'me@example.com',
          displayName: 'Personal',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );

    final messages = await repository.messages(mailbox: MailboxKind.inbox);

    expect(transport.fetchedCredentialIds, ['work', 'personal']);
    expect(messages.map((message) => message.accountId), ['personal', 'work']);
  });

  test(
    'messages hides cached mail for accounts no longer in the vault',
    () async {
      final cache = _MemoryMailCache();
      await cache.saveMessages([
        MailMessage(
          id: 'removed:inbox:1',
          accountId: 'removed',
          from: 'Old <old@example.com>',
          subject: 'Removed account',
          preview: 'This account is no longer configured.',
          body: 'This account is no longer configured.',
          receivedAt: DateTime.utc(2026, 7, 1),
        ),
        MailMessage(
          id: 'work:inbox:1',
          accountId: 'work',
          from: 'Work <work@example.com>',
          subject: 'Active account',
          preview: 'Still configured.',
          body: 'Still configured.',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
      ]);
      final transport =
          _RecordingTransport()
            ..messagesByMailbox[MailboxKind.inbox] = [
              MailMessage(
                id: 'work:inbox:1',
                accountId: 'work',
                from: 'Work <work@example.com>',
                subject: 'Active account',
                preview: 'Still configured.',
                body: 'Still configured.',
                receivedAt: DateTime.utc(2026, 7, 2),
              ),
            ];
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'work@example.com',
            displayName: 'Work',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'work@example.com',
            secret: 'secret',
          ),
        ],
      );

      final allAccounts = await repository.messages(mailbox: MailboxKind.inbox);
      final removedAccount = await repository.messages(
        mailbox: MailboxKind.inbox,
        accountId: 'removed',
      );

      expect(allAccounts.map((message) => message.accountId), ['work']);
      expect(removedAccount, isEmpty);
    },
  );

  test(
    'messagePage removes cached mail missing from fetched UID window',
    () async {
      final transport =
          _RecordingTransport()
            ..messagesByMailbox[MailboxKind.inbox] = [
              MailMessage(
                id: 'work:inbox:42',
                accountId: 'work',
                from: 'Sender <sender@example.com>',
                subject: 'Still remote',
                preview: 'Still remote',
                body: 'Still remote',
                receivedAt: DateTime.utc(2026, 7, 2),
              ),
            ];
      final cache = _MemoryMailCache();
      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:42',
          accountId: 'work',
          from: 'Sender <sender@example.com>',
          subject: 'Still remote old flags',
          preview: 'Still remote',
          body: 'Still remote',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
        MailMessage(
          id: 'work:inbox:41',
          accountId: 'work',
          from: 'Deleted <deleted@example.com>',
          subject: 'Deleted remotely',
          preview: 'Gone',
          body: 'Gone',
          receivedAt: DateTime.utc(2026, 7, 1),
        ),
      ]);
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );

      final page = await repository.messagePage(
        mailbox: MailboxKind.inbox,
        limit: 30,
      );
      final cached = await cache.loadMessages(mailbox: MailboxKind.inbox);

      expect(page.messages.map((message) => message.id), ['work:inbox:42']);
      expect(cached.map((message) => message.id), ['work:inbox:42']);
    },
  );

  test('archive moves cached message into archive mailbox', () async {
    final transport = _RecordingTransport();
    final cache = _MemoryMailCache();
    final repository = CachedTransportMailRepository(
      cache: cache,
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final message = MailMessage(
      id: 'work:inbox:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Hello',
      preview: 'Hello',
      body: 'Hello',
      receivedAt: DateTime.utc(2026, 7),
    );
    await cache.saveMessages([message]);

    await repository.archive(message);

    expect(transport.movedMessageId, 'work:inbox:42');
    expect(transport.moveDestination, MailboxKind.archive);
    expect(await cache.loadMessages(mailbox: MailboxKind.inbox), isEmpty);
    final archived = await cache.loadMessages(mailbox: MailboxKind.archive);
    expect(archived.single.mailbox, MailboxKind.archive);
  });

  test(
    'moveToMailbox moves cached message into the selected mailbox',
    () async {
      final transport = _RecordingTransport();
      final cache = _MemoryMailCache();
      final repository = CachedTransportMailRepository(
        cache: cache,
        transport: transport,
        credentials: const [
          MailboxCredential(
            accountId: 'work',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
          ),
        ],
      );
      final message = MailMessage(
        id: 'work:inbox:99',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        subject: 'Check this',
        preview: 'Check this',
        body: 'Check this',
        receivedAt: DateTime.utc(2026, 7),
      );
      await cache.saveMessages([message]);

      await repository.moveToMailbox(
        message: message,
        destination: MailboxKind.spam,
      );

      expect(transport.movedMessageId, 'work:inbox:99');
      expect(transport.moveDestination, MailboxKind.spam);
      expect(await cache.loadMessages(mailbox: MailboxKind.inbox), isEmpty);
      final spam = await cache.loadMessages(mailbox: MailboxKind.spam);
      expect(spam.single.mailbox, MailboxKind.spam);
      expect(spam.single.subject, 'Check this');
    },
  );

  test('moveToInbox moves cached message back into inbox', () async {
    final transport = _RecordingTransport();
    final cache = _MemoryMailCache();
    final repository = CachedTransportMailRepository(
      cache: cache,
      transport: transport,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final message = MailMessage(
      id: 'work:trash:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Recover me',
      preview: 'Recover me',
      body: 'Recover me',
      mailbox: MailboxKind.trash,
      receivedAt: DateTime.utc(2026, 7),
    );
    await cache.saveMessages([message]);

    await repository.moveToInbox(message);

    expect(transport.movedMessageId, 'work:trash:42');
    expect(transport.moveDestination, MailboxKind.inbox);
    expect(await cache.loadMessages(mailbox: MailboxKind.trash), isEmpty);
    final inbox = await cache.loadMessages(mailbox: MailboxKind.inbox);
    expect(inbox.single.mailbox, MailboxKind.inbox);
    expect(inbox.single.subject, 'Recover me');
  });

  test('downloadAttachment stores sanitized attachment bytes', () async {
    final transport =
        _RecordingTransport()
          ..downloadedAttachment = const DownloadedAttachment(
            filename: 'report:Q3?.pdf',
            contentType: 'application/pdf',
            bytes: [0, 1, 2, 3],
          );
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      supportDirectoryProvider: () async => tempDir,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final message = MailMessage(
      id: 'work:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Report',
      preview: 'See attached',
      body: 'See attached',
      receivedAt: DateTime.utc(2026, 7),
    );
    const attachment = MailAttachment(
      filename: 'ignored.pdf',
      contentType: 'application/pdf',
      partId: '2',
      transferEncoding: 'base64',
    );

    final file = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );

    expect(transport.attachmentMessageId, 'work:42');
    expect(transport.attachmentPartId, '2');
    expect(file.path, contains('report_Q3_.pdf'));
    expect(await file.readAsBytes(), [0, 1, 2, 3]);
  });

  test('downloadAttachment scopes cached files by user namespace', () async {
    final transport =
        _RecordingTransport()
          ..downloadedAttachment = const DownloadedAttachment(
            filename: 'report.pdf',
            contentType: 'application/pdf',
            bytes: [0, 1, 2, 3],
          );
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      cacheNamespace: 'user-one',
      supportDirectoryProvider: () async => tempDir,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final message = MailMessage(
      id: 'work:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Report',
      preview: 'See attached',
      body: 'See attached',
      receivedAt: DateTime.utc(2026, 7),
    );
    const attachment = MailAttachment(
      filename: 'report.pdf',
      contentType: 'application/pdf',
      partId: '2',
      transferEncoding: 'base64',
    );

    final file = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );

    expect(
      _normalizedTestPath(file.path),
      contains('/mail-attachments/user-one/work_42/2/report.pdf'),
    );
  });

  test(
    'clearMailAttachmentCache removes only the selected user namespace',
    () async {
      const userNamespace = 'user-aaaaaaaaaaaaaaaaaaaaaaaa';
      const otherNamespace = 'user-bbbbbbbbbbbbbbbbbbbbbbbb';
      final userFile = File(
        '${tempDir.path}/mail-attachments/$userNamespace/work_42/2/report.pdf',
      );
      final otherFile = File(
        '${tempDir.path}/mail-attachments/$otherNamespace/work_42/2/report.pdf',
      );
      await userFile.parent.create(recursive: true);
      await otherFile.parent.create(recursive: true);
      await userFile.writeAsBytes([1], flush: true);
      await otherFile.writeAsBytes([2], flush: true);

      await clearMailAttachmentCache(
        cacheNamespace: userNamespace,
        supportDirectoryProvider: () async => tempDir,
      );

      expect(await userFile.exists(), isFalse);
      expect(await otherFile.exists(), isTrue);
    },
  );

  test(
    'clearLegacyMailAttachmentCache removes pre-namespace attachment cache',
    () async {
      final legacyFile = File(
        '${tempDir.path}/mail-attachments/work_42/2/report.pdf',
      );
      final namespacedFile = File(
        '${tempDir.path}/mail-attachments/user-aaaaaaaaaaaaaaaaaaaaaaaa/work_42/2/report.pdf',
      );
      await legacyFile.parent.create(recursive: true);
      await namespacedFile.parent.create(recursive: true);
      await legacyFile.writeAsBytes([1], flush: true);
      await namespacedFile.writeAsBytes([2], flush: true);

      await clearLegacyMailAttachmentCache(
        supportDirectoryProvider: () async => tempDir,
      );

      expect(await legacyFile.exists(), isFalse);
      expect(await namespacedFile.exists(), isTrue);
    },
  );

  test('downloadAttachment reuses a complete cached attachment', () async {
    final transport =
        _RecordingTransport()
          ..downloadedAttachment = const DownloadedAttachment(
            filename: 'report.pdf',
            contentType: 'application/pdf',
            bytes: [9, 9, 9, 9],
          );
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      supportDirectoryProvider: () async => tempDir,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final cached = File(
      '${tempDir.path}/mail-attachments/work_42/2/report.pdf',
    );
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes([0, 1, 2, 3], flush: true);
    final message = MailMessage(
      id: 'work:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Report',
      preview: 'See attached',
      body: 'See attached',
      receivedAt: DateTime.utc(2026, 7),
    );
    const attachment = MailAttachment(
      filename: 'report.pdf',
      contentType: 'application/pdf',
      partId: '2',
      transferEncoding: 'base64',
      size: 4,
    );

    final first = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );
    final second = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );

    expect(_normalizedTestPath(first.path), _normalizedTestPath(cached.path));
    expect(_normalizedTestPath(second.path), _normalizedTestPath(cached.path));
    expect(await second.readAsBytes(), [0, 1, 2, 3]);
    expect(transport.attachmentDownloadCount, 0);
  });

  test('downloadAttachment encrypts persistent attachment cache', () async {
    final transport =
        _RecordingTransport()
          ..downloadedAttachment = const DownloadedAttachment(
            filename: 'report.pdf',
            contentType: 'application/pdf',
            bytes: [0, 1, 2, 3],
          );
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      localCacheSecret: _testSecret(),
      supportDirectoryProvider: () async => tempDir,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final message = MailMessage(
      id: 'work:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Report',
      preview: 'See attached',
      body: 'See attached',
      receivedAt: DateTime.utc(2026, 7),
    );
    const attachment = MailAttachment(
      filename: 'report.pdf',
      contentType: 'application/pdf',
      partId: '2',
      transferEncoding: 'base64',
      size: 4,
    );

    final first = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );
    final second = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );
    final persistent = File(
      '${tempDir.path}/mail-attachments/work_42/2/report.pdf.nyacache',
    );
    final rawPersistent = await persistent.readAsString(encoding: utf8);

    expect(await first.readAsBytes(), [0, 1, 2, 3]);
    expect(await second.readAsBytes(), [0, 1, 2, 3]);
    expect(
      _normalizedTestPath(second.path),
      contains('/.nyamail-open/report.pdf'),
    );
    expect(await persistent.readAsBytes(), isNot(equals([0, 1, 2, 3])));
    expect(rawPersistent, contains('nyamail-local-cache-aes256gcm-v1'));
    expect(transport.attachmentDownloadCount, 1);
  });

  test('downloadAttachment replaces incomplete cache atomically', () async {
    final transport =
        _RecordingTransport()
          ..downloadedAttachment = const DownloadedAttachment(
            filename: 'report.pdf',
            contentType: 'application/pdf',
            bytes: [0, 1, 2, 3],
          );
    final repository = CachedTransportMailRepository(
      cache: _MemoryMailCache(),
      transport: transport,
      supportDirectoryProvider: () async => tempDir,
      credentials: const [
        MailboxCredential(
          accountId: 'work',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: 'imap.example.com',
          imapPort: 993,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
        ),
      ],
    );
    final attachmentDir = Directory(
      '${tempDir.path}/mail-attachments/work_42/2',
    );
    await attachmentDir.create(recursive: true);
    await File('${attachmentDir.path}/report.pdf').writeAsBytes([9, 9]);
    await File(
      '${attachmentDir.path}/.nyamail-download-leftover.download',
    ).writeAsBytes([8, 8]);
    final message = MailMessage(
      id: 'work:42',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Report',
      preview: 'See attached',
      body: 'See attached',
      receivedAt: DateTime.utc(2026, 7),
    );
    const attachment = MailAttachment(
      filename: 'report.pdf',
      contentType: 'application/pdf',
      partId: '2',
      transferEncoding: 'base64',
      size: 4,
    );

    final file = await repository.downloadAttachment(
      message: message,
      attachment: attachment,
    );
    final leftovers =
        await attachmentDir
            .list()
            .where((entity) => entity.path.endsWith('.download'))
            .toList();

    expect(transport.attachmentDownloadCount, 1);
    expect(file.path, '${attachmentDir.path}/report.pdf');
    expect(await file.readAsBytes(), [0, 1, 2, 3]);
    expect(leftovers, isEmpty);
  });
}

String _testSecret() =>
    base64UrlEncode(List<int>.generate(32, (index) => index));

String _normalizedTestPath(String path) => path.replaceAll('\\', '/');

class _MemoryMailCache implements MailMessageCache {
  final _messages = <String, MailMessage>{};

  @override
  Future<void> saveMessages(List<MailMessage> messages) async {
    for (final message in messages) {
      _messages[message.id] = message;
    }
  }

  @override
  Future<List<MailMessage>> loadMessages({
    MailboxKind? mailbox,
    String? accountId,
    String? folderPath,
    String? query,
  }) async {
    final values =
        _messages.values
            .where((message) => mailbox == null || message.mailbox == mailbox)
            .where(
              (message) => accountId == null || message.accountId == accountId,
            )
            .where(
              (message) =>
                  folderPath == null ||
                  message.effectiveFolderPath == folderPath,
            )
            .toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    if (query == null || query.trim().isEmpty) return values;
    return values
        .where((message) => mailMessageMatchesQuery(message, query))
        .toList();
  }

  @override
  Future<void> updateMessage(MailMessage message) async {
    _messages[message.id] = message;
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    _messages.remove(messageId);
  }
}

class _RecordingTransport implements MailTransport {
  MailboxCredential? sentCredential;
  OutgoingMessage? sentMessage;
  String? seenMessageId;
  bool? seen;
  String? flaggedMessageId;
  bool? flagged;
  String? movedMessageId;
  MailboxKind? moveDestination;
  String? attachmentMessageId;
  String? attachmentPartId;
  int attachmentDownloadCount = 0;
  DownloadedAttachment? downloadedAttachment;
  MailboxKind? fetchedMailbox;
  int? fetchedLimit;
  int? fetchedBeforeUid;
  String? bodyMessageId;
  final messagesByMailbox = <MailboxKind, List<MailMessage>>{};
  final messagesByCredential = <String, List<MailMessage>>{};
  final foldersByCredential = <String, List<MailFolder>>{};
  final messagesByFolder = <String, List<MailMessage>>{};
  final bodyById = <String, MailMessage>{};
  final fetchedCredentialIds = <String>[];
  final fetchedBeforeUids = <int?>[];

  @override
  Future<void> validateCredential({
    required MailboxCredential credential,
  }) async {}

  @override
  Future<List<MailFolder>> listFolders({
    required MailboxCredential credential,
  }) async {
    return foldersByCredential[credential.accountId] ??
        [
          MailFolder(
            accountId: credential.accountId,
            path: 'INBOX',
            displayName: 'Inbox',
            kind: MailboxKind.inbox,
          ),
          MailFolder(
            accountId: credential.accountId,
            path: 'Sent',
            displayName: 'Sent',
            kind: MailboxKind.sent,
          ),
        ];
  }

  @override
  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  }) async {
    fetchedCredentialIds.add(credential.accountId);
    fetchedMailbox = mailbox;
    fetchedLimit = limit;
    return _messageWindow(
      credential: credential,
      mailbox: mailbox,
      limit: limit,
    );
  }

  @override
  Future<List<MailMessage>> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  }) async {
    fetchedCredentialIds.add(credential.accountId);
    fetchedMailbox = mailbox;
    fetchedLimit = limit;
    fetchedBeforeUid = beforeUid;
    fetchedBeforeUids.add(beforeUid);
    return [
      for (final message in _messageWindow(
        credential: credential,
        mailbox: mailbox,
        limit: limit,
        beforeUid: beforeUid,
      ))
        message.copyWith(
          body: '',
          hasAttachments: false,
          attachments: const [],
          bodyLoaded: false,
        ),
    ];
  }

  @override
  Future<List<MailMessage>> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  }) async {
    fetchedCredentialIds.add(credential.accountId);
    fetchedMailbox = folder.kind;
    fetchedLimit = limit;
    fetchedBeforeUid = beforeUid;
    fetchedBeforeUids.add(beforeUid);
    return [
      for (final message in _messageWindowForFolder(
        credential: credential,
        folder: folder,
        limit: limit,
        beforeUid: beforeUid,
      ))
        message.copyWith(
          mailbox: folder.kind,
          folderPath: folder.path,
          folderDisplayName: folder.displayName,
          body: '',
          hasAttachments: false,
          attachments: const [],
          bodyLoaded: false,
        ),
    ];
  }

  @override
  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  }) async {
    bodyMessageId = message.id;
    return bodyById[message.id] ??
        message.copyWith(body: 'Loaded ${message.subject}', bodyLoaded: true);
  }

  @override
  Future<List<MailMessage>> fetchInbox({
    required MailboxCredential credential,
    int limit = 30,
  }) async {
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
    sentCredential = credential;
    sentMessage = message;
  }

  @override
  Future<void> setSeen({
    required MailboxCredential credential,
    required String messageId,
    required bool seen,
  }) async {
    seenMessageId = messageId;
    this.seen = seen;
  }

  @override
  Future<void> setFlagged({
    required MailboxCredential credential,
    required String messageId,
    required bool flagged,
  }) async {
    flaggedMessageId = messageId;
    this.flagged = flagged;
  }

  @override
  Future<void> moveMessage({
    required MailboxCredential credential,
    required String messageId,
    required MailboxKind destination,
  }) async {
    movedMessageId = messageId;
    moveDestination = destination;
  }

  @override
  Future<DownloadedAttachment> downloadAttachment({
    required MailboxCredential credential,
    required String messageId,
    required MailAttachment attachment,
  }) async {
    attachmentDownloadCount += 1;
    attachmentMessageId = messageId;
    attachmentPartId = attachment.partId;
    return downloadedAttachment ??
        DownloadedAttachment(
          filename: attachment.filename,
          contentType: attachment.contentType,
          bytes: const [],
        );
  }

  List<MailMessage> _messageWindow({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    required int limit,
    int? beforeUid,
  }) {
    final credentialMessages = messagesByCredential[credential.accountId];
    final source = credentialMessages ?? messagesByMailbox[mailbox] ?? const [];
    final sorted = [...source]..sort((a, b) {
      final aUid = _uidFor(a);
      final bUid = _uidFor(b);
      if (aUid != null && bUid != null) return bUid.compareTo(aUid);
      return b.receivedAt.compareTo(a.receivedAt);
    });
    return sorted
        .where((message) {
          final uid = _uidFor(message);
          return beforeUid == null || uid == null || uid < beforeUid;
        })
        .take(limit)
        .toList();
  }

  List<MailMessage> _messageWindowForFolder({
    required MailboxCredential credential,
    required MailFolder folder,
    required int limit,
    int? beforeUid,
  }) {
    final source =
        messagesByFolder[folder.key] ??
        messagesByCredential[credential.accountId] ??
        messagesByMailbox[folder.kind] ??
        const [];
    final sorted = [...source]..sort((a, b) {
      final aUid = _uidFor(a);
      final bUid = _uidFor(b);
      if (aUid != null && bUid != null) return bUid.compareTo(aUid);
      return b.receivedAt.compareTo(a.receivedAt);
    });
    return sorted
        .where((message) {
          final uid = _uidFor(message);
          return beforeUid == null || uid == null || uid < beforeUid;
        })
        .take(limit)
        .toList();
  }

  int? _uidFor(MailMessage message) {
    final raw =
        message.id.contains(':') ? message.id.split(':').last : message.id;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }
}
