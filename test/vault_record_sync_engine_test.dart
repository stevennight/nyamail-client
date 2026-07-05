import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/security/local_vault_record_store.dart';
import 'package:nyamail/src/security/local_vault_sync_state_store.dart';
import 'package:nyamail/src/security/vault_crypto.dart';
import 'package:nyamail/src/security/vault_document.dart';
import 'package:nyamail/src/security/vault_record_crypto.dart';
import 'package:nyamail/src/security/vault_record_sync_engine.dart';
import 'package:nyamail/src/security/vault_record_sync_mapper.dart';
import 'package:nyamail/src/security/vault_records.dart';

void main() {
  test(
    'vault record sync engine pushes local and pulls remote records',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-sync-engine-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const vaultCrypto = VaultCrypto();
      const recordCrypto = VaultRecordCrypto();
      const mapper = VaultRecordSyncMapper();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final recordStore = LocalVaultRecordStore(
        supportDirectoryProvider: () async => temp,
      );
      final stateStore = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => temp,
      );
      final localRecords = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.imapSmtp,
              address: 'local@example.com',
              displayName: 'Local',
              provider: 'imap',
              username: 'local@example.com',
              secret: 'local-secret',
              imapHost: 'imap.example.com',
              imapPort: 993,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              useTls: true,
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      await recordStore.write(
        profileId: 'owner',
        expectedRevision: 0,
        records: localRecords,
      );
      final remoteRecords = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertOAuthProvider(
            const VaultOAuthProviderConfig(
              provider: 'gmail',
              clientId: 'remote-client-id',
              clientSecret: 'remote-client-secret',
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      final pushed = <SyncRecord>[];
      final engine = VaultRecordSyncEngine(
        recordStore: recordStore,
        stateStore: stateStore,
      );

      final result = await engine.sync(
        profileId: 'owner',
        deviceId: 'local-device',
        pushRecords: (records) async {
          pushed.addAll(records);
          return const SyncPushResult(logicalTime: 2);
        },
        pullRecords: ({required after, required limit}) async {
          expect(after, 0);
          expect(limit, 500);
          return SyncPullResult(
            records: [
              mapper.toSyncRecord(
                record: remoteRecords.records.single,
                deviceId: 'remote-device',
              ),
            ],
            nextCursor: 3,
          );
        },
      );

      expect(result.pushed, 1);
      expect(result.pulled, 1);
      expect(result.conflicts, 0);
      expect(result.cursor, 3);
      expect(pushed.single.deviceId, 'local-device');
      expect((await stateStore.read('owner'))?.cursor, 3);
      final merged = await recordStore.read('owner');
      final decrypted = await recordCrypto.decryptRecordSet(
        records: merged!.records,
        vaultSecret: vaultSecret,
      );
      final document = decrypted.toVaultDocument();
      expect(document.items.single.address, 'local@example.com');
      expect(
        document.oauthProviders.single.clientSecret,
        'remote-client-secret',
      );
      expect(
        merged.records.records.where((record) => record.syncDirty),
        isEmpty,
      );
    },
  );

  test('vault record sync engine applies newer tombstones', () async {
    final temp = await Directory.systemTemp.createTemp(
      'nyamail-vault-sync-tombstone-test-',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    const vaultCrypto = VaultCrypto();
    const recordCrypto = VaultRecordCrypto();
    const mapper = VaultRecordSyncMapper();
    final vaultSecret = vaultCrypto.newVaultSecret();
    final recordStore = LocalVaultRecordStore(
      supportDirectoryProvider: () async => temp,
    );
    final stateStore = LocalVaultSyncStateStore(
      supportDirectoryProvider: () async => temp,
    );
    final localRecords = await recordCrypto.encryptRecordSet(
      records: VaultRecordSet.fromVaultDocument(
        VaultDocument.empty().upsertMailbox(
          const VaultMailboxItem(
            id: 'mail-1',
            kind: VaultItemKind.imapSmtp,
            address: 'deleted@example.com',
            displayName: 'Deleted',
            provider: 'imap',
            username: 'deleted@example.com',
            secret: 'deleted-secret',
            imapHost: 'imap.example.com',
            imapPort: 993,
            smtpHost: 'smtp.example.com',
            smtpPort: 587,
            useTls: true,
          ),
        ),
      ),
      vaultSecret: vaultSecret,
    );
    await recordStore.write(
      profileId: 'owner',
      expectedRevision: 0,
      records: EncryptedVaultRecordSet(
        version: localRecords.version,
        records: [
          localRecords.records.single.copyWith(
            syncDirty: false,
            lastSyncedLogicalTime: 1,
            lastSyncedContentHash: localRecords.records.single.contentHash,
          ),
        ],
      ),
    );
    final tombstone = await recordCrypto.encryptRecord(
      record: VaultRecord(
        id: 'mail-1',
        type: VaultRecordTypes.mailAccount,
        entityId: 'mail-1',
        payload: const {},
        version: 2,
        updatedAt: DateTime.utc(2026, 5, 6),
        deleted: true,
      ),
      vaultSecret: vaultSecret,
    );
    final engine = VaultRecordSyncEngine(
      recordStore: recordStore,
      stateStore: stateStore,
    );

    final result = await engine.sync(
      profileId: 'owner',
      deviceId: 'local-device',
      pushRecords: (records) async {
        fail('clean local records should not be pushed');
      },
      pullRecords:
          ({required after, required limit}) async => SyncPullResult(
            records: [
              mapper.toSyncRecord(record: tombstone, deviceId: 'remote-device'),
            ],
            nextCursor: 4,
          ),
    );

    expect(result.pushed, 0);
    expect(result.pulled, 1);
    expect(result.conflicts, 0);
    final merged = await recordStore.read('owner');
    final decrypted = await recordCrypto.decryptRecordSet(
      records: merged!.records,
      vaultSecret: vaultSecret,
    );

    expect(decrypted.records.single.deleted, isTrue);
    expect(decrypted.toVaultDocument().items, isEmpty);
    expect((await stateStore.read('owner'))?.cursor, 4);
  });

  test('vault record sync engine does not push clean records twice', () async {
    final temp = await Directory.systemTemp.createTemp(
      'nyamail-vault-sync-clean-test-',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    const vaultCrypto = VaultCrypto();
    const recordCrypto = VaultRecordCrypto();
    final vaultSecret = vaultCrypto.newVaultSecret();
    final recordStore = LocalVaultRecordStore(
      supportDirectoryProvider: () async => temp,
    );
    final stateStore = LocalVaultSyncStateStore(
      supportDirectoryProvider: () async => temp,
    );
    final localRecords = await recordCrypto.encryptRecordSet(
      records: VaultRecordSet.fromVaultDocument(
        VaultDocument.empty().upsertOAuthProvider(
          const VaultOAuthProviderConfig(
            provider: 'gmail',
            clientId: 'client-id',
            clientSecret: 'client-secret',
          ),
        ),
      ),
      vaultSecret: vaultSecret,
    );
    await recordStore.write(
      profileId: 'owner',
      expectedRevision: 0,
      records: localRecords,
    );
    final engine = VaultRecordSyncEngine(
      recordStore: recordStore,
      stateStore: stateStore,
    );

    await engine.sync(
      profileId: 'owner',
      deviceId: 'local-device',
      pushRecords: (records) async => const SyncPushResult(logicalTime: 1),
      pullRecords:
          ({required after, required limit}) async =>
              const SyncPullResult(records: [], nextCursor: 1),
    );
    final second = await engine.sync(
      profileId: 'owner',
      deviceId: 'local-device',
      pushRecords: (records) async {
        fail('record was already clean after the first sync');
      },
      pullRecords:
          ({required after, required limit}) async =>
              const SyncPullResult(records: [], nextCursor: 1),
    );

    expect(second.pushed, 0);
    expect(second.pulled, 0);
    expect(second.conflicts, 0);
    expect(
      (await recordStore.read('owner'))!.records.records.single.syncDirty,
      isFalse,
    );
  });

  test(
    'vault record sync engine keeps local dirty record over pulled tombstone',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-sync-dirty-tombstone-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const vaultCrypto = VaultCrypto();
      const recordCrypto = VaultRecordCrypto();
      const mapper = VaultRecordSyncMapper();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final recordStore = LocalVaultRecordStore(
        supportDirectoryProvider: () async => temp,
      );
      final stateStore = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => temp,
      );
      final localRecords = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.imapSmtp,
              address: 'local-wins@example.com',
              displayName: 'Local wins',
              provider: 'imap',
              username: 'local-wins@example.com',
              secret: 'local-secret',
              imapHost: 'imap.example.com',
              imapPort: 993,
              smtpHost: 'smtp.example.com',
              smtpPort: 587,
              useTls: true,
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      await recordStore.write(
        profileId: 'owner',
        expectedRevision: 0,
        records: localRecords,
      );
      final tombstone = await recordCrypto.encryptRecord(
        record: VaultRecord(
          id: 'mail-1',
          type: VaultRecordTypes.mailAccount,
          entityId: 'mail-1',
          payload: const {},
          version: 2,
          updatedAt: DateTime.utc(2026, 5, 6),
          deleted: true,
        ),
        vaultSecret: vaultSecret,
      );
      final engine = VaultRecordSyncEngine(
        recordStore: recordStore,
        stateStore: stateStore,
      );

      final result = await engine.sync(
        profileId: 'owner',
        deviceId: 'local-device',
        pushRecords: (records) async => const SyncPushResult(logicalTime: 2),
        pullRecords:
            ({required after, required limit}) async => SyncPullResult(
              records: [
                mapper.toSyncRecord(
                  record: tombstone,
                  deviceId: 'remote-device',
                ),
              ],
              nextCursor: 4,
            ),
      );

      expect(result.pushed, 1);
      expect(result.pulled, 1);
      expect(result.conflicts, 1);
      final merged = await recordStore.read('owner');
      final decrypted = await recordCrypto.decryptRecordSet(
        records: merged!.records,
        vaultSecret: vaultSecret,
      );

      expect(decrypted.records.single.deleted, isFalse);
      expect(
        decrypted.toVaultDocument().items.single.address,
        'local-wins@example.com',
      );
      expect(merged.records.records.single.syncDirty, isFalse);
    },
  );

  test(
    'new device restores record vault from sync without legacy vault blob',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-sync-new-device-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const vaultCrypto = VaultCrypto();
      const recordCrypto = VaultRecordCrypto();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final server = _FakeVaultRecordSyncServer();
      final deviceADir = Directory('${temp.path}/device-a');
      final deviceBDir = Directory('${temp.path}/device-b');
      final deviceARecords = LocalVaultRecordStore(
        supportDirectoryProvider: () async => deviceADir,
      );
      final deviceAState = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => deviceADir,
      );
      final deviceBRecords = LocalVaultRecordStore(
        supportDirectoryProvider: () async => deviceBDir,
      );
      final deviceBState = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => deviceBDir,
      );
      final remoteDocument = VaultDocument.empty()
          .upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.oauth,
              address: 'restored@example.com',
              displayName: 'Restored',
              provider: 'gmail',
              username: 'restored@example.com',
              secret: 'access-token',
              refreshToken: 'refresh-token',
              imapHost: 'imap.gmail.com',
              imapPort: 993,
              smtpHost: 'smtp.gmail.com',
              smtpPort: 587,
              useTls: true,
            ),
          )
          .upsertOAuthProvider(
            const VaultOAuthProviderConfig(
              provider: 'gmail',
              clientId: 'gmail-client-id',
              clientSecret: 'gmail-client-secret',
            ),
          );
      await deviceARecords.write(
        profileId: 'owner',
        expectedRevision: 0,
        records: await recordCrypto.encryptRecordSet(
          records: VaultRecordSet.fromVaultDocument(remoteDocument),
          vaultSecret: vaultSecret,
        ),
      );

      final deviceAResult = await VaultRecordSyncEngine(
        recordStore: deviceARecords,
        stateStore: deviceAState,
      ).sync(
        profileId: 'owner',
        deviceId: 'device-a',
        pushRecords: server.push,
        pullRecords: server.pull,
      );
      final deviceBResult = await VaultRecordSyncEngine(
        recordStore: deviceBRecords,
        stateStore: deviceBState,
      ).sync(
        profileId: 'owner',
        deviceId: 'device-b',
        pushRecords: server.push,
        pullRecords: server.pull,
      );

      expect(deviceAResult.pushed, 2);
      expect(deviceBResult.pushed, 0);
      expect(deviceBResult.pulled, 2);
      final restoredSnapshot = await deviceBRecords.read('owner');
      expect(restoredSnapshot, isNotNull);
      final restoredDocument =
          (await recordCrypto.decryptRecordSet(
            records: restoredSnapshot!.records,
            vaultSecret: vaultSecret,
          )).toVaultDocument();
      expect(restoredDocument.items.single.address, 'restored@example.com');
      expect(
        restoredDocument.oauthProviders.single.clientId,
        'gmail-client-id',
      );
      expect(
        restoredSnapshot.records.records.where((record) => record.syncDirty),
        isEmpty,
      );
      expect((await deviceBState.read('owner'))?.cursor, deviceBResult.cursor);
    },
  );

  test(
    'vault record sync engine syncs records across two fake devices',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'nyamail-vault-sync-two-device-test-',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      const vaultCrypto = VaultCrypto();
      const recordCrypto = VaultRecordCrypto();
      final vaultSecret = vaultCrypto.newVaultSecret();
      final server = _FakeVaultRecordSyncServer();
      final deviceADir = Directory('${temp.path}/device-a');
      final deviceBDir = Directory('${temp.path}/device-b');
      final deviceARecords = LocalVaultRecordStore(
        supportDirectoryProvider: () async => deviceADir,
      );
      final deviceAState = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => deviceADir,
      );
      final deviceBRecords = LocalVaultRecordStore(
        supportDirectoryProvider: () async => deviceBDir,
      );
      final deviceBState = LocalVaultSyncStateStore(
        supportDirectoryProvider: () async => deviceBDir,
      );
      final initialA = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertMailbox(
            const VaultMailboxItem(
              id: 'mail-1',
              kind: VaultItemKind.oauth,
              address: 'owner@example.com',
              displayName: 'Owner',
              provider: 'gmail',
              username: 'owner@example.com',
              secret: 'access-token',
              refreshToken: 'refresh-token',
              imapHost: 'imap.gmail.com',
              imapPort: 993,
              smtpHost: 'smtp.gmail.com',
              smtpPort: 587,
              useTls: true,
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      await deviceARecords.write(
        profileId: 'owner',
        expectedRevision: 0,
        records: initialA,
      );
      final engineA = VaultRecordSyncEngine(
        recordStore: deviceARecords,
        stateStore: deviceAState,
      );
      final engineB = VaultRecordSyncEngine(
        recordStore: deviceBRecords,
        stateStore: deviceBState,
      );

      final firstA = await engineA.sync(
        profileId: 'owner',
        deviceId: 'device-a',
        pushRecords: server.push,
        pullRecords: server.pull,
      );
      final firstB = await engineB.sync(
        profileId: 'owner',
        deviceId: 'device-b',
        pushRecords: server.push,
        pullRecords: server.pull,
      );

      expect(firstA.pushed, 1);
      expect(firstB.pushed, 0);
      expect(firstB.pulled, 1);
      final pulledB = await deviceBRecords.read('owner');
      final documentB =
          (await recordCrypto.decryptRecordSet(
            records: pulledB!.records,
            vaultSecret: vaultSecret,
          )).toVaultDocument();
      expect(documentB.items.single.address, 'owner@example.com');
      expect(pulledB.records.records.single.syncDirty, isFalse);

      final oauthProvider = await recordCrypto.encryptRecordSet(
        records: VaultRecordSet.fromVaultDocument(
          VaultDocument.empty().upsertOAuthProvider(
            const VaultOAuthProviderConfig(
              provider: 'gmail',
              clientId: 'client-from-device-b',
              clientSecret: 'secret-from-device-b',
            ),
          ),
        ),
        vaultSecret: vaultSecret,
      );
      await deviceBRecords.write(
        profileId: 'owner',
        expectedRevision: pulledB.revision,
        records: EncryptedVaultRecordSet(
          version: pulledB.records.version,
          records: [...pulledB.records.records, oauthProvider.records.single],
        ),
      );

      final secondB = await engineB.sync(
        profileId: 'owner',
        deviceId: 'device-b',
        pushRecords: server.push,
        pullRecords: server.pull,
      );
      final secondA = await engineA.sync(
        profileId: 'owner',
        deviceId: 'device-a',
        pushRecords: server.push,
        pullRecords: server.pull,
      );

      expect(secondB.pushed, 1);
      expect(secondA.pushed, 0);
      expect(secondA.pulled, 1);
      final pulledA = await deviceARecords.read('owner');
      final documentA =
          (await recordCrypto.decryptRecordSet(
            records: pulledA!.records,
            vaultSecret: vaultSecret,
          )).toVaultDocument();
      expect(documentA.items.single.address, 'owner@example.com');
      expect(documentA.oauthProviders.single.clientId, 'client-from-device-b');
      expect(
        pulledA.records.records.where((record) => record.syncDirty),
        isEmpty,
      );
    },
  );
}

