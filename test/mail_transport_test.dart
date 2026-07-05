import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

void main() {
  test('parseRfc822Message extracts core fields', () {
    final message = parseRfc822Message(
      [
        'From: Alice <alice@example.com>',
        'To: Me <me@example.com>, Team <team@example.com>',
        'Cc: Manager <manager@example.com>',
        'Reply-To: Replies <replies@example.com>',
        'Subject: Hello NyaMail',
        'Date: 2026-07-01T08:00:00Z',
        '',
        'This is the first line.',
        'This is the second line.',
      ].join('\r\n'),
      id: 'acc:1',
      accountId: 'acc',
      mailbox: MailboxKind.archive,
      read: true,
      starred: true,
    );

    expect(message.id, 'acc:1');
    expect(message.accountId, 'acc');
    expect(message.mailbox, MailboxKind.archive);
    expect(message.from, 'Alice <alice@example.com>');
    expect(message.to, ['me@example.com', 'team@example.com']);
    expect(message.cc, ['manager@example.com']);
    expect(message.replyTo, ['replies@example.com']);
    expect(message.subject, 'Hello NyaMail');
    expect(message.preview, contains('first line'));
    expect(message.body, contains('second line'));
    expect(message.read, isTrue);
    expect(message.starred, isTrue);
    expect(message.hasAttachments, isFalse);
  });

  test('parseRfc822Message decodes RFC 2047 encoded headers', () {
    final message = parseRfc822Message(
      [
        'From: =?UTF-8?B?5rWL6K+V?= <alice@example.com>',
        'To: Me <me@example.com>',
        'Subject: =?utf-8?B?5L2g?= =?utf-8?B?5aW9?=',
        '',
        'Body',
      ].join('\r\n'),
      id: 'acc:encoded',
      accountId: 'acc',
    );

    expect(message.from, '测试 <alice@example.com>');
    expect(message.subject, '你好');
  });

  test('parseRfc822Message decodes quoted-printable encoded headers', () {
    final message = parseRfc822Message(
      [
        'From: Alice <alice@example.com>',
        'Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD_NyaMail?=',
        '',
        'Body',
      ].join('\r\n'),
      id: 'acc:encoded-q',
      accountId: 'acc',
    );

    expect(message.subject, '你好 NyaMail');
  });

  test(
    'parseRfc822Message extracts multipart body and attachment metadata',
    () {
      final message = parseRfc822Message(
        [
          'From: Alice <alice@example.com>',
          'Subject: Quarterly report',
          'Date: 2026-07-01T08:00:00Z',
          'Content-Type: multipart/mixed; boundary="mixed-1"',
          '',
          '--mixed-1',
          'Content-Type: multipart/alternative; boundary="alt-1"',
          '',
          '--alt-1',
          'Content-Type: text/plain; charset=utf-8',
          'Content-Transfer-Encoding: quoted-printable',
          '',
          'Plain body with caf=C3=A9.',
          '--alt-1',
          'Content-Type: text/html; charset=utf-8',
          '',
          '<p>HTML body</p>',
          '--alt-1--',
          '--mixed-1',
          'Content-Type: application/pdf; name="report.pdf"',
          'Content-Disposition: attachment; filename="report.pdf"',
          'Content-Transfer-Encoding: base64',
          '',
          'aGVsbG8=',
          '--mixed-1--',
        ].join('\r\n'),
        id: 'acc:2',
        accountId: 'acc',
      );

      expect(message.body, 'Plain body with café.');
      expect(message.htmlBody, '<p>HTML body</p>');
      expect(message.preview, contains('café'));
      expect(message.hasAttachments, isTrue);
      expect(message.attachments, hasLength(1));
      expect(message.attachments.single.filename, 'report.pdf');
      expect(message.attachments.single.contentType, 'application/pdf');
      expect(message.attachments.single.partId, '2');
      expect(message.attachments.single.transferEncoding, 'base64');
      expect(message.attachments.single.size, 5);
    },
  );

  test(
    'parseRfc822Message falls back to html text when plain part is absent',
    () {
      final message = parseRfc822Message(
        [
          'From: Alice <alice@example.com>',
          'Subject: HTML',
          'Content-Type: multipart/alternative; boundary="alt-2"',
          '',
          '--alt-2',
          'Content-Type: text/html; charset=utf-8',
          '',
          '<div>Hello&nbsp;<b>NyaMail</b></div>',
          '--alt-2--',
        ].join('\r\n'),
        id: 'acc:3',
        accountId: 'acc',
      );

      expect(message.body, 'Hello NyaMail');
      expect(message.htmlBody, '<div>Hello&nbsp;<b>NyaMail</b></div>');
      expect(message.hasAttachments, isFalse);
    },
  );

  test('parseRfc822Message keeps text attachments out of the body', () {
    final message = parseRfc822Message(
      [
        'From: Alice <alice@example.com>',
        'Subject: Notes',
        'Content-Type: multipart/mixed; boundary="mixed-text"',
        '',
        '--mixed-text',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'Please see the attachment.',
        '--mixed-text',
        'Content-Type: text/plain; name="notes.txt"',
        'Content-Disposition: attachment; filename="notes.txt"',
        'Content-Transfer-Encoding: base64',
        '',
        'Tm90ZSBib2R5',
        '--mixed-text--',
      ].join('\r\n'),
      id: 'acc:txt',
      accountId: 'acc',
    );

    expect(message.body, 'Please see the attachment.');
    expect(message.hasAttachments, isTrue);
    expect(message.attachments.single.filename, 'notes.txt');
    expect(message.attachments.single.contentType, 'text/plain');
    expect(message.attachments.single.size, 9);
  });

  test('parseRfc822Message decodes truncated base64 preview body', () {
    const text = '您好，欢迎使用 NyaMail。';
    final encoded = base64Encode(utf8.encode(text));
    final message = parseRfc822Message(
      [
        'From: Alice <alice@example.com>',
        'Subject: Encoded preview',
        'Content-Type: multipart/alternative; boundary="alt-preview"',
        '',
        '--alt-preview',
        'Content-Type: text/plain; charset=utf-8',
        'Content-Transfer-Encoding: base64',
        '',
        encoded.substring(0, encoded.length - 2),
      ].join('\r\n'),
      id: 'acc:preview',
      accountId: 'acc',
      bodyLoaded: false,
    );

    expect(message.from, 'Alice <alice@example.com>');
    expect(message.subject, 'Encoded preview');
    expect(message.preview, contains('欢迎使用 NyaMail'));
  });

  test('SocketMailTransport resolves special-use archive mailbox', () async {
    final server = await _FakeImapServer.start();
    try {
      final messages = await const SocketMailTransport().fetchMessages(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: server.port,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
        mailbox: MailboxKind.archive,
      );

      expect(server.selectedMailbox, '[Gmail]/All Mail');
      expect(server.sawUidSearch, isTrue);
      expect(server.sawUidFetch, isTrue);
      expect(messages.single.id, 'acc:archive:501');
      expect(messages.single.mailbox, MailboxKind.archive);
      expect(messages.single.read, isTrue);
      expect(messages.single.starred, isTrue);
    } finally {
      await server.close();
    }
  });

  test('SocketMailTransport lists custom account folders', () async {
    final server = await _FakeImapServer.start();
    try {
      final folders = await const SocketMailTransport().listFolders(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: server.port,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
      );

      expect(server.sawList, isTrue);
      expect(
        folders.map(
          (folder) => '${folder.accountId}:${folder.path}:${folder.kind.name}',
        ),
        contains('acc:Projects:custom'),
      );
      expect(
        folders.map((folder) => '${folder.path}:${folder.kind.name}'),
        contains('INBOX:inbox'),
      );
      final chineseFolder = folders.singleWhere(
        (folder) => folder.path == '&Ti1lhw-',
      );
      expect(chineseFolder.displayName, '中文');
      expect(chineseFolder.effectiveDisplayPath, '中文');
      final kindsByPath = {
        for (final folder in folders) folder.path: folder.kind,
      };
      expect(kindsByPath['[Gmail]/&XfJSIJZkkK5O9g-'], MailboxKind.trash);
      expect(kindsByPath['&g0l6P3ux-'], MailboxKind.drafts);
      expect(kindsByPath['&V4NXPpCuTvY-'], MailboxKind.spam);
    } finally {
      await server.close();
    }
  });

  test(
    'SocketMailTransport fetches highest UIDs when search order varies',
    () async {
      final server = await _FakeImapServer.start(
        searchUids: [501, 499, 503, 502],
      );
      try {
        final messages = await const SocketMailTransport().fetchMessages(
          credential: MailboxCredential(
            accountId: 'acc',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: InternetAddress.loopbackIPv4.address,
            imapPort: server.port,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            username: 'me@example.com',
            secret: 'secret',
            useTls: false,
          ),
          mailbox: MailboxKind.inbox,
          limit: 2,
        );

        expect(server.fetchedUids, [503, 502]);
        expect(messages.map((message) => message.id), [
          'acc:inbox:503',
          'acc:inbox:502',
        ]);
      } finally {
        await server.close();
      }
    },
  );

  test('SocketMailTransport fetches preview UIDs before a cursor', () async {
    final server = await _FakeImapServer.start(
      searchUids: [501, 499, 503, 502],
    );
    try {
      final messages = await const SocketMailTransport().fetchMessagePreviews(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: server.port,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
        mailbox: MailboxKind.inbox,
        limit: 2,
        beforeUid: 503,
      );

      expect(server.fetchedUids, [502, 501]);
      expect(messages.map((message) => message.id), [
        'acc:inbox:502',
        'acc:inbox:501',
      ]);
      expect(messages.first.bodyLoaded, isFalse);
      expect(messages.first.body, isEmpty);
      expect(messages.first.preview, contains('Body 502'));
      expect(server.sawPreviewRangeFetch, isTrue);
    } finally {
      await server.close();
    }
  });

  test('SocketMailTransport decodes base64 message previews', () async {
    const text = '您好，欢迎使用 NyaMail。';
    final encoded = base64Encode(utf8.encode(text));
    final server = await _FakeImapServer.start(
      messagesByUid: {
        501: [
          'From: Alice <alice@example.com>',
          'Subject: Encoded preview',
          'Date: 2026-07-01T08:00:00Z',
          'Content-Type: multipart/alternative; boundary="alt-preview"',
          '',
          '--alt-preview',
          'Content-Type: text/plain; charset=utf-8',
          'Content-Transfer-Encoding: base64',
          '',
          encoded.substring(0, encoded.length - 2),
        ].join('\r\n'),
      },
    );
    try {
      final messages = await const SocketMailTransport().fetchMessagePreviews(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: server.port,
          smtpHost: 'smtp.example.com',
          smtpPort: 465,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
        mailbox: MailboxKind.inbox,
        limit: 1,
      );

      expect(messages.single.from, 'Alice <alice@example.com>');
      expect(messages.single.subject, 'Encoded preview');
      expect(messages.single.preview, contains('欢迎使用 NyaMail'));
      expect(messages.single.bodyLoaded, isFalse);
      expect(server.sawPreviewRangeFetch, isTrue);
    } finally {
      await server.close();
    }
  });

  test(
    'SocketMailTransport appends sent copy to special-use sent folder',
    () async {
      final imap = await _FakeImapServer.start();
      final smtp = await _FakeSmtpServer.start();
      try {
        await const SocketMailTransport().send(
          credential: MailboxCredential(
            accountId: 'acc',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: InternetAddress.loopbackIPv4.address,
            imapPort: imap.port,
            smtpHost: InternetAddress.loopbackIPv4.address,
            smtpPort: smtp.port,
            username: 'me@example.com',
            secret: 'secret',
            useTls: false,
          ),
          message: const OutgoingMessage(
            from: 'me@example.com',
            to: ['alice@example.com'],
            cc: ['carol@example.com'],
            bcc: ['dave@example.com'],
            subject: 'Hello',
            textBody: 'Sent body',
          ),
        );

        expect(smtp.receivedData, contains('Subject: Hello'));
        expect(smtp.receivedData, contains('To: alice@example.com'));
        expect(smtp.receivedData, contains('Cc: carol@example.com'));
        expect(smtp.receivedData, isNot(contains('Bcc:')));
        expect(smtp.recipients, [
          'alice@example.com',
          'carol@example.com',
          'dave@example.com',
        ]);
        expect(imap.appendMailbox, '[Gmail]/Sent Mail');
        expect(imap.appendedMessage, contains('Subject: Hello'));
        expect(imap.appendedMessage, isNot(contains('Bcc:')));
        expect(imap.appendedMessage, contains('Sent body'));
      } finally {
        await smtp.close();
        await imap.close();
      }
    },
  );

  test(
    'SocketMailTransport sends multipart attachment and appends raw copy',
    () async {
      final imap = await _FakeImapServer.start();
      final smtp = await _FakeSmtpServer.start();
      try {
        await const SocketMailTransport().send(
          credential: MailboxCredential(
            accountId: 'acc',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: InternetAddress.loopbackIPv4.address,
            imapPort: imap.port,
            smtpHost: InternetAddress.loopbackIPv4.address,
            smtpPort: smtp.port,
            username: 'me@example.com',
            secret: 'secret',
            useTls: false,
          ),
          message: OutgoingMessage(
            from: 'me@example.com',
            to: const ['alice@example.com'],
            bcc: const ['hidden@example.com'],
            subject: 'Report',
            textBody: 'See attached.',
            date: DateTime.utc(2026, 7, 2, 10, 30),
            attachments: const [
              OutgoingAttachment(
                filename: 'report.pdf',
                contentType: 'application/pdf',
                bytes: [0, 1, 2, 3, 4, 5],
              ),
            ],
          ),
        );

        expect(smtp.receivedData, contains('Subject: Report'));
        expect(smtp.receivedData, contains('Content-Type: multipart/mixed;'));
        expect(
          smtp.receivedData,
          contains('Content-Type: text/plain; charset=utf-8'),
        );
        expect(
          smtp.receivedData,
          contains('Content-Type: application/pdf; name="report.pdf"'),
        );
        expect(
          smtp.receivedData,
          contains('Content-Disposition: attachment; filename="report.pdf"'),
        );
        expect(
          smtp.receivedData,
          contains('Content-Transfer-Encoding: base64'),
        );
        expect(smtp.receivedData, contains('AAECAwQF'));
        expect(smtp.receivedData, isNot(contains('Bcc:')));
        expect(smtp.recipients, ['alice@example.com', 'hidden@example.com']);
        expect(imap.appendedMessage, smtp.receivedData);

        final parsed = parseRfc822Message(
          smtp.receivedData,
          id: 'acc:sent:1',
          accountId: 'acc',
        );
        expect(parsed.body, 'See attached.');
        expect(parsed.hasAttachments, isTrue);
        expect(parsed.attachments.single.filename, 'report.pdf');
        expect(parsed.attachments.single.contentType, 'application/pdf');
        expect(parsed.attachments.single.size, 6);
      } finally {
        await smtp.close();
        await imap.close();
      }
    },
  );

  test('SocketMailTransport sends html alternative body', () async {
    final imap = await _FakeImapServer.start();
    final smtp = await _FakeSmtpServer.start();
    try {
      await const SocketMailTransport().send(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: imap.port,
          smtpHost: InternetAddress.loopbackIPv4.address,
          smtpPort: smtp.port,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
        message: OutgoingMessage(
          from: 'me@example.com',
          to: const ['alice@example.com'],
          subject: 'Rich reply',
          textBody: 'Hello rich mail',
          htmlBody: '<div>Hello <b>rich</b> mail</div>',
          date: DateTime.utc(2026, 7, 2, 10, 30),
        ),
      );

      expect(smtp.receivedData, contains('Subject: Rich reply'));
      expect(
        smtp.receivedData,
        contains('Content-Type: multipart/alternative;'),
      );
      expect(
        smtp.receivedData,
        contains('Content-Type: text/plain; charset=utf-8'),
      );
      expect(
        smtp.receivedData,
        contains('Content-Type: text/html; charset=utf-8'),
      );
      expect(smtp.receivedData, contains('<b>rich</b>'));
      expect(imap.appendedMessage, smtp.receivedData);

      final parsed = parseRfc822Message(
        smtp.receivedData,
        id: 'acc:sent:rich',
        accountId: 'acc',
      );
      expect(parsed.body, 'Hello rich mail');
      expect(parsed.htmlBody, '<div>Hello <b>rich</b> mail</div>');
      expect(parsed.hasAttachments, isFalse);
    } finally {
      await smtp.close();
      await imap.close();
    }
  });

  test(
    'SocketMailTransport nests html alternative before attachments',
    () async {
      final imap = await _FakeImapServer.start();
      final smtp = await _FakeSmtpServer.start();
      try {
        await const SocketMailTransport().send(
          credential: MailboxCredential(
            accountId: 'acc',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: InternetAddress.loopbackIPv4.address,
            imapPort: imap.port,
            smtpHost: InternetAddress.loopbackIPv4.address,
            smtpPort: smtp.port,
            username: 'me@example.com',
            secret: 'secret',
            useTls: false,
          ),
          message: OutgoingMessage(
            from: 'me@example.com',
            to: const ['alice@example.com'],
            subject: 'Rich report',
            textBody: 'See the rich report.',
            htmlBody: '<div>See the <u>rich</u> report.</div>',
            date: DateTime.utc(2026, 7, 2, 10, 31),
            attachments: const [
              OutgoingAttachment(
                filename: 'report.txt',
                contentType: 'text/plain',
                bytes: [82, 101, 112, 111, 114, 116],
              ),
            ],
          ),
        );

        expect(smtp.receivedData, contains('Content-Type: multipart/mixed;'));
        expect(
          smtp.receivedData,
          contains('Content-Type: multipart/alternative;'),
        );
        expect(
          smtp.receivedData,
          contains('Content-Type: text/html; charset=utf-8'),
        );
        expect(
          smtp.receivedData,
          contains('Content-Disposition: attachment; filename="report.txt"'),
        );

        final parsed = parseRfc822Message(
          smtp.receivedData,
          id: 'acc:sent:rich-attachment',
          accountId: 'acc',
        );
        expect(parsed.body, 'See the rich report.');
        expect(parsed.htmlBody, '<div>See the <u>rich</u> report.</div>');
        expect(parsed.hasAttachments, isTrue);
        expect(parsed.attachments.single.filename, 'report.txt');
        expect(parsed.attachments.single.size, 6);
      } finally {
        await smtp.close();
        await imap.close();
      }
    },
  );

  test('SocketMailTransport validates IMAP and SMTP credentials', () async {
    final imap = await _FakeImapServer.start();
    final smtp = await _FakeSmtpServer.start();
    try {
      await const SocketMailTransport().validateCredential(
        credential: MailboxCredential(
          accountId: 'acc',
          address: 'me@example.com',
          displayName: 'Me',
          imapHost: InternetAddress.loopbackIPv4.address,
          imapPort: imap.port,
          smtpHost: InternetAddress.loopbackIPv4.address,
          smtpPort: smtp.port,
          username: 'me@example.com',
          secret: 'secret',
          useTls: false,
        ),
      );

      expect(imap.sawLogin, isTrue);
      expect(imap.sawList, isTrue);
      expect(smtp.sawAuth, isTrue);
      expect(smtp.receivedData, isEmpty);
    } finally {
      await smtp.close();
      await imap.close();
    }
  });

  test(
    'SocketMailTransport validates OAuth2 credentials with XOAUTH2',
    () async {
      final imap = await _FakeImapServer.start();
      final smtp = await _FakeSmtpServer.start();
      try {
        await const SocketMailTransport().validateCredential(
          credential: MailboxCredential(
            accountId: 'acc',
            address: 'me@example.com',
            displayName: 'Me',
            imapHost: InternetAddress.loopbackIPv4.address,
            imapPort: imap.port,
            smtpHost: InternetAddress.loopbackIPv4.address,
            smtpPort: smtp.port,
            username: 'me@example.com',
            secret: 'oauth-token',
            authType: MailboxAuthType.oauth2,
            useTls: false,
          ),
        );

        expect(imap.sawLogin, isFalse);
        expect(imap.sawXoauth2, isTrue);
        expect(imap.oauth2Payload, contains('user=me@example.com'));
        expect(imap.oauth2Payload, contains('auth=Bearer oauth-token'));
        expect(smtp.sawAuth, isFalse);
        expect(smtp.sawXoauth2, isTrue);
        expect(smtp.oauth2Payload, contains('user=me@example.com'));
        expect(smtp.oauth2Payload, contains('auth=Bearer oauth-token'));
      } finally {
        await smtp.close();
        await imap.close();
      }
    },
  );

  test(
    'SocketMailTransport refuses TLS SMTP without STARTTLS capability',
    () async {
      final imap = await _FakeImapServer.start();
      final smtp = await _FakeSmtpServer.start(advertiseStartTls: false);
      try {
        await expectLater(
          const SocketMailTransport().send(
            credential: MailboxCredential(
              accountId: 'acc',
              address: 'me@example.com',
              displayName: 'Me',
              imapHost: InternetAddress.loopbackIPv4.address,
              imapPort: imap.port,
              smtpHost: InternetAddress.loopbackIPv4.address,
              smtpPort: smtp.port,
              username: 'me@example.com',
              secret: 'secret',
              useTls: true,
            ),
            message: const OutgoingMessage(
              from: 'me@example.com',
              to: ['alice@example.com'],
              subject: 'Hello',
              textBody: 'Sent body',
            ),
          ),
          throwsA(
            isA<MailTransportException>().having(
              (error) => error.message,
              'message',
              contains('does not advertise STARTTLS'),
            ),
          ),
        );
        expect(smtp.sawStartTls, isFalse);
        expect(smtp.receivedData, isEmpty);
      } finally {
        await smtp.close();
        await imap.close();
      }
    },
  );
}

