import 'local_vault_record_store.dart';
import 'local_vault_store.dart';
import 'vault_crypto.dart';
import 'vault_document.dart';
import 'vault_record_crypto.dart';
import 'vault_records.dart';

class LocalVaultDocumentLoadResult {
  const LocalVaultDocumentLoadResult({
    required this.document,
    required this.recordRevision,
    required this.migratedLegacyVault,
    required this.createdRecordVault,
  });

  final VaultDocument document;
  final int recordRevision;
  final bool migratedLegacyVault;
  final bool createdRecordVault;
}

Future<LocalVaultDocumentLoadResult> loadOrMigrateLocalVaultDocument({
  required String profileId,
  required String profileEmail,
  required String vaultSecret,
  required LocalVaultRecordStore recordStore,
  required LocalVaultStore legacyStore,
  required VaultRecordCrypto recordCrypto,
  required VaultCrypto vaultCrypto,
  DateTime Function()? clock,
}) async {
  final recordSnapshot = await recordStore.read(profileId);
  if (recordSnapshot != null) {
    final records = await recordCrypto.decryptRecordSet(
      records: recordSnapshot.records,
      vaultSecret: vaultSecret,
    );
    return LocalVaultDocumentLoadResult(
      document: records.toVaultDocument(),
      recordRevision: recordSnapshot.revision,
      migratedLegacyVault: false,
      createdRecordVault: false,
    );
  }

  final legacySnapshot = await legacyStore.read(profileId);
  final document =
      legacySnapshot == null
          ? VaultDocument.empty()
          : await vaultCrypto.decryptDocument(
            blob: legacySnapshot.blob,
            email: profileEmail,
            password: '',
            vaultSecret: vaultSecret,
          );
  final encrypted = await recordCrypto.encryptRecordSet(
    records: VaultRecordSet.fromVaultDocument(
      document,
      updatedAt: (clock ?? DateTime.now)().toUtc(),
    ),
    vaultSecret: vaultSecret,
  );
  final saved = await recordStore.write(
    profileId: profileId,
    expectedRevision: 0,
    records: encrypted,
  );
  if (legacySnapshot != null) {
    await legacyStore.clear(profileId);
  }
  return LocalVaultDocumentLoadResult(
    document: document,
    recordRevision: saved.revision,
    migratedLegacyVault: legacySnapshot != null,
    createdRecordVault: true,
  );
}