class _FakeVaultRecordSyncServer {
  final Map<String, SyncRecord> _records = {};
  int _clock = 0;

  Future<SyncPushResult> push(List<SyncRecord> records) async {
    for (final record in records) {
      _clock++;
      _records[record.id] = SyncRecord(
        id: record.id,
        entityType: record.entityType,
        entityId: record.entityId,
        deviceId: record.deviceId,
        version: record.version,
        versionVector: record.versionVector,
        logicalTime: _clock,
        algorithm: record.algorithm,
        kdf: record.kdf,
        nonce: record.nonce,
        ciphertext: record.ciphertext,
        contentHash: record.contentHash,
        metadata: record.metadata,
        deleted: record.deleted,
        updatedAt: DateTime.utc(2026, 7, 5),
      );
    }
    return SyncPushResult(logicalTime: _clock);
  }

  Future<SyncPullResult> pull({required int after, required int limit}) async {
    final records =
        _records.values.where((record) => record.logicalTime > after).toList()
          ..sort((a, b) {
            final logicalTime = a.logicalTime.compareTo(b.logicalTime);
            return logicalTime == 0 ? a.id.compareTo(b.id) : logicalTime;
          });
    final limited = records.take(limit).toList();
    return SyncPullResult(
      records: limited,
      nextCursor: limited.isEmpty ? after : limited.last.logicalTime,
    );
  }
}
