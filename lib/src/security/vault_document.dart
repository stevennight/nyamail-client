import 'dart:convert';

import '../mail/mail_transport.dart';

class VaultDocument {
  const VaultDocument({
    required this.version,
    required this.items,
    this.oauthProviders = const [],
  });

  factory VaultDocument.empty() {
    return const VaultDocument(version: 1, items: []);
  }

  factory VaultDocument.fromJson(Map<String, Object?> json) {
    return VaultDocument(
      version: (json['version'] as num?)?.toInt() ?? 1,
      items:
          ((json['items'] as List?) ?? const [])
              .map(
                (item) => VaultMailboxItem.fromJson(
                  (item as Map).cast<String, Object?>(),
                ),
              )
              .toList(),
      oauthProviders:
          ((json['oauth_providers'] as List?) ?? const [])
              .map(
                (item) => VaultOAuthProviderConfig.fromJson(
                  (item as Map).cast<String, Object?>(),
                ),
              )
              .where((item) => item.provider.isNotEmpty)
              .toList(),
    );
  }

  factory VaultDocument.decodePlaintext(String plaintext) {
    if (plaintext.trim().isEmpty) return VaultDocument.empty();
    return VaultDocument.fromJson(
      (jsonDecode(plaintext) as Map).cast<String, Object?>(),
    );
  }

  final int version;
  final List<VaultMailboxItem> items;
  final List<VaultOAuthProviderConfig> oauthProviders;

  VaultDocument copyWith({
    int? version,
    List<VaultMailboxItem>? items,
    List<VaultOAuthProviderConfig>? oauthProviders,
  }) {
    return VaultDocument(
      version: version ?? this.version,
      items: items ?? this.items,
      oauthProviders: oauthProviders ?? this.oauthProviders,
    );
  }

  VaultDocument upsertMailbox(VaultMailboxItem item) {
    final next = [...items];
    final index = next.indexWhere(
      (existing) => existing.id == item.id || existing.address == item.address,
    );
    if (index >= 0) {
      next[index] = item;
    } else {
      next.add(item);
    }
    return copyWith(items: next);
  }

  VaultDocument removeMailbox(String id) {
    final next = items.where((item) => item.id != id).toList();
    if (next.length == items.length) return this;
    return copyWith(items: next);
  }

  VaultDocument upsertOAuthProvider(VaultOAuthProviderConfig provider) {
    final normalized = provider.normalized();
    if (normalized.provider.isEmpty) return this;
    final next = [...oauthProviders];
    final index = next.indexWhere(
      (item) => item.provider == normalized.provider,
    );
    if (index >= 0) {
      next[index] = normalized;
    } else {
      next.add(normalized);
    }
    return copyWith(oauthProviders: next);
  }

  VaultDocument removeOAuthProvider(String provider) {
    final normalized = normalizeOAuthProviderKey(provider);
    final next =
        oauthProviders.where((item) => item.provider != normalized).toList();
    if (next.length == oauthProviders.length) return this;
    return copyWith(oauthProviders: next);
  }

  VaultOAuthProviderConfig? oauthProviderFor(String provider) {
    final normalized = normalizeOAuthProviderKey(provider);
    for (final item in oauthProviders) {
      if (item.provider == normalized) return item;
    }
    return null;
  }

  List<MailboxCredential> toCredentials() {
    return items
        .where(
          (item) =>
              item.kind == VaultItemKind.imapSmtp ||
              item.kind == VaultItemKind.oauth,
        )
        .map((item) => item.toCredential())
        .toList();
  }

  String encodePlaintext() {
    return jsonEncode(toJson());
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'items': items.map((item) => item.toJson()).toList(),
    if (oauthProviders.isNotEmpty)
      'oauth_providers': oauthProviders.map((item) => item.toJson()).toList(),
  };
}

class VaultOAuthProviderConfig {
  const VaultOAuthProviderConfig({
    required this.provider,
    required this.clientId,
    this.clientSecret = '',
  });

  factory VaultOAuthProviderConfig.fromJson(Map<String, Object?> json) {
    return VaultOAuthProviderConfig(
      provider: normalizeOAuthProviderKey(json['provider'] as String? ?? ''),
      clientId: json['client_id'] as String? ?? '',
      clientSecret: json['client_secret'] as String? ?? '',
    ).normalized();
  }

  final String provider;
  final String clientId;
  final String clientSecret;

  VaultOAuthProviderConfig normalized() {
    return VaultOAuthProviderConfig(
      provider: normalizeOAuthProviderKey(provider),
      clientId: clientId.trim(),
      clientSecret: clientSecret.trim(),
    );
  }

