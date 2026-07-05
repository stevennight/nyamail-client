import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_cache.dart';
import 'package:nyamail/src/mail/mail_draft_cache.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nyamail-draft-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('compose draft round trips locally', () async {
    final cache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );
    final updatedAt = DateTime.utc(2026, 7, 2, 10, 30);

    await cache.saveComposeDraft(
      MailDraft(
        accountId: 'work',
        to: 'alice@example.com',
        cc: 'bob@example.com',
        bcc: 'audit@example.com',
        subject: 'Status',
        body: 'Draft body',
        updatedAt: updatedAt,
      ),
    );

    final draft = await cache.loadComposeDraft();

    expect(draft, isNotNull);
    expect(draft!.accountId, 'work');
    expect(draft.to, 'alice@example.com');
    expect(draft.cc, 'bob@example.com');
    expect(draft.bcc, 'audit@example.com');
    expect(draft.subject, 'Status');
    expect(draft.body, 'Draft body');
    expect(draft.updatedAt.toUtc(), updatedAt);
  });

  test('empty compose draft deletes the saved draft', () async {
    final cache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );

    await cache.saveComposeDraft(
      MailDraft(
        accountId: 'work',
        body: 'Text that should be removed',
        updatedAt: DateTime.utc(2026, 7, 2),
      ),
    );
    await cache.saveComposeDraft(
      MailDraft(accountId: 'work', updatedAt: DateTime.utc(2026, 7, 2)),
    );

    expect(await cache.loadComposeDraft(), isNull);
  });

  test(
    'compose draft encrypts saved content when a secret is available',
    () async {
      final namespace = mailCacheNamespaceForUser('user-a');
      final cache = MailDraftCache(
        namespace: namespace,
        localCacheSecret: _testSecret(),
        supportDirectoryProvider: () async => tempDir,
      );

      await cache.saveComposeDraft(
        MailDraft(
          accountId: 'work',
          to: 'alice@example.com',
          subject: 'Sensitive subject',
          body: 'Sensitive draft body',
          updatedAt: DateTime.utc(2026, 7, 2),
        ),
      );

      final file = File('${tempDir.path}/mail-drafts/$namespace/compose.json');
      final raw = await file.readAsString(encoding: utf8);
      final draft = await cache.loadComposeDraft();

      expect(raw, contains('nyamail-local-cache-aes256gcm-v1'));
      expect(raw, isNot(contains('alice@example.com')));
      expect(raw, isNot(contains('Sensitive draft body')));
      expect(draft?.to, 'alice@example.com');
      expect(draft?.body, 'Sensitive draft body');
    },
  );

  test('draft namespaces isolate local drafts per signed-in user', () async {
    final userACache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );
    final userBCache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-b'),
      supportDirectoryProvider: () async => tempDir,
    );

    await userACache.saveComposeDraft(
      MailDraft(
        accountId: 'work',
        subject: 'Private A',
        body: 'Only user A should see this.',
        updatedAt: DateTime.utc(2026, 7, 2),
      ),
    );

    expect(await userBCache.loadComposeDraft(), isNull);
    expect((await userACache.loadComposeDraft())?.subject, 'Private A');
  });

  test('draft clear removes only the selected user namespace', () async {
    final userACache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );
    final userBCache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-b'),
      supportDirectoryProvider: () async => tempDir,
    );
    await userACache.saveComposeDraft(
      MailDraft(
        accountId: 'work',
        subject: 'A',
        body: 'A',
        updatedAt: DateTime.utc(2026, 7, 2),
      ),
    );
    await userBCache.saveComposeDraft(
      MailDraft(
        accountId: 'personal',
        subject: 'B',
        body: 'B',
        updatedAt: DateTime.utc(2026, 7, 2),
      ),
    );

    await userACache.clear();

    expect(await userACache.loadComposeDraft(), isNull);
    expect((await userBCache.loadComposeDraft())?.subject, 'B');
  });
}

String _testSecret() =>
    base64UrlEncode(List<int>.generate(32, (index) => index));
