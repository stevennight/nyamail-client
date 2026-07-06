import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/nyamail_api.dart';
import 'package:nyamail/src/app/app_theme_settings.dart';
import 'package:nyamail/src/mail/mail_models.dart';
import 'package:nyamail/src/mail/mail_repository.dart';
import 'package:nyamail/src/mail/mail_transport.dart';
import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/release/release_service.dart';
import 'package:nyamail/src/release/release_verifier.dart';
import 'package:nyamail/src/security/local_secure_store.dart';
import 'package:nyamail/src/security/local_vault_record_store.dart';
import 'package:nyamail/src/security/local_vault_store.dart';
import 'package:nyamail/src/security/local_vault_sync_state_store.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/ui/mail_home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('starts on create gate instead of opening creation dialog', (
    tester,
  ) async {
    await tester.pumpWidget(_mailHomePage());
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Create local vault'), findsOneWidget);
    expect(
      find.text('A local vault is required before mail accounts can be added.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('starts on unlock gate instead of prompting immediately', (
    tester,
  ) async {
    const secureStore = LocalSecureStore();
    await secureStore.saveLocalProfile(
      const LocalProfile(id: 'local-profile', displayName: 'Personal vault'),
    );

    await tester.pumpWidget(_mailHomePage(secureStore: secureStore));
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Unlock Personal vault'), findsOneWidget);
    expect(
      find.text('Your local vault is locked on this device.'),
      findsOneWidget,
    );
    expect(find.text('Vault password'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}

Widget _mailHomePage({
  LocalSecureStore secureStore = const LocalSecureStore(),
}) {
  final api = NyaMailApi(baseUrl: 'http://localhost:8080');
  return MaterialApp(
    home: MailHomePage(
      api: api,
      apiBaseUrl: 'http://localhost:8080',
      defaultApiBaseUrl: 'http://localhost:8080',
      onApiBaseUrlChanged: (_) async {},
      appThemeSetting: AppThemeSetting.system,
      onAppThemeSettingChanged: (_) async {},
      releaseService: ReleaseService(
        api: api,
        channel: 'dev',
        verifier: ReleaseVerifier(publicKey: ''),
      ),
      secureStore: secureStore,
      localVaultStore: const LocalVaultStore(),
      localVaultRecordStore: const LocalVaultRecordStore(),
      localVaultSyncStateStore: const LocalVaultSyncStateStore(),
      vaultCrypto: const VaultCrypto(),
      vaultRecordCrypto: const VaultRecordCrypto(),
      oauthClient: OAuthLoopbackClient(openAuthorizationUrl: (_) async {}),
      gmailOAuthClientId: '',
      gmailOAuthClientSecret: '',
      outlookOAuthClientId: '',
      outlookOAuthClientSecret: '',
      mailRepository: const _EmptyMailRepository(),
    ),
  );
}

class _EmptyMailRepository implements MailRepository {
  const _EmptyMailRepository();

  static const _page = MailMessagePage(messages: [], hasMore: false);

  @override
  Future<List<MailAccount>> accounts() async => const [];

  @override
  Future<List<MailFolder>> folders({String? accountId}) async => const [];

  @override
  Future<MailMessagePage> cachedViewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessagePage> viewPage({
    required MailboxView view,
    String? query,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessagePage> loadOlderViewMessages({
    required MailboxView view,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessagePage> cachedMessagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessagePage> messagePage({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessagePage> loadOlderMessages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    required int visibleCount,
    int limit = 30,
  }) async => _page;

  @override
  Future<MailMessage> loadMessageBody(MailMessage message) async => message;

  @override
  Future<List<MailMessage>> messages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async => const [];

  @override
  Future<void> sendReply({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {}

  @override
  Future<void> sendReplyAll({
    required MailMessage original,
    required String textBody,
    String htmlBody = '',
    List<OutgoingAttachment> attachments = const [],
  }) async {}

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
  }) async {}

  @override
  Future<MailMessage> setRead({
    required MailMessage message,
    required bool read,
  }) async => message.copyWith(read: read);

  @override
  Future<MailMessage> setStarred({
    required MailMessage message,
    required bool starred,
  }) async => message.copyWith(starred: starred);

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
  }) {
    throw UnimplementedError();
  }
}
