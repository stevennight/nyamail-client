import 'mail_transport.dart';
import 'mailbox_diagnostics.dart';
import 'provider_presets.dart';

class MailProviderProbeConfig {
  const MailProviderProbeConfig({
    required this.provider,
    required this.address,
    required this.username,
    required this.secret,
    required this.imapHost,
    required this.imapPort,
    required this.smtpHost,
    required this.smtpPort,
    required this.authType,
    required this.useTls,
  });

  factory MailProviderProbeConfig.fromProvider({
    required String provider,
    required String address,
    required String secret,
    String? username,
    String? imapHost,
    int? imapPort,
    String? smtpHost,
    int? smtpPort,
    MailboxAuthType authType = MailboxAuthType.password,
    bool? useTls,
  }) {
    final normalizedProvider =
        provider.trim().isEmpty ? 'imap' : provider.trim().toLowerCase();
    final normalizedAddress = address.trim();
    final preset = presetForProvider(normalizedProvider, normalizedAddress);
    return MailProviderProbeConfig(
      provider: preset.provider,
      address: normalizedAddress,
      username: username?.trim().isNotEmpty == true
          ? username!.trim()
          : normalizedAddress,
      secret: secret,
      imapHost: imapHost?.trim().isNotEmpty == true
          ? imapHost!.trim()
          : preset.imapHost,
      imapPort: imapPort ?? preset.imapPort,
      smtpHost: smtpHost?.trim().isNotEmpty == true
          ? smtpHost!.trim()
          : preset.smtpHost,
      smtpPort: smtpPort ?? preset.smtpPort,
      authType: authType,
      useTls: useTls ?? preset.useTls,
    );
  }

  final String provider;
  final String address;
  final String username;
  final String secret;
  final String imapHost;
  final int imapPort;
  final String smtpHost;
  final int smtpPort;
  final MailboxAuthType authType;
  final bool useTls;

  MailboxCredential toCredential() {
    return MailboxCredential(
      accountId: 'provider-probe',
      address: address,
      displayName: address,
      imapHost: imapHost,
      imapPort: imapPort,
      smtpHost: smtpHost,
      smtpPort: smtpPort,
      username: username,
      secret: secret,
      authType: authType,
      useTls: useTls,
    );
  }

  List<String> validate() {
    return [
      if (address.isEmpty) 'address is required',
      if (username.isEmpty) 'username is required',
      if (secret.isEmpty) 'secret is required',
      if (imapHost.isEmpty) 'imap host is required',
      if (smtpHost.isEmpty) 'smtp host is required',
      if (imapPort <= 0 || imapPort > 65535) 'imap port is invalid',
      if (smtpPort <= 0 || smtpPort > 65535) 'smtp port is invalid',
    ];
  }

  Map<String, Object?> toRedactedJson() {
    return {
      'provider': provider,
      'address': address,
      'username': username,
      'secret': secret.isEmpty ? 'missing' : 'redacted',
      'imap_host': imapHost,
      'imap_port': imapPort,
      'smtp_host': smtpHost,
      'smtp_port': smtpPort,
      'auth_type': authType.name,
      'use_tls': useTls,
    };
  }
}

class MailProviderProbeResult {
  const MailProviderProbeResult({
    required this.ok,
    required this.config,
    required this.elapsed,
    this.diagnostic,
  });

  final bool ok;
  final MailProviderProbeConfig config;
  final Duration elapsed;
  final String? diagnostic;

  Map<String, Object?> toJson() {
    return {
      'ok': ok,
      'elapsed_ms': elapsed.inMilliseconds,
      'config': config.toRedactedJson(),
      if (diagnostic != null) 'diagnostic': diagnostic,
    };
  }
}

class MailProviderProbe {
  const MailProviderProbe({
    this.transport = const SocketMailTransport(),
    this.diagnostics = const MailboxSetupDiagnostics(),
  });

  final MailTransport transport;
  final MailboxSetupDiagnostics diagnostics;

  Future<MailProviderProbeResult> run(MailProviderProbeConfig config) async {
    final stopwatch = Stopwatch()..start();
    final errors = config.validate();
    if (errors.isNotEmpty) {
      stopwatch.stop();
      return MailProviderProbeResult(
        ok: false,
        config: config,
        elapsed: stopwatch.elapsed,
        diagnostic: 'Invalid probe configuration:\n- ${errors.join('\n- ')}',
      );
    }

    try {
      await transport.validateCredential(credential: config.toCredential());
      stopwatch.stop();
      return MailProviderProbeResult(
        ok: true,
        config: config,
        elapsed: stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      return MailProviderProbeResult(
        ok: false,
        config: config,
        elapsed: stopwatch.elapsed,
        diagnostic: diagnostics.message(
          provider: config.provider,
          credential: config.toCredential(),
          error: error,
        ),
      );
    }
  }
}
