import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_cache.dart';
import 'package:nyamail/src/mail/mail_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nyamail-cache-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'mail cache namespaces isolate local messages per signed-in user',
    () async {
      final userACache = MailCache(
        namespace: mailCacheNamespaceForUser('user-a'),
        supportDirectoryProvider: () async => tempDir,
      );
      final userBCache = MailCache(
        namespace: mailCacheNamespaceForUser('user-b'),
        supportDirectoryProvider: () async => tempDir,
      );

      await userACache.saveMessages([
        MailMessage(
          id: 'work:inbox:1',
          accountId: 'work',
          from: 'Alice <alice@example.com>',
          subject: 'Private A',
          preview: 'Only user A should see this.',
          body: 'Only user A should see this.',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
      ]);

      expect(await userBCache.loadMessages(), isEmpty);
      expect(await userACache.loadMessages(), hasLength(1));
    },
  );

  test('mail cache namespace does not expose the raw user id', () {
    final namespace = mailCacheNamespaceForUser('alice@example.com');

    expect(namespace, startsWith('user-'));
    expect(namespace, isNot(contains('alice')));
    expect(namespace, isNot(contains('@')));
  });

  test(
    'mail cache encrypts saved message content when a secret is available',
    () async {
      final namespace = mailCacheNamespaceForUser('user-a');
      final cache = MailCache(
        namespace: namespace,
        localCacheSecret: _testSecret(),
        supportDirectoryProvider: () async => tempDir,
      );

      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:secret',
          accountId: 'work',
          from: 'Alice <alice@example.com>',
          subject: 'Quarterly plan',
          preview: 'Sensitive preview',
          body: 'Sensitive body that should not be on disk as plaintext.',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
      ]);

      final file = File('${tempDir.path}/mail-cache/$namespace/messages.json');
      final raw = await file.readAsString(encoding: utf8);
      final loaded = await cache.loadMessages();

      expect(raw, contains('nyamail-local-cache-aes256gcm-v1'));
      expect(raw, isNot(contains('Quarterly plan')));
      expect(raw, isNot(contains('Sensitive body')));
      expect(loaded.single.subject, 'Quarterly plan');
      expect(loaded.single.body, contains('Sensitive body'));
    },
  );

  test('mail cache decodes encoded headers from existing cache', () async {
    final cache = MailCache(supportDirectoryProvider: () async => tempDir);

    await cache.saveMessages([
      MailMessage(
        id: 'work:inbox:encoded',
        accountId: 'work',
        from: '=?UTF-8?B?5rWL6K+V?= <alice@example.com>',
        subject: '=?utf-8?B?5L2g?= =?utf-8?B?5aW9?=',
        preview: 'Preview',
        body: 'Body',
        receivedAt: DateTime.utc(2026, 7, 2),
        hasAttachments: true,
        attachments: const [
          MailAttachment(
            filename: '=?UTF-8?Q?=E6=8A=A5=E5=91=8A.pdf?=',
            contentType: 'application/pdf',
            partId: '1',
            transferEncoding: 'base64',
          ),
        ],
      ),
    ]);

    final loaded = await cache.loadMessages();

    expect(loaded.single.from, '测试 <alice@example.com>');
    expect(loaded.single.subject, '你好');
    expect(loaded.single.attachments.single.filename, '报告.pdf');
  });

  test('mail cache skips disk rewrites for unchanged messages', () async {
    final cache = MailCache(
      localCacheSecret: _testSecret(),
      supportDirectoryProvider: () async => tempDir,
    );
    final message = MailMessage(
      id: 'work:inbox:unchanged',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'No changes',
      preview: 'Same preview',
      body: '',
      receivedAt: DateTime.utc(2026, 7, 2),
      bodyLoaded: false,
    );

    await cache.saveMessages([message]);
    final file = File('${tempDir.path}/mail-cache/messages.json');
    final firstWrite = await file.readAsString(encoding: utf8);

    await cache.saveMessages([message]);

    expect(await file.readAsString(encoding: utf8), firstWrite);
  });

  test('mail cache round trips a large encrypted payload', () async {
    final cache = MailCache(
      localCacheSecret: _testSecret(),
      supportDirectoryProvider: () async => tempDir,
    );
    final message = MailMessage(
      id: 'work:inbox:large',
      accountId: 'work',
      from: 'Alice <alice@example.com>',
      subject: 'Large local cache entry',
      preview: 'A large body is stored locally.',
      body: List<String>.filled(72 * 1024, 'x').join(),
      receivedAt: DateTime.utc(2026, 7, 2),
    );

    await cache.saveMessages([message]);
    final indexFile = File('${tempDir.path}/mail-cache/messages.json');
    final bodiesFile = File('${tempDir.path}/mail-cache/bodies.json');
    final encryptedIndex = await indexFile.readAsString(encoding: utf8);
    final encryptedBodies = await bodiesFile.readAsString(encoding: utf8);

    expect(encryptedBodies, contains('nyamail-local-cache-aes256gcm-v1'));
    expect(encryptedBodies, isNot(contains('xxxxxxxxxx')));

    await cache.clear();
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsString(encryptedIndex, encoding: utf8);
    await bodiesFile.writeAsString(encryptedBodies, encoding: utf8);

    final loaded = await cache.loadMessages();

    expect(loaded, hasLength(1));
    expect(loaded.single.id, message.id);
    expect(loaded.single.body, message.body);
  });

  test('mail cache splits legacy inline bodies into a bodies file', () async {
    final indexFile = File('${tempDir.path}/mail-cache/messages.json');
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsString(
      jsonEncode([
        {
          'id': 'work:inbox:legacy',
          'account_id': 'work',
          'from': 'Alice <alice@example.com>',
          'subject': 'Legacy entry',
          'preview': 'Legacy preview',
          'body': 'Legacy plain body',
          'html_body': '<p>Legacy body</p>',
          'received_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'body_loaded': true,
        },
      ]),
      encoding: utf8,
    );

    final cache = MailCache(supportDirectoryProvider: () async => tempDir);
    final loaded = await cache.loadMessages();

    expect(loaded.single.body, 'Legacy plain body');
    expect(loaded.single.htmlBody, '<p>Legacy body</p>');

    final bodiesFile = File('${tempDir.path}/mail-cache/bodies.json');
    expect(await bodiesFile.exists(), isTrue);
    final rewrittenIndex = jsonDecode(
      await indexFile.readAsString(encoding: utf8),
    );
    expect((rewrittenIndex as List).single, isNot(contains('body')));
  });

  test(
    'mail cache list load omits body text and reports bodyLoaded false',
    () async {
      final cache = MailCache(supportDirectoryProvider: () async => tempDir);
      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:withbody',
          accountId: 'work',
          from: 'Alice <alice@example.com>',
          subject: 'Has a body',
          preview: 'Preview',
          body: 'A cached body',
          htmlBody: '<p>A cached body</p>',
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
      ]);

      final listView = await cache.loadMessages(includeBodies: false);
      expect(listView.single.body, isEmpty);
      expect(listView.single.htmlBody, isEmpty);
      expect(listView.single.bodyLoaded, isFalse);

      final body = await cache.loadBody('work:inbox:withbody');
      expect(body?.body, 'A cached body');
      expect(body?.htmlBody, '<p>A cached body</p>');
    },
  );

  test(
    'mail cache flag-only change does not rewrite the bodies file',
    () async {
      final cache = MailCache(supportDirectoryProvider: () async => tempDir);
      final message = MailMessage(
        id: 'work:inbox:flag',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        subject: 'Flag me',
        preview: 'Preview',
        body: 'Body text',
        receivedAt: DateTime.utc(2026, 7, 2),
      );
      await cache.saveMessages([message]);
      final bodiesFile = File('${tempDir.path}/mail-cache/bodies.json');
      final bodiesBefore = await bodiesFile.readAsString(encoding: utf8);
      final bodiesModifiedBefore = (await bodiesFile.stat()).modified;

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await cache.updateMessage(
        message.copyWith(read: true, body: '', bodyLoaded: false),
      );

      expect(await bodiesFile.readAsString(encoding: utf8), bodiesBefore);
      expect((await bodiesFile.stat()).modified, bodiesModifiedBefore);
      final loaded = await cache.loadMessages();
      expect(loaded.single.read, isTrue);
      expect(loaded.single.body, 'Body text');
    },
  );

  test('mail cache loadBody returns null for a preview-only message', () async {
    final cache = MailCache(supportDirectoryProvider: () async => tempDir);
    await cache.saveMessages([
      MailMessage(
        id: 'work:inbox:previewonly',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        subject: 'Preview only',
        preview: 'Preview text',
        body: '',
        receivedAt: DateTime.utc(2026, 7, 2),
        bodyLoaded: false,
      ),
    ]);

    expect(await cache.loadBody('work:inbox:previewonly'), isNull);
    expect(await cache.loadBody('work:inbox:missing'), isNull);
  });

  test('mail cache deletes a batch in one logical update', () async {
    final cache = MailCache(supportDirectoryProvider: () async => tempDir);
    await cache.saveMessages([
      for (final id in ['one', 'two', 'three'])
        MailMessage(
          id: 'work:inbox:$id',
          accountId: 'work',
          from: 'Sender <sender@example.com>',
          subject: id,
          preview: id,
          body: id,
          receivedAt: DateTime.utc(2026, 7, 2),
        ),
    ]);

    await cache.deleteMessages(['work:inbox:one', 'work:inbox:three']);

    expect((await cache.loadMessages()).map((message) => message.id), [
      'work:inbox:two',
    ]);
  });

  test(
    'mail cache quarantines unreadable json instead of failing load',
    () async {
      final cache = MailCache(supportDirectoryProvider: () async => tempDir);
      final file = File('${tempDir.path}/mail-cache/messages.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('not json', encoding: utf8);

      final loaded = await cache.loadMessages();

      expect(loaded, isEmpty);
      expect(await file.exists(), isFalse);
      final quarantined =
          await file.parent
              .list()
              .where(
                (entity) =>
                    entity is File &&
                    entity.path.contains('messages.json.invalid-'),
              )
              .toList();
      expect(quarantined, hasLength(1));
    },
  );

  test(
    'mail cache does not treat invalid cached dates as current time',
    () async {
      final cache = MailCache(supportDirectoryProvider: () async => tempDir);
      final file = File('${tempDir.path}/mail-cache/messages.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode([
          {
            'id': 'work:inbox:bad-date',
            'account_id': 'work',
            'from': 'Alice <alice@example.com>',
            'subject': 'Bad date',
            'preview': 'Preview',
            'body': 'Body',
            'received_at': 'not a date',
          },
        ]),
        encoding: utf8,
      );

      final loaded = await cache.loadMessages();

      expect(
        loaded.single.receivedAt,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    },
  );

  test(
    'mail cache preserves loaded body when a preview is saved later',
    () async {
      final cache = MailCache(supportDirectoryProvider: () async => tempDir);

      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:42',
          accountId: 'work',
          from: 'Alice <alice@example.com>',
          subject: 'Loaded',
          preview: 'Full preview',
          body: 'Full body',
          htmlBody: '<p>Full body</p>',
          receivedAt: DateTime.utc(2026, 7, 2),
          hasAttachments: true,
          attachments: const [
            MailAttachment(
              filename: 'report.pdf',
              contentType: 'application/pdf',
              partId: '2',
            ),
          ],
        ),
      ]);

      await cache.saveMessages([
        MailMessage(
          id: 'work:inbox:42',
          accountId: 'work',
          from: 'Alice <alice@example.com>',
          subject: 'Loaded',
          preview: 'Fresh preview',
          body: '',
          receivedAt: DateTime.utc(2026, 7, 2, 1),
          bodyLoaded: false,
        ),
      ]);

      final loaded = await cache.loadMessages();

      expect(loaded.single.preview, 'Fresh preview');
      expect(loaded.single.bodyLoaded, isTrue);
      expect(loaded.single.body, 'Full body');
      expect(loaded.single.htmlBody, '<p>Full body</p>');
      expect(loaded.single.hasAttachments, isTrue);
      expect(loaded.single.attachments.single.filename, 'report.pdf');
    },
  );

  test('mail cache persists preview-only messages', () async {
    final cache = MailCache(supportDirectoryProvider: () async => tempDir);

    await cache.saveMessages([
      MailMessage(
        id: 'work:inbox:preview',
        accountId: 'work',
        from: 'Alice <alice@example.com>',
        subject: 'Preview',
        preview: 'Preview text',
        body: '',
        receivedAt: DateTime.utc(2026, 7, 2),
        bodyLoaded: false,
      ),
    ]);

    final loaded = await cache.loadMessages();

    expect(loaded.single.bodyLoaded, isFalse);
    expect(loaded.single.body, isEmpty);
    expect(loaded.single.preview, 'Preview text');
  });

  test(
    'mail cache serializes concurrent writes without dropping messages',
    () async {
      final cacheA = MailCache(supportDirectoryProvider: () async => tempDir);
      final cacheB = MailCache(supportDirectoryProvider: () async => tempDir);

      await Future.wait([
        for (var index = 0; index < 20; index++)
          (index.isEven ? cacheA : cacheB).saveMessages([
            MailMessage(
              id: 'work:inbox:$index',
              accountId: 'work',
              from: 'Sender <sender@example.com>',
              subject: 'Message $index',
              preview: 'Preview $index',
              body: '',
              receivedAt: DateTime.utc(2026, 7, 2, 0, index),
              bodyLoaded: false,
            ),
          ]),
      ]);

      final loaded = await cacheA.loadMessages();

      expect(loaded.map((message) => message.id).toSet(), {
        for (var index = 0; index < 20; index++) 'work:inbox:$index',
      });
    },
  );

  test('mail cache clear removes only the selected user namespace', () async {
    final userACache = MailCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );
    final userBCache = MailCache(
      namespace: mailCacheNamespaceForUser('user-b'),
      supportDirectoryProvider: () async => tempDir,
    );
    await userACache.saveMessages([
      MailMessage(
        id: 'work:inbox:a',
        accountId: 'work',
        from: 'A <a@example.com>',
        subject: 'A',
        preview: 'A',
        body: 'A',
        receivedAt: DateTime.utc(2026, 7, 2),
      ),
    ]);
    await userBCache.saveMessages([
      MailMessage(
        id: 'work:inbox:b',
        accountId: 'work',
        from: 'B <b@example.com>',
        subject: 'B',
        preview: 'B',
        body: 'B',
        receivedAt: DateTime.utc(2026, 7, 2),
      ),
    ]);

    await userACache.clear();

    expect(await userACache.loadMessages(), isEmpty);
    expect(await userBCache.loadMessages(), hasLength(1));
  });
}

String _testSecret() =>
    base64UrlEncode(List<int>.generate(32, (index) => index));