class _FakeImapServer {
  _FakeImapServer._(
    this._server, {
    required this.searchUids,
    required this.messagesByUid,
  });

  final ServerSocket _server;
  final List<int> searchUids;
  final Map<int, String> messagesByUid;
  final _commands = <String>[];
  final fetchedUids = <int>[];

  int get port => _server.port;
  String? get selectedMailbox {
    for (final command in _commands) {
      final match = RegExp(r'^A\d+ SELECT "(.+)"$').firstMatch(command);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String? get appendMailbox {
    for (final command in _commands) {
      final match = RegExp(r'^A\d+ APPEND "(.+)"').firstMatch(command);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String appendedMessage = '';

  bool get sawUidSearch {
    return _commands.any((command) => command.contains(' UID SEARCH ALL'));
  }

  bool get sawUidFetch {
    return _commands.any((command) => command.contains(' UID FETCH 501 '));
  }

  bool get sawPreviewRangeFetch {
    return _commands.any((command) => command.contains(' BODY.PEEK[]<0.'));
  }

  bool get sawLogin {
    return _commands.any((command) => command.contains(' LOGIN '));
  }

  bool get sawXoauth2 {
    return _commands.any(
      (command) => command.contains(' AUTHENTICATE XOAUTH2 '),
    );
  }

  String get oauth2Payload {
    final command = _commands.firstWhere(
      (command) => command.contains(' AUTHENTICATE XOAUTH2 '),
      orElse: () => '',
    );
    if (command.isEmpty) return '';
    final encoded = command.split(' AUTHENTICATE XOAUTH2 ').last;
    return utf8.decode(base64Decode(encoded));
  }

  bool get sawList {
    return _commands.any((command) => command.contains(' LIST '));
  }

  static Future<_FakeImapServer> start({
    List<int> searchUids = const [501],
    Map<int, String> messagesByUid = const {},
  }) async {
    final server = _FakeImapServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      searchUids: searchUids,
      messagesByUid: messagesByUid,
    );
    unawaited(server._serve());
    return server;
  }

  Future<void> close() async {
    await _server.close();
  }

  Future<void> _serve() async {
    await for (final socket in _server) {
      unawaited(_handle(socket));
    }
  }

  Future<void> _handle(Socket socket) async {
    socket.write('* OK NyaMail test IMAP\r\n');
    final reader = _SocketTestReader(socket);
    while (true) {
      final command = await reader.readLine();
      if (command == null) return;
      _commands.add(command);
      final tag = command.split(' ').first;
      if (command.contains(' LOGIN ')) {
        socket.write('$tag OK LOGIN completed\r\n');
      } else if (command.contains(' AUTHENTICATE XOAUTH2 ')) {
        socket.write('$tag OK AUTHENTICATE completed\r\n');
      } else if (command.contains(' LIST ')) {
        socket.write(
          r'* LIST (\HasNoChildren \Archive) "/" "[Gmail]/All Mail"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren) "/" "Projects"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren) "/" "&Ti1lhw-"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren) "/" "[Gmail]/&XfJSIJZkkK5O9g-"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren) "/" "&g0l6P3ux-"'
          '\r\n',
        );
        socket.write(
          r'* LIST (\HasNoChildren) "/" "&V4NXPpCuTvY-"'
          '\r\n',
        );
        socket.write('$tag OK LIST completed\r\n');
      } else if (command.contains(' SELECT ')) {
        socket.write('* 1 EXISTS\r\n');
        socket.write('$tag OK SELECT completed\r\n');
      } else if (command.contains(' UID SEARCH ALL')) {
        socket.write('* SEARCH ${searchUids.join(' ')}\r\n');
        socket.write('$tag OK SEARCH completed\r\n');
      } else if (command.contains(' UID FETCH ')) {
        final uid = RegExp(r' UID FETCH (\d+) ').firstMatch(command)?.group(1);
        if (uid == null) {
          socket.write('$tag BAD invalid fetch\r\n');
          continue;
        }
        final parsedUid = int.parse(uid);
        fetchedUids.add(parsedUid);
        final raw =
            messagesByUid[parsedUid] ??
            [
              'From: Alice <alice@example.com>',
              'Subject: Message $parsedUid',
              'Date: 2026-07-01T08:00:00Z',
              '',
              'Body $parsedUid',
            ].join('\r\n');
        socket.write(
          '* 1 FETCH (UID $parsedUid FLAGS (\\Seen \\Flagged) BODY[] '
          '{${utf8.encode(raw).length}}\r\n',
        );
        socket.add(utf8.encode(raw));
        socket.write(')\r\n');
        socket.write('$tag OK FETCH completed\r\n');
      } else if (command.contains(' APPEND ')) {
        final literalLength = int.parse(
          RegExp(r'\{(\d+)\}$').firstMatch(command)!.group(1)!,
        );
        socket.write('+ Ready for literal\r\n');
        final bytes = await reader.readBytes(literalLength);
        appendedMessage = utf8.decode(bytes);
        await reader.readLine();
        socket.write('$tag OK APPEND completed\r\n');
      } else if (command.contains(' LOGOUT')) {
        socket.write('* BYE LOGOUT requested\r\n');
        socket.write('$tag OK LOGOUT completed\r\n');
        await socket.close();
        return;
      } else {
        socket.write('$tag BAD unsupported\r\n');
      }
    }
  }
}

class _FakeSmtpServer {
  _FakeSmtpServer._(this._server, {required this.advertiseStartTls});

  final ServerSocket _server;
  final bool advertiseStartTls;
  String receivedData = '';
  bool sawStartTls = false;
  bool sawAuth = false;
  bool sawXoauth2 = false;
  String oauth2Payload = '';
  final recipients = <String>[];

  int get port => _server.port;

  static Future<_FakeSmtpServer> start({bool advertiseStartTls = false}) async {
    final server = _FakeSmtpServer._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      advertiseStartTls: advertiseStartTls,
    );
    unawaited(server._serve());
    return server;
  }

  Future<void> close() async {
    await _server.close();
  }

  Future<void> _serve() async {
    await for (final socket in _server) {
      unawaited(_handle(socket));
    }
  }

  Future<void> _handle(Socket socket) async {
    socket.write('220 nyamail test smtp\r\n');
    final lines =
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream();
    var readingData = false;
    final dataLines = <String>[];
    await for (final line in lines) {
      if (readingData) {
        if (line == '.') {
          receivedData = dataLines.join('\r\n');
          readingData = false;
          socket.write('250 queued\r\n');
        } else {
          dataLines.add(line);
        }
        continue;
      }
      if (line.startsWith('EHLO')) {
        socket.write('250-nyamail\r\n');
        if (advertiseStartTls) {
          socket.write('250-STARTTLS\r\n');
        }
        socket.write('250 AUTH LOGIN\r\n');
      } else if (line == 'STARTTLS') {
        sawStartTls = true;
        socket.write(
          advertiseStartTls
              ? '220 ready to start TLS\r\n'
              : '454 TLS unavailable\r\n',
        );
      } else if (line == 'AUTH LOGIN') {
        sawAuth = true;
        socket.write('334 VXNlcm5hbWU6\r\n');
      } else if (line.startsWith('AUTH XOAUTH2 ')) {
        sawXoauth2 = true;
        oauth2Payload = utf8.decode(
          base64Decode(line.substring('AUTH XOAUTH2 '.length)),
        );
        socket.write('235 authenticated\r\n');
      } else if (line == base64Encode(utf8.encode('me@example.com'))) {
        socket.write('334 UGFzc3dvcmQ6\r\n');
      } else if (line == base64Encode(utf8.encode('secret'))) {
        socket.write('235 authenticated\r\n');
      } else if (line.startsWith('MAIL FROM:')) {
        socket.write('250 ok\r\n');
      } else if (line.startsWith('RCPT TO:')) {
        final match = RegExp(r'^RCPT TO:<([^>]+)>$').firstMatch(line);
        if (match != null) recipients.add(match.group(1)!);
        socket.write('250 ok\r\n');
      } else if (line == 'DATA') {
        readingData = true;
        socket.write('354 send data\r\n');
      } else if (line == 'QUIT') {
        socket.write('221 bye\r\n');
        await socket.close();
        return;
      } else {
        socket.write('250 ok\r\n');
      }
    }
  }
}

class _SocketTestReader {
  _SocketTestReader(Socket socket) {
    _subscription = socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _flush();
      },
      onDone: () {
        _closed = true;
        _flush();
      },
      onError: (Object error) {
        _completeError(error);
      },
    );
  }

