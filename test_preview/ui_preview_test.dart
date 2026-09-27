// ignore_for_file: invalid_use_of_visible_for_testing_member
// Renders the unlocked mail UI with fake data into PNG files for visual review.
// Run: flutter test --no-pub test_preview/ui_preview_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/api/nyamail_api.dart';
import 'package:nyamail/src/app/app_theme.dart';
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
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/security/vault_records.dart';
import 'package:nyamail/src/ui/mail_home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fontDir = r'D:\Software\Flutter\bin\cache\artifacts\material_fonts';

Future<void> _loadFonts() async {
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final name in [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
    'roboto-light.ttf',
  ]) {
    roboto.addFont(read('$_fontDir\\$name'));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(read('$_fontDir\\materialicons-regular.otf'));
  await icons.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    await _loadFonts();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('nyamail_preview');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
    debugDisableShadows = false;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    required Size size,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recordStore = LocalVaultRecordStore(
      supportDirectoryProvider: () async => tempDir,
    );
    const secureStore = LocalSecureStore();
    await tester.runAsync(() async {
      await secureStore.saveLocalProfile(
        const LocalProfile(id: 'p1', displayName: 'Personal vault'),
      );
      const secret = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
      await secureStore.saveVaultSecret(secret);
      final document = VaultDocument(
        version: 1,
        items: [
          _mailbox('acc-1', 'alice@example.com', 'Alice Work'),
          _mailbox('acc-2', 'alice.home@example.net', 'Alice Home'),
        ],
      );
      final encrypted = await const VaultRecordCrypto().encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          document,
          updatedAt: DateTime.utc(2026, 9, 1),
        ),
        vaultSecret: secret,
      );
      await recordStore.write(
        profileId: 'p1',
        expectedRevision: 0,
        records: encrypted,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode:
            brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        home: MailHomePage(
          api: NyaMailApi(baseUrl: 'http://localhost:8080'),
          apiBaseUrl: 'http://localhost:8080',
          defaultApiBaseUrl: 'http://localhost:8080',
          onApiBaseUrlChanged: (_) async {},
          appThemeSetting: AppThemeSetting.system,
          onAppThemeSettingChanged: (_) async {},
          releaseService: _NoopReleaseService(),
          secureStore: secureStore,
          localVaultStore: const LocalVaultStore(),
          localVaultRecordStore: recordStore,
          localVaultSyncStateStore: const LocalVaultSyncStateStore(),
          vaultCrypto: const VaultCrypto(),
          vaultRecordCrypto: const VaultRecordCrypto(),
          oauthClient: OAuthLoopbackClient(openAuthorizationUrl: (_) async {}),
          gmailOAuthClientId: '',
          gmailOAuthClientSecret: '',
          gmailAndroidOAuthClientId: '',
          gmailAndroidOAuthClientSecret: '',
          gmailAndroidOAuthRedirectUri: '',
          outlookOAuthClientId: '',
          outlookOAuthClientSecret: '',
          outlookAndroidOAuthClientId: '',
          outlookAndroidOAuthClientSecret: '',
          outlookAndroidOAuthRedirectUri: '',
          mailRepository: _SampleMailRepository(),
          vaultMailRepositoryBuilder: (_) => _SampleMailRepository(),
        ),
      ),
    );
    debugDisableShadows = false;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 400));
    addTearDown(() => debugDisableShadows = true);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/$name.png'),
    );
  }

  testWidgets('desktop', (tester) async {
    await pumpHome(tester, size: const Size(1400, 860));
    await shot(tester, 'desktop');
  });

  testWidgets('desktop dark', (tester) async {
    await pumpHome(
      tester,
      size: const Size(1400, 860),
      brightness: Brightness.dark,
    );
    await shot(tester, 'desktop_dark');
  });

  testWidgets('desktop settings', (tester) async {
    await pumpHome(tester, size: const Size(1400, 860));
    await tester.tap(find.byTooltip('Settings').first);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot(tester, 'desktop_settings');
  });

  testWidgets('mobile', (tester) async {
    await pumpHome(tester, size: const Size(412, 900));
    await shot(tester, 'mobile');
  });

  testWidgets('mobile settings', (tester) async {
    await pumpHome(tester, size: const Size(412, 900));
    await tester.tap(find.byTooltip('Settings').first);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await shot(tester, 'mobile_settings');
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('desktop settings notifications', (tester) async {
    await pumpHome(tester, size: const Size(1400, 860));
    await tester.tap(find.byTooltip('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Notifications').last);
    await settle(tester);
    await shot(tester, 'desktop_settings_notifications');
  });

  testWidgets('desktop bundle expanded', (tester) async {
    await pumpHome(tester, size: const Size(1400, 860));
    await tester.tap(find.text('Notifications').first);
    await settle(tester);
    await tester.tap(find.text('Carol Wu').first);
    await settle(tester);
    await shot(tester, 'desktop_bundle');
  });

  testWidgets('mobile settings inbox', (tester) async {
    await pumpHome(tester, size: const Size(412, 900));
    await tester.tap(find.byTooltip('Settings').first);
    await settle(tester);
    await tester.tap(find.text('Inbox & actions'));
    await settle(tester);
    await shot(tester, 'mobile_settings_inbox');
  });
}

VaultMailboxItem _mailbox(String id, String address, String name) {
  return VaultMailboxItem(
    id: id,
    kind: VaultItemKind.imapSmtp,
    address: address,
    displayName: name,
    provider: 'imap',
    username: address,
    secret: 'x',
    imapHost: '127.0.0.1',
    imapPort: 1,
    smtpHost: '127.0.0.1',
    smtpPort: 1,
    useTls: false,
  );
}

final _now = DateTime.now();

MailMessage _msg(
  int n, {
  required String from,
  required String subject,
  required String preview,
  Duration ago = Duration.zero,
  bool read = false,
  bool starred = false,
  bool attachments = false,
  String account = 'acc-1',
}) {
  return MailMessage(
    id: '$account:INBOX:$n',
    accountId: account,
    from: from,
    subject: subject,
    preview: preview,
    body: preview,
    receivedAt: _now.subtract(ago),
    read: read,
    starred: starred,
    hasAttachments: attachments,
    folderPath: 'INBOX',
    bodyLoaded: false,
  );
}

final _sampleMessages = [
  _msg(
    1,
    from: 'Bob Chen <bob@example.com>',
    subject: 'Q3 planning notes',
    preview: 'Hey Alice, attaching the notes from today. Let me know...',
    ago: const Duration(minutes: 12),
    attachments: true,
  ),
  _msg(
    2,
    from: 'GitHub <noreply@github.com>',
    subject: '[nyamail] CI run failed on main',
    preview: 'The workflow ci.yml failed for commit 3f2a1c.',
    ago: const Duration(minutes: 40),
  ),
  _msg(
    3,
    from: 'Carol Wu <carol@example.org>',
    subject: 'Re: Dinner on Friday?',
    preview: 'Sounds great, see you at 7!',
    ago: const Duration(hours: 2),
    starred: true,
    account: 'acc-2',
  ),
  _msg(
    4,
    from: 'The Verge <newsletter@theverge.com>',
    subject: 'Verge Daily: the week in gadgets',
    preview: 'Top stories today: new phones, new chips, new everything.',
    ago: const Duration(hours: 3),
  ),
  _msg(
    5,
    from: 'Amazon <shipment-tracking@amazon.com>',
    subject: 'Your package has shipped',
    preview: 'Arriving Thursday. Track your package.',
    ago: const Duration(hours: 5),
    account: 'acc-2',
  ),
  _msg(
    6,
    from: 'Dan Lee <dan@example.com>',
    subject: 'Contract draft v2',
    preview: 'Updated per legal feedback, see section 4.',
    ago: const Duration(days: 1, hours: 2),
    read: true,
  ),
  _msg(
    7,
    from: 'Medium Daily Digest <noreply@medium.com>',
    subject: '5 stories picked for you',
    preview: 'Flutter tips, Rust async and more.',
    ago: const Duration(days: 1, hours: 5),
    read: true,
  ),
  _msg(
    8,
    from: 'Eve <eve@example.net>',
    subject: 'Photos from the trip',
    preview: 'Here are the photos I promised.',
    ago: const Duration(days: 3),
    read: true,
    attachments: true,
    account: 'acc-2',
  ),
  _msg(
    9,
    from: 'Slack <notification@slack.com>',
    subject: 'You have 3 unread mentions',
    preview: '#general: @alice can you review...',
    ago: const Duration(days: 4),
    read: true,
  ),
  _msg(
    10,
    from: 'Frank <frank@example.com>',
    subject: 'Lunch?',
    preview: 'Free tomorrow around noon?',
    ago: const Duration(days: 9),
    read: true,
  ),
];

class _NoopReleaseService extends ReleaseService {
  _NoopReleaseService()
    : super(channel: 'dev', verifier: ReleaseVerifier(publicKey: ''));

  @override
  Future<ReleaseCheckResult> check() async {
    return const ReleaseCheckResult(updateAvailable: false);
  }
}

class _SampleMailRepository implements MailRepository {
  MailMessagePage get _page =>
      MailMessagePage(messages: _sampleMessages, hasMore: false);

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
  }) async => const MailMessagePage(messages: [], hasMore: false);

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
  }) async => const MailMessagePage(messages: [], hasMore: false);

  @override
  Future<MailMessage> loadMessageBody(MailMessage message) async => message;

  @override
  Future<List<MailMessage>> messages({
    required MailboxKind mailbox,
    String? accountId,
    String? query,
    int limit = 30,
  }) async => _sampleMessages;

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

  @override
  Future<void> clearLocalCache() async {}
}
