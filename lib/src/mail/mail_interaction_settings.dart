import 'package:shared_preferences/shared_preferences.dart';

enum MailListActionPreference {
  pin,
  delete,
  toggleRead,
  toggleStar,
  archive,
  moveToInbox,
}

extension MailListActionPreferenceStorage on MailListActionPreference {
  String get storageValue {
    return switch (this) {
      MailListActionPreference.pin => 'pin',
      MailListActionPreference.delete => 'delete',
      MailListActionPreference.toggleRead => 'toggle_read',
      MailListActionPreference.toggleStar => 'toggle_star',
      MailListActionPreference.archive => 'archive',
      MailListActionPreference.moveToInbox => 'move_to_inbox',
    };
  }
}

MailListActionPreference mailListActionPreferenceFromStorage(String? value) {
  return switch (value) {
    'delete' => MailListActionPreference.delete,
    'toggle_read' => MailListActionPreference.toggleRead,
    'toggle_star' => MailListActionPreference.toggleStar,
    'archive' => MailListActionPreference.archive,
    'move_to_inbox' => MailListActionPreference.moveToInbox,
    _ => MailListActionPreference.pin,
  };
}

class MailInteractionSettings {
  const MailInteractionSettings({
    this.mobileSwipeEnabled = true,
    this.desktopContextMenuEnabled = true,
    this.multiSelectEnabled = true,
    this.smartInbox = true,
    this.mobileSwipeRightToLeftLevel1 = MailListActionPreference.pin,
    this.mobileSwipeRightToLeftLevel2 = MailListActionPreference.delete,
    this.mobileSwipeLeftToRightLevel1 = MailListActionPreference.toggleRead,
    this.mobileSwipeLeftToRightLevel2 = MailListActionPreference.toggleStar,
    this.desktopContextMenuActions = defaultDesktopContextMenuActions,
    this.pinnedMessageIds = const [],
  });

  static const defaultDesktopContextMenuActions = [
    MailListActionPreference.pin,
    MailListActionPreference.delete,
    MailListActionPreference.toggleRead,
    MailListActionPreference.toggleStar,
    MailListActionPreference.archive,
    MailListActionPreference.moveToInbox,
  ];

  static const defaults = MailInteractionSettings();

  final bool mobileSwipeEnabled;
  final bool desktopContextMenuEnabled;
  final bool multiSelectEnabled;

  /// Group automated notifications and newsletters into bundles in incoming
  /// views instead of listing them between mail from people.
  final bool smartInbox;
  final MailListActionPreference mobileSwipeRightToLeftLevel1;
  final MailListActionPreference mobileSwipeRightToLeftLevel2;
  final MailListActionPreference mobileSwipeLeftToRightLevel1;
  final MailListActionPreference mobileSwipeLeftToRightLevel2;
  final List<MailListActionPreference> desktopContextMenuActions;
  final List<String> pinnedMessageIds;

  MailInteractionSettings copyWith({
    bool? mobileSwipeEnabled,
    bool? desktopContextMenuEnabled,
    bool? multiSelectEnabled,
    bool? smartInbox,
    MailListActionPreference? mobileSwipeRightToLeftLevel1,
    MailListActionPreference? mobileSwipeRightToLeftLevel2,
    MailListActionPreference? mobileSwipeLeftToRightLevel1,
    MailListActionPreference? mobileSwipeLeftToRightLevel2,
    List<MailListActionPreference>? desktopContextMenuActions,
    List<String>? pinnedMessageIds,
  }) {
    return MailInteractionSettings(
      mobileSwipeEnabled: mobileSwipeEnabled ?? this.mobileSwipeEnabled,
      desktopContextMenuEnabled:
          desktopContextMenuEnabled ?? this.desktopContextMenuEnabled,
      multiSelectEnabled: multiSelectEnabled ?? this.multiSelectEnabled,
      smartInbox: smartInbox ?? this.smartInbox,
      mobileSwipeRightToLeftLevel1:
          mobileSwipeRightToLeftLevel1 ?? this.mobileSwipeRightToLeftLevel1,
      mobileSwipeRightToLeftLevel2:
          mobileSwipeRightToLeftLevel2 ?? this.mobileSwipeRightToLeftLevel2,
      mobileSwipeLeftToRightLevel1:
          mobileSwipeLeftToRightLevel1 ?? this.mobileSwipeLeftToRightLevel1,
      mobileSwipeLeftToRightLevel2:
          mobileSwipeLeftToRightLevel2 ?? this.mobileSwipeLeftToRightLevel2,
      desktopContextMenuActions:
          desktopContextMenuActions ?? this.desktopContextMenuActions,
      pinnedMessageIds: pinnedMessageIds ?? this.pinnedMessageIds,
    );
  }
}