  final _buffer = <int>[];
  final _pendingLines = <Completer<String?>>[];
  final _pendingBytes = <_PendingTestBytes>[];
  late final StreamSubscription<List<int>> _subscription;
  bool _closed = false;

  Future<String?> readLine() {
    final line = _tryReadLine();
    if (line != null) return Future.value(line);
    if (_closed) return Future.value(null);
    final completer = Completer<String?>();
    _pendingLines.add(completer);
    return completer.future;
  }

  Future<List<int>> readBytes(int length) {
    if (_buffer.length >= length) return Future.value(_takeBytes(length));
    final pending = _PendingTestBytes(length);
    _pendingBytes.add(pending);
    return pending.completer.future;
  }

  void _flush() {
    while (_pendingBytes.isNotEmpty &&
        _buffer.length >= _pendingBytes.first.length) {
      final pending = _pendingBytes.removeAt(0);
      pending.completer.complete(_takeBytes(pending.length));
    }
    while (_pendingBytes.isEmpty && _pendingLines.isNotEmpty) {
      final line = _tryReadLine();
      if (line == null) break;
      _pendingLines.removeAt(0).complete(line);
    }
    if (_closed) {
      while (_pendingLines.isNotEmpty) {
        _pendingLines.removeAt(0).complete(null);
      }
      while (_pendingBytes.isNotEmpty) {
        _pendingBytes.removeAt(0).completer.complete(const []);
      }
    }
  }

  void _completeError(Object error) {
    while (_pendingLines.isNotEmpty) {
      _pendingLines.removeAt(0).completeError(error);
    }
    while (_pendingBytes.isNotEmpty) {
      _pendingBytes.removeAt(0).completer.completeError(error);
    }
  }

  String? _tryReadLine() {
    for (var i = 0; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10) {
        final line = utf8.decode(_buffer.sublist(0, i));
        _buffer.removeRange(0, i + 2);
        return line;
      }
    }
    return null;
  }

  List<int> _takeBytes(int length) {
    final bytes = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return bytes;
  }

  Future<void> close() {
    return _subscription.cancel();
  }
}

class _PendingTestBytes {
  _PendingTestBytes(this.length);

  final int length;
  final completer = Completer<List<int>>();
}
