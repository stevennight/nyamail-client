import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/mail/mail_interaction_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('mail interaction settings use Spark-like defaults', () async {
    final settings = await const MailInteractionSettingsStore().load();

    expect(settings.mobileSwipeEnabled, isTrue);
    expect(settings.desktopContextMenuEnabled, isTrue);
    expect(settings.multiSelectEnabled, isTrue);
    expect(settings.mobileSwipeRightToLeftLevel1, MailListActionPreference.pin);
    expect(
      settings.mobileSwipeRightToLeftLevel2,
      MailListActionPreference.delete,
    );
    expect(
      settings.mobileSwipeLeftToRightLevel1,
      MailListActionPreference.toggleRead,
    );
    expect(
      settings.mobileSwipeLeftToRightLevel2,
      MailListActionPreference.toggleStar,
    );
    expect(
      settings.desktopContextMenuActions,
      MailInteractionSettings.defaultDesktopContextMenuActions,
    );
  });

  test('mail interaction settings persist actions and pinned ids', () async {
    const store = MailInteractionSettingsStore();

    await store.save(
      const MailInteractionSettings(
        mobileSwipeEnabled: false,
        desktopContextMenuEnabled: false,
        multiSelectEnabled: false,
        mobileSwipeRightToLeftLevel1: MailListActionPreference.archive,
        mobileSwipeRightToLeftLevel2: MailListActionPreference.delete,
        mobileSwipeLeftToRightLevel1: MailListActionPreference.moveToInbox,
        mobileSwipeLeftToRightLevel2: MailListActionPreference.toggleStar,
        desktopContextMenuActions: [
          MailListActionPreference.delete,
          MailListActionPreference.toggleStar,
        ],
        pinnedMessageIds: ['m-2', 'm-1'],
      ),
    );
    final loaded = await store.load();

    expect(loaded.mobileSwipeEnabled, isFalse);
    expect(loaded.desktopContextMenuEnabled, isFalse);
    expect(loaded.multiSelectEnabled, isFalse);
    expect(
      loaded.mobileSwipeRightToLeftLevel1,
      MailListActionPreference.archive,
    );
    expect(
      loaded.mobileSwipeLeftToRightLevel1,
      MailListActionPreference.moveToInbox,
    );
    expect(loaded.desktopContextMenuActions, [
      MailListActionPreference.delete,
      MailListActionPreference.toggleStar,
    ]);
    expect(loaded.pinnedMessageIds, ['m-2', 'm-1']);
  });
}
