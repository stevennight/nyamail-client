import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/local_vault_sync_state_store.dart';

void main() {
  test('local vault sync state persists cursor and timestamp', () async {
    final temp = await Directory.systemTemp.createTemp(
      'nyamail-vault-sync-state-test-',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final store = LocalVaultSyncStateStore(
      supportDirectoryProvider: () async => temp,
    );
    final syncedAt = DateTime.utc(2026, 6, 7, 8, 9, 10);

    await store.write(
      profileId: 'owner@example.com',
      state: LocalVaultSyncState(cursor: 42, lastSyncedAt: syncedAt),
    );
    final loaded = await store.read('owner@example.com');

    expect(loaded?.cursor, 42);
    expect(loaded?.lastSyncedAt, syncedAt);

    await store.clear('owner@example.com');

    expect(await store.read('owner@example.com'), isNull);
  });
}