  VaultOAuthProviderConfig copyWith({
    String? provider,
    String? clientId,
    String? clientSecret,
  }) {
    return VaultOAuthProviderConfig(
      provider: provider ?? this.provider,
      clientId: clientId ?? this.clientId,
      clientSecret: clientSecret ?? this.clientSecret,
    ).normalized();
  }

  bool get hasClientId => clientId.trim().isNotEmpty;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'client_id': clientId,
    if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
  };
}

String normalizeOAuthProviderKey(String value) {
  return switch (value.trim().toLowerCase()) {
    'google' => 'gmail',
    'microsoft' => 'outlook',
    final normalized => normalized,
  };
}

enum VaultItemKind { imapSmtp, oauth }

class VaultMailboxItem {
  const VaultMailboxItem({
    required this.id,
    required this.kind,
    required this.address,
    required this.displayName,
    required this.provider,
    required this.username,
    required this.secret,
    this.refreshToken = '',
    this.tokenExpiresAt,
    this.tokenScope = '',
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.useTls,
  });

  factory VaultMailboxItem.fromJson(Map<String, Object?> json) {
    return VaultMailboxItem(
      id: json['id'] as String? ?? '',
      kind:
          (json['kind'] as String? ?? 'imap_smtp') == 'oauth'
              ? VaultItemKind.oauth
              : VaultItemKind.imapSmtp,
      address: json['address'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      provider: json['provider'] as String? ?? 'imap',
      username: json['username'] as String? ?? '',
      secret: json['secret'] as String? ?? '',
      refreshToken: json['refresh_token'] as String? ?? '',
      tokenExpiresAt:
          json['token_expires_at'] == null
              ? null
              : DateTime.parse(json['token_expires_at'] as String),
      tokenScope: json['token_scope'] as String? ?? '',
      imapHost: json['imap_host'] as String? ?? '',
      imapPort: (json['imap_port'] as num?)?.toInt() ?? 993,
      smtpHost: json['smtp_host'] as String? ?? '',
      smtpPort: (json['smtp_port'] as num?)?.toInt() ?? 587,
      useTls: json['use_tls'] as bool? ?? true,
    );
  }

  final String id;
  final VaultItemKind kind;
  final String address;
  final String displayName;
  final String provider;
  final String username;
  final String secret;
  final String refreshToken;
  final DateTime? tokenExpiresAt;
  final String tokenScope;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final bool useTls;

  VaultMailboxItem copyWith({
    String? id,
    VaultItemKind? kind,
    String? address,
    String? displayName,
    String? provider,
    String? username,
    String? secret,
    String? refreshToken,
    DateTime? tokenExpiresAt,
    String? tokenScope,
    String? imapHost,
    int? imapPort,
    String? smtpHost,
    int? smtpPort,
    bool? useTls,
  }) {
    return VaultMailboxItem(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      address: address ?? this.address,
      displayName: displayName ?? this.displayName,
      provider: provider ?? this.provider,
      username: username ?? this.username,
      secret: secret ?? this.secret,
      refreshToken: refreshToken ?? this.refreshToken,
      tokenExpiresAt: tokenExpiresAt ?? this.tokenExpiresAt,
      tokenScope: tokenScope ?? this.tokenScope,
      imapHost: imapHost ?? this.imapHost,
      imapPort: imapPort ?? this.imapPort,
      smtpHost: smtpHost ?? this.smtpHost,
      smtpPort: smtpPort ?? this.smtpPort,
      useTls: useTls ?? this.useTls,
    );
  }

  MailboxCredential toCredential() {
    return MailboxCredential(
      accountId: id,
      address: address,
      displayName: displayName,
      imapHost: imapHost,
      imapPort: imapPort,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      username: username,
      secret: secret,
      authType:
          kind == VaultItemKind.oauth
              ? MailboxAuthType.oauth2
              : MailboxAuthType.password,
      useTls: useTls,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind == VaultItemKind.oauth ? 'oauth' : 'imap_smtp',
    'address': address,
    'display_name': displayName,
    'provider': provider,
    'username': username,
    'secret': secret,
    if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
    if (tokenExpiresAt != null)
      'token_expires_at': tokenExpiresAt!.toUtc().toIso8601String(),
    if (tokenScope.isNotEmpty) 'token_scope': tokenScope,
    'imap_host': imapHost,
    'imap_port': imapPort,
    'smtp_host': smtpHost,
    'smtp_port': smtpPort,
    'use_tls': useTls,
  };
}
