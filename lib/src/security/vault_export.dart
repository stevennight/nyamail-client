import 'dart:convert';

import '../api/models.dart';
import 'vault_crypto.dart';
import 'vault_document.dart';

class VaultExportService {
  const VaultExportService({VaultCrypto crypto = const VaultCrypto()})
    : _crypto = crypto;

  static const format = 'nyamail-vault-export';
  static const version = 1;
  static const scope = 'vault';
  static const extension = 'nyavault';
  static const _keyIdentity = 'nyamail-vault-export-v1';
  static const minimumPasswordLength = 12;

  final VaultCrypto _crypto;

  Future<String> exportDocument({
    required VaultDocument document,
    required String password,
    DateTime? createdAt,
  }) async {
    _validatePassword(password);
    final blob = await _crypto.encryptDocument(
      document: document,
      email: _keyIdentity,
      password: password,
    );
    return jsonEncode({
      'format': format,
      'version': version,
      'scope': scope,
      'created_at': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      'blob': blob.toJson(),
    });
  }

  Future<VaultDocument> importDocument({
    required String encoded,
    required String password,
  }) async {
    _validatePassword(password);
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const VaultExportException('export file must contain an object');
      }
      final json = decoded.cast<String, Object?>();
      if (json['format'] != format) {
        throw const VaultExportException('unsupported export file format');
      }
      if ((json['version'] as num?)?.toInt() != version) {
        throw const VaultExportException('unsupported export file version');
      }
      if (json['scope'] != scope) {
        throw const VaultExportException('export file is not a vault export');
      }
      final blobJson = json['blob'];
      if (blobJson is! Map) {
        throw const VaultExportException(
          'export file is missing encrypted data',
        );
      }
      return await _crypto.decryptDocument(
        blob: EncryptedBlob.fromJson(blobJson.cast<String, Object?>()),
        email: _keyIdentity,
        password: password,
      );
    } on VaultExportException {
      rethrow;
    } on VaultCryptoException catch (error) {
      throw VaultExportException(error.message);
    } on FormatException catch (error) {
      throw VaultExportException(
        'export file is not valid JSON: ${error.message}',
      );
    } on TypeError {
      throw const VaultExportException('export file structure is invalid');
    }
  }

  void _validatePassword(String password) {
    if (password.length < minimumPasswordLength) {
      throw const VaultExportException(
        'export password must contain at least 12 characters',
      );
    }
  }
}

enum VaultImportConflictPolicy { keepLocal, replaceLocal }

class VaultImportPlan {
  const VaultImportPlan({
    required this.current,
    required this.incoming,
    required this.mailboxConflicts,
    required this.oauthProviderConflicts,
  });

  factory VaultImportPlan.create({
    required VaultDocument current,
    required VaultDocument incoming,
  }) {
    final mailboxConflicts = <VaultMailboxConflict>[];
    for (final item in incoming.items) {
      final existing = _findMatchingMailbox(current.items, item);
      if (existing != null) {
        mailboxConflicts.add(
          VaultMailboxConflict(existing: existing, incoming: item),
        );
      }
    }
    final oauthProviderConflicts = <VaultOAuthProviderConflict>[];
    for (final provider in incoming.oauthProviders) {
      final existing = _findMatchingProvider(current.oauthProviders, provider);
      if (existing != null) {
        oauthProviderConflicts.add(
          VaultOAuthProviderConflict(existing: existing, incoming: provider),
        );
      }
    }
    return VaultImportPlan(
      current: current,
      incoming: incoming,
      mailboxConflicts: List.unmodifiable(mailboxConflicts),
      oauthProviderConflicts: List.unmodifiable(oauthProviderConflicts),
    );
  }

  final VaultDocument current;
  final VaultDocument incoming;
  final List<VaultMailboxConflict> mailboxConflicts;
  final List<VaultOAuthProviderConflict> oauthProviderConflicts;

  int get newMailboxCount => incoming.items.length - mailboxConflicts.length;

  int get newOAuthProviderCount =>
      incoming.oauthProviders.length - oauthProviderConflicts.length;

  bool get hasConflicts =>
      mailboxConflicts.isNotEmpty || oauthProviderConflicts.isNotEmpty;

  VaultDocument merge(VaultImportConflictPolicy policy) {
    final importedByMailboxId = {
      for (final item in incoming.items) item.id: item,
    };
    final importedByMailboxKey = {
      for (final item in incoming.items) _mailboxKey(item): item,
    };
    final importedByProvider = {
      for (final provider in incoming.oauthProviders)
        normalizeOAuthProviderKey(provider.provider): provider,
    };
    final currentMailboxIds = current.items.map((item) => item.id).toSet();
    final mergedItems = <VaultMailboxItem>[];

    for (final existing in current.items) {
      final imported =
          importedByMailboxId[existing.id] ??
          importedByMailboxKey[_mailboxKey(existing)];
      if (imported == null || policy == VaultImportConflictPolicy.keepLocal) {
        mergedItems.add(existing);
      } else {
        mergedItems.add(imported.copyWith(id: existing.id));
      }
    }
    for (final imported in incoming.items) {
      final matching = _findMatchingMailbox(current.items, imported);
      if (matching != null) continue;
      final id =
          currentMailboxIds.contains(imported.id)
              ? VaultCrypto().newVaultItemId(imported.address)
              : imported.id;
      mergedItems.add(imported.copyWith(id: id));
    }

    final mergedProviders = <VaultOAuthProviderConfig>[];
    for (final existing in current.oauthProviders) {
      final imported =
          importedByProvider[normalizeOAuthProviderKey(existing.provider)];
      if (imported == null || policy == VaultImportConflictPolicy.keepLocal) {
        mergedProviders.add(existing);
      } else {
        mergedProviders.add(imported);
      }
    }
    for (final imported in incoming.oauthProviders) {
      if (current.oauthProviders.any(
        (existing) =>
            normalizeOAuthProviderKey(existing.provider) ==
            normalizeOAuthProviderKey(imported.provider),
      )) {
        continue;
      }
      mergedProviders.add(imported);
    }

    return current.copyWith(
      version: current.version,
      items: mergedItems,
      oauthProviders: mergedProviders,
    );
  }
}

class VaultMailboxConflict {
  const VaultMailboxConflict({required this.existing, required this.incoming});

  final VaultMailboxItem existing;
  final VaultMailboxItem incoming;
}

class VaultOAuthProviderConflict {
  const VaultOAuthProviderConflict({
    required this.existing,
    required this.incoming,
  });

  final VaultOAuthProviderConfig existing;
  final VaultOAuthProviderConfig incoming;
}

class VaultExportException implements Exception {
  const VaultExportException(this.message);

  final String message;

  @override
  String toString() => 'VaultExportException: $message';
}

VaultMailboxItem? _findMatchingMailbox(
  List<VaultMailboxItem> items,
  VaultMailboxItem target,
) {
  for (final item in items) {
    if (item.id == target.id || _mailboxKey(item) == _mailboxKey(target)) {
      return item;
    }
  }
  return null;
}

VaultOAuthProviderConfig? _findMatchingProvider(
  List<VaultOAuthProviderConfig> providers,
  VaultOAuthProviderConfig target,
) {
  for (final provider in providers) {
    if (normalizeOAuthProviderKey(provider.provider) ==
        normalizeOAuthProviderKey(target.provider)) {
      return provider;
    }
  }
  return null;
}

String _mailboxKey(VaultMailboxItem item) {
  return [
    item.kind.name,
    item.provider.trim().toLowerCase(),
    item.address.trim().toLowerCase(),
  ].join('|');
}
