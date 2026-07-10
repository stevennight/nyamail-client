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
        htmlBody: '<div><strong>Draft body</strong></div>',
        attachments: const [
          MailDraftAttachment(
            filename: 'status.txt',
            contentType: 'text/plain',
            bytes: [83, 116, 97, 116, 117, 115],
          ),
        ],
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
    expect(draft.htmlBody, '<div><strong>Draft body</strong></div>');
    expect(draft.attachments, hasLength(1));
    expect(draft.attachments.single.filename, 'status.txt');
    expect(draft.attachments.single.contentType, 'text/plain');
    expect(draft.attachments.single.bytes, [83, 116, 97, 116, 117, 115]);
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

  test('legacy plain-text compose draft loads without HTML content', () async {
    final namespace = mailCacheNamespaceForUser('user-a');
    final cache = MailDraftCache(
      namespace: namespace,
      supportDirectoryProvider: () async => tempDir,
    );
    final file = File('${tempDir.path}/mail-drafts/$namespace/compose.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'account_id': 'work',
        'subject': 'Legacy draft',
        'body': 'Plain text only',
        'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
      }),
      encoding: utf8,
    );

    final draft = await cache.loadComposeDraft();

    expect(draft?.subject, 'Legacy draft');
    expect(draft?.body, 'Plain text only');
    expect(draft?.htmlBody, isEmpty);
  });

  test('compose draft serializes concurrent writes', () async {
    final cache = MailDraftCache(
      namespace: mailCacheNamespaceForUser('user-a'),
      supportDirectoryProvider: () async => tempDir,
    );

    await Future.wait([
      cache.saveComposeDraft(
        MailDraft(
          accountId: 'work',
          subject: 'First save',
          body: 'First body',
          updatedAt: DateTime.utc(2026, 7, 2, 10),
        ),
      ),
      cache.saveComposeDraft(
        MailDraft(
          accountId: 'work',
          subject: 'Second save',
          body: 'Second body',
          updatedAt: DateTime.utc(2026, 7, 2, 10, 1),
        ),
      ),
    ]);

    final draft = await cache.loadComposeDraft();

    expect(draft?.subject, 'Second save');
    expect(draft?.body, 'Second body');
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
          htmlBody: '<div><em>Sensitive draft body</em></div>',
          attachments: const [
            MailDraftAttachment(
              filename: 'private.txt',
              contentType: 'text/plain',
              bytes: [112, 114, 105, 118, 97, 116, 101],
            ),
          ],
          updatedAt: DateTime.utc(2026, 7, 2),
        ),
      );

      final file = File('${tempDir.path}/mail-drafts/$namespace/compose.json');
      final raw = await file.readAsString(encoding: utf8);
      final draft = await cache.loadComposeDraft();

      expect(raw, contains('nyamail-local-cache-aes256gcm-v1'));
      expect(raw, isNot(contains('alice@example.com')));
      expect(raw, isNot(contains('Sensitive draft body')));
      expect(raw, isNot(contains('<em>')));
      expect(raw, isNot(contains('private.txt')));
      expect(draft?.to, 'alice@example.com');
      expect(draft?.body, 'Sensitive draft body');
      expect(draft?.htmlBody, '<div><em>Sensitive draft body</em></div>');
      expect(draft?.attachments.single.filename, 'private.txt');
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