class MailInteractionSettingsStore {
  const MailInteractionSettingsStore();

  static const _mobileSwipeEnabledKey =
      'nyamail.interaction.mobile_swipe_enabled';
  static const _desktopContextMenuEnabledKey =
      'nyamail.interaction.desktop_context_menu_enabled';
  static const _multiSelectEnabledKey =
      'nyamail.interaction.multi_select_enabled';
  static const _smartInboxKey = 'nyamail.interaction.smart_inbox';
  static const _mobileSwipeRightToLeftLevel1Key =
      'nyamail.interaction.mobile_rtl_level_1';
  static const _mobileSwipeRightToLeftLevel2Key =
      'nyamail.interaction.mobile_rtl_level_2';
  static const _mobileSwipeLeftToRightLevel1Key =
      'nyamail.interaction.mobile_ltr_level_1';
  static const _mobileSwipeLeftToRightLevel2Key =
      'nyamail.interaction.mobile_ltr_level_2';
  static const _desktopContextMenuActionsKey =
      'nyamail.interaction.desktop_context_menu_actions';
  static const _pinnedMessageIdsKey = 'nyamail.interaction.pinned_message_ids';

  Future<MailInteractionSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final contextMenuActions =
        prefs
            .getStringList(_desktopContextMenuActionsKey)
            ?.map(mailListActionPreferenceFromStorage)
            .toList();
    return MailInteractionSettings(
      mobileSwipeEnabled:
          prefs.getBool(_mobileSwipeEnabledKey) ??
          MailInteractionSettings.defaults.mobileSwipeEnabled,
      desktopContextMenuEnabled:
          prefs.getBool(_desktopContextMenuEnabledKey) ??
          MailInteractionSettings.defaults.desktopContextMenuEnabled,
      multiSelectEnabled:
          prefs.getBool(_multiSelectEnabledKey) ??
          MailInteractionSettings.defaults.multiSelectEnabled,
      smartInbox:
          prefs.getBool(_smartInboxKey) ??
          MailInteractionSettings.defaults.smartInbox,
      mobileSwipeRightToLeftLevel1: mailListActionPreferenceFromStorage(
        prefs.getString(_mobileSwipeRightToLeftLevel1Key),
      ),
      mobileSwipeRightToLeftLevel2: mailListActionPreferenceFromStorage(
        prefs.getString(_mobileSwipeRightToLeftLevel2Key) ??
            MailListActionPreference.delete.storageValue,
      ),
      mobileSwipeLeftToRightLevel1: mailListActionPreferenceFromStorage(
        prefs.getString(_mobileSwipeLeftToRightLevel1Key) ??
            MailListActionPreference.toggleRead.storageValue,
      ),
      mobileSwipeLeftToRightLevel2: mailListActionPreferenceFromStorage(
        prefs.getString(_mobileSwipeLeftToRightLevel2Key) ??
            MailListActionPreference.toggleStar.storageValue,
      ),
      desktopContextMenuActions:
          contextMenuActions == null || contextMenuActions.isEmpty
              ? MailInteractionSettings.defaultDesktopContextMenuActions
              : contextMenuActions,
      pinnedMessageIds: prefs.getStringList(_pinnedMessageIdsKey) ?? const [],
    );
  }

  Future<void> save(MailInteractionSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mobileSwipeEnabledKey, settings.mobileSwipeEnabled);
    await prefs.setBool(
      _desktopContextMenuEnabledKey,
      settings.desktopContextMenuEnabled,
    );
    await prefs.setBool(_multiSelectEnabledKey, settings.multiSelectEnabled);
    await prefs.setBool(_smartInboxKey, settings.smartInbox);
    await prefs.setString(
      _mobileSwipeRightToLeftLevel1Key,
      settings.mobileSwipeRightToLeftLevel1.storageValue,
    );
    await prefs.setString(
      _mobileSwipeRightToLeftLevel2Key,
      settings.mobileSwipeRightToLeftLevel2.storageValue,
    );
    await prefs.setString(
      _mobileSwipeLeftToRightLevel1Key,
      settings.mobileSwipeLeftToRightLevel1.storageValue,
    );
    await prefs.setString(
      _mobileSwipeLeftToRightLevel2Key,
      settings.mobileSwipeLeftToRightLevel2.storageValue,
    );
    await prefs.setStringList(
      _desktopContextMenuActionsKey,
      settings.desktopContextMenuActions
          .map((action) => action.storageValue)
          .toList(),
    );
    await prefs.setStringList(_pinnedMessageIdsKey, settings.pinnedMessageIds);
  }
}
