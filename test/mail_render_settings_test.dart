import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_appearance.dart';
import 'package:nyamail/src/mail/mail_render_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('mail render settings default to automatic appearance', () async {
    final settings = await const MailRenderSettingsStore().load();

    expect(settings.appearance, MailAppearance.automatic);
    expect(settings.autoLoadRemoteImages, isFalse);
    expect(settings.autoLoadExternalStylesAndFonts, isFalse);
  });

  test('mail render settings persist appearance mode', () async {
    const store = MailRenderSettingsStore();

    await store.save(
      const MailRenderSettings(
        autoLoadRemoteImages: true,
        autoLoadExternalStylesAndFonts: true,
        appearance: MailAppearance.dark,
      ),
    );
    final loaded = await store.load();

    expect(loaded.autoLoadRemoteImages, isTrue);
    expect(loaded.autoLoadExternalStylesAndFonts, isTrue);
    expect(loaded.appearance, MailAppearance.dark);
  });
}
