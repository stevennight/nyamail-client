import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_provider_probe.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

void main() {
  test('config applies provider preset and redacts secret', () {
    final config = MailProviderProbeConfig.fromProvider(
      provider: 'gmail',
      address: 'me@gmail.com',
      secret: 'app-password',
    );

    expect(config.imapHost, 'imap.gmail.com');
    expect(config.smtpHost, 'smtp.gmail.com');
    expect(config.smtpPort, 465);
    expect(config.username, 'me@gmail.com');
    expect(config.toRedactedJson()['secret'], 'redacted');
  });

  test('config can request oauth2 transport authentication', () {
    final config = MailProviderProbeConfig.fromProvider(
      provider: 'outlook',
      address: 'me@outlook.com',
      secret: 'access-token',
      authType: MailboxAuthType.oauth2,
    );

    expect(config.authType, MailboxAuthType.oauth2);
    expect(config.toCredential().authType, MailboxAuthType.oauth2);
    expect(config.toRedactedJson()['auth_type'], 'oauth2');
  });

  test('probe validates config before touching transport', () async {
    final transport = _ProbeTransport();
    final result = await MailProviderProbe(transport: transport).run(
      MailProviderProbeConfig.fromProvider(
        provider: 'imap',
        address: '',
        secret: '',
      ),
    );

    expect(result.ok, isFalse);
    expect(result.diagnostic, contains('address is required'));
    expect(result.diagnostic, contains('secret is required'));
    expect(transport.validated, isFalse);
  });

  test('probe succeeds when transport validates credential', () async {
    final transport = _ProbeTransport();
    final result = await MailProviderProbe(transport: transport).run(
      MailProviderProbeConfig.fromProvider(
        provider: 'icloud',
        address: 'me@icloud.com',
        secret: 'app-specific-password',
      ),
    );

    expect(result.ok, isTrue);
    expect(result.diagnostic, isNull);
    expect(transport.validated, isTrue);
    expect(transport.credential?.smtpHost, 'smtp.mail.me.com');
  });

  test('probe returns provider diagnostic on transport failure', () async {
    final transport = _ProbeTransport(
      error: const MailTransportException(
        'SMTP server does not advertise STARTTLS: smtp-mail.outlook.com:587',
      ),
    );
    final result = await MailProviderProbe(transport: transport).run(
      MailProviderProbeConfig.fromProvider(
        provider: 'outlook',
        address: 'me@outlook.com',
        secret: 'secret',
      ),
    );

    expect(result.ok, isFalse);
    expect(result.diagnostic, contains('OAuth2/Modern Auth'));
    expect(result.diagnostic, contains('STARTTLS'));
  });
}

class _ProbeTransport implements MailTransport {
  _ProbeTransport({this.error});

  final Object? error;
  bool validated = false;
  MailboxCredential? credential;

  @override
  Future<void> validateCredential({
    required MailboxCredential credential,
  }) async {
    validated = true;
    this.credential = credential;
    final error = this.error;
    if (error != null) throw error;
  }

  @override
  Future<List<MailFolder>> listFolders({
    required MailboxCredential credential,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<MailMessage>> fetchInbox({
    required MailboxCredential credential,
    int limit = 30,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<MailMessage>> fetchMessages({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<MailMessage>> fetchMessagePreviews({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    int limit = 30,
    int? beforeUid,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<MailMessage>> fetchFolderMessagePreviews({
    required MailboxCredential credential,
    required MailFolder folder,
    int limit = 30,
    int? beforeUid,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<MailMessage> fetchMessageBody({
    required MailboxCredential credential,
    required MailMessage message,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> send({
    required MailboxCredential credential,
    required OutgoingMessage message,
  }) {
    throw UnimplementedError();
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
