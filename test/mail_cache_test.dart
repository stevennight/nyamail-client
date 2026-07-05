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
