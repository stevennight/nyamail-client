import 'package:shared_preferences/shared_preferences.dart';

import 'mail_appearance.dart';

class MailRenderSettings {
  const MailRenderSettings({
    this.autoLoadRemoteImages = false,
    this.autoLoadExternalStylesAndFonts = false,
    this.appearance = MailAppearance.automatic,
  });

  static const defaults = MailRenderSettings();

  final bool autoLoadRemoteImages;
  final bool autoLoadExternalStylesAndFonts;
  final MailAppearance appearance;

  MailRenderSettings copyWith({
    bool? autoLoadRemoteImages,
    bool? autoLoadExternalStylesAndFonts,
    MailAppearance? appearance,
  }) {
    return MailRenderSettings(
      autoLoadRemoteImages: autoLoadRemoteImages ?? this.autoLoadRemoteImages,
      autoLoadExternalStylesAndFonts:
          autoLoadExternalStylesAndFonts ?? this.autoLoadExternalStylesAndFonts,
      appearance: appearance ?? this.appearance,
    );
  }
}

class MailRenderSettingsStore {
  const MailRenderSettingsStore();

  static const _remoteImagesKey = 'nyamail.render.auto_load_remote_images';
  static const _externalStylesAndFontsKey =
      'nyamail.render.auto_load_external_styles_and_fonts';
  static const _appearanceKey = 'nyamail.render.appearance';

  Future<MailRenderSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return MailRenderSettings(
      autoLoadRemoteImages: prefs.getBool(_remoteImagesKey) ?? false,
      autoLoadExternalStylesAndFonts:
          prefs.getBool(_externalStylesAndFontsKey) ?? false,
      appearance: mailAppearanceFromStorage(prefs.getString(_appearanceKey)),
    );
  }

  Future<void> save(MailRenderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_remoteImagesKey, settings.autoLoadRemoteImages);
    await prefs.setBool(
      _externalStylesAndFontsKey,
      settings.autoLoadExternalStylesAndFonts,
    );
    await prefs.setString(_appearanceKey, settings.appearance.storageValue);
  }
}
