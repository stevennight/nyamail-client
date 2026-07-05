import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_live_smoke.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_provider_probe.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

void main() {
  test(
    'validate mode authenticates and fetches inbox without sending',
    () async {
      final transport = _SmokeTransport();
      final result = await MailLiveSmoke(
        transport: transport,
      ).run(_config(mode: MailLiveSmokeMode.validate));

      expect(result.ok, isTrue);
      expect(transport.validated, isTrue);
      expect(transport.sentMessages, isEmpty);
      expect(transport.fetches, [MailboxKind.inbox]);
      expect(result.steps.map((step) => step.name), [
        'validate_credential',
        'fetch_inbox',
      ]);
    },
  );

  test(
    'roundtrip mode sends tagged message and verifies sent and inbox',
    () async {
      final transport = _SmokeTransport();
      final result = await MailLiveSmoke(transport: transport).run(
        _config(
          mode: MailLiveSmokeMode.roundtrip,
          recipient: 'me@gmail.com',
          expectInboxDelivery: true,
        ),
      );

      expect(result.ok, isTrue);
      expect(transport.sentMessages.single.subject, contains('token-123'));
      expect(transport.sentMessages.single.textBody, contains('token-123'));
      expect(transport.fetches, [
        MailboxKind.inbox,
        MailboxKind.sent,
        MailboxKind.inbox,
      ]);
      expect(result.steps.map((step) => step.name), [
        'validate_credential',
        'fetch_inbox',
        'send_roundtrip_message',
        'verify_sent',
        'verify_inbox_delivery',
      ]);
    },
  );

  test('roundtrip mode can verify generated attachment metadata', () async {
    final transport = _SmokeTransport();
    final result = await MailLiveSmoke(transport: transport).run(
      _config(
        mode: MailLiveSmokeMode.roundtrip,
        recipient: 'me@gmail.com',
        expectInboxDelivery: true,
        includeAttachment: true,
        attachmentFilename: 'provider-smoke.txt',
      ),
    );

    expect(result.ok, isTrue);
    final sentAttachment = transport.sentMessages.single.attachments.single;
    expect(sentAttachment.filename, 'provider-smoke.txt');
    expect(sentAttachment.contentType, smokeAttachmentContentType);
    expect(utf8.decode(sentAttachment.bytes), contains('token-123'));
    expect(
      result.config.toRedactedJson(),
      containsPair('include_attachment', true),
    );
    expect(
      result.config.toRedactedJson(),
      containsPair('attachment_size', sentAttachment.bytes.length),
    );
    expect(
      result.steps.map((step) => step.detail ?? '').join('\n'),
      contains('Verified attachment provider-smoke.txt'),
    );
  });

  test(
    'roundtrip attachment mode fails when provider metadata is missing',
    () async {
      final transport = _SmokeTransport(includeFetchedAttachments: false);
      final result = await MailLiveSmoke(transport: transport).run(
        _config(
          mode: MailLiveSmokeMode.roundtrip,
          recipient: 'me@gmail.com',
          includeAttachment: true,
        ),
      );

      expect(result.ok, isFalse);
      final failedStep = result.steps.last;
      expect(failedStep.name, 'verify_sent');
      expect(failedStep.ok, isFalse);
      expect(failedStep.diagnostic, contains('Expected attachment'));
    },
  );

  test('roundtrip mode requires recipient before touching transport', () async {
    final transport = _SmokeTransport();
    final result = await MailLiveSmoke(
      transport: transport,
    ).run(_config(mode: MailLiveSmokeMode.roundtrip));

    expect(result.ok, isFalse);
    expect(result.diagnostic, contains('recipient is required'));
    expect(transport.validated, isFalse);
  });
}

MailLiveSmokeConfig _config({
  required MailLiveSmokeMode mode,
  String recipient = '',
  bool expectInboxDelivery = false,
  bool includeAttachment = false,
  String attachmentFilename = 'nyamail-smoke-attachment.txt',
}) {
  return MailLiveSmokeConfig(
    providerConfig: MailProviderProbeConfig.fromProvider(
      provider: 'gmail',
      address: 'me@gmail.com',
      secret: 'secret',
    ),
    mode: mode,
    recipient: recipient,
    expectInboxDelivery: expectInboxDelivery,
    includeAttachment: includeAttachment,
    attachmentFilename: attachmentFilename,
    token: 'token-123',
    pollAttempts: 1,
    pollInterval: Duration.zero,
  );
}

class _SmokeTransport implements MailTransport {
  _SmokeTransport({this.includeFetchedAttachments = true});

  final bool includeFetchedAttachments;
  bool validated = false;
  final sentMessages = <OutgoingMessage>[];
  final fetches = <MailboxKind>[];

  @override
  Future<void> validateCredential({
    required MailboxCredential credential,
  }) async {
    validated = true;
  }

  @override
  Future<List<MailFolder>> listFolders({
    required MailboxCredential credential,
  }) async {
    return [
      MailFolder(
        accountId: credential.accountId,
        path: 'INBOX',
        displayName: 'Inbox',
        kind: MailboxKind.inbox,
      ),
    ];
  }

  @override
  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  }) async {
    fetches.add(mailbox);
    final sent = sentMessages.lastOrNull;
    if (sent == null) return const [];
    final attachments =
        includeFetchedAttachments
            ? [
              for (final attachment in sent.attachments)
                MailAttachment(
                  filename: attachment.filename,
                  contentType: attachment.contentType,
                  partId: '2',
                  transferEncoding: 'base64',
                  size: attachment.bytes.length,
                ),
            ]
            : <MailAttachment>[];
    return [
      MailMessage(
        id: 'provider-probe-${mailbox.name}-1',
        accountId: credential.accountId,
        from: credential.address,
        to: sent.to,
        subject: sent.subject,
        preview: sent.textBody,
        body: sent.textBody,
        receivedAt: DateTime.utc(2026, 1, 1),
        mailbox: mailbox,
        hasAttachments: attachments.isNotEmpty,
        attachments: attachments,
      ),
    ];
  }

  @override
  Future<List<MailMessage>> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  }) {
    return fetchMessages(
      credential: credential,
      mailbox: mailbox,
      limit: limit,
    );
  }

  @override
  Future<List<MailMessage>> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  }) {
    return fetchMessages(
      credential: credential,
      mailbox: folder.kind,
      limit: limit,
    );
  }

  @override
  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  }) async {
    return message;
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
    sentMessages.add(message);
  }

  @override
  Future<void> setFlagged({
    required MailboxCredential credential,
    required String messageId,
    required bool flagged,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> setSeen({
    required MailboxCredential credential,
    required String messageId,
    required bool seen,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> moveMessage({
    required MailboxCredential credential,
    required String messageId,
    required MailboxKind destination,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DownloadedAttachment> downloadAttachment({
    required MailboxCredential credential,
    required String messageId,
    required MailAttachment attachment,
  }) {
    throw UnimplementedError();
  }
}

extension _LastOrNull<T> on List<T> {
  T? get lastOrNull => length == 0 ? null : last;
}
