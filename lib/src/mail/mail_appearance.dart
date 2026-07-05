enum MailAppearance { automatic, light, dark }

extension MailAppearanceLabel on MailAppearance {
  String get storageValue {
    return switch (this) {
      MailAppearance.automatic => 'auto',
      MailAppearance.light => 'light',
      MailAppearance.dark => 'dark',
    };
  }

  String get label {
    return switch (this) {
      MailAppearance.automatic => 'Auto',
      MailAppearance.light => 'Light',
      MailAppearance.dark => 'Dark',
    };
  }
}

MailAppearance mailAppearanceFromStorage(String? value) {
  return switch (value?.trim().toLowerCase()) {
    'light' => MailAppearance.light,
    'dark' => MailAppearance.dark,
    _ => MailAppearance.automatic,
  };
}
