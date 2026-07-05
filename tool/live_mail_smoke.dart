import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:nyamail/src/mail/mail_live_smoke.dart';
import 'package:nyamail/src/mail/mail_provider_probe.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options.containsKey('help')) {
    _usage();
    return;
  }

  final secretEnv = options['secret-env'];
  final secret =
      options['secret'] ??
      (secretEnv == null ? null : Platform.environment[secretEnv]);
  final address = options['address'];
  if (address == null || secret == null) {
    _usage();
    exitCode = 64;
    return;
  }

  final recipient = options['recipient'] ?? '';
  final mode = _modeOption(options['mode']);
  final expectInbox =
      _boolOption(options, 'expect-inbox') ??
      (mode == MailLiveSmokeMode.roundtrip &&
          recipient.trim().toLowerCase() == address.trim().toLowerCase());
  final providerConfig = MailProviderProbeConfig.fromProvider(
    provider: options['provider'] ?? 'imap',
    address: address,
    username: options['username'],
    secret: secret,
    imapHost: options['imap-host'],
    imapPort: _intOption(options, 'imap-port'),
    smtpHost: options['smtp-host'],
    smtpPort: _intOption(options, 'smtp-port'),
    authType: _authTypeOption(options['auth']),
    useTls: _boolOption(options, 'tls'),
  );
  final config = MailLiveSmokeConfig(
    providerConfig: providerConfig,
    mode: mode,
    recipient: recipient,
    expectInboxDelivery: expectInbox,
    fetchLimit: _intOption(options, 'limit') ?? 20,
    pollAttempts: _intOption(options, 'poll-attempts') ?? 6,
    pollInterval: Duration(seconds: _intOption(options, 'poll-seconds') ?? 5),
    subjectPrefix: options['subject-prefix'] ?? 'NyaMail live smoke',
    includeAttachment: _boolOption(options, 'include-attachment') ?? false,
    attachmentFilename:
        options['attachment-name'] ?? 'nyamail-smoke-attachment.txt',
    token: options['token'] ?? _newToken(),
  );

  final result = await const MailLiveSmoke().run(config);
  if (options['json'] == 'true') {
    const encoder = JsonEncoder.withIndent('  ');
    stdout.writeln(encoder.convert(result.toJson()));
  } else if (result.ok) {
    stdout.writeln('Live mail smoke succeeded.');
    stdout.writeln(_redactedSummary(config));
    for (final step in result.steps) {
      stdout.writeln('- ${step.name}: ${step.detail}');
    }
    stdout.writeln('Elapsed: ${result.elapsed.inMilliseconds} ms');
  } else {
    stderr.writeln('Live mail smoke failed.');
    stderr.writeln(_redactedSummary(config));
    if (result.diagnostic != null) {
      stderr.writeln(result.diagnostic);
    }
    for (final step in result.steps) {
      final detail = step.ok ? step.detail : step.diagnostic;
      stderr.writeln('- ${step.name}: ${detail ?? 'failed'}');
    }
  }
  exitCode = result.ok ? 0 : 1;
}

Map<String, String> _parseArgs(List<String> args) {
  final values = <String, String>{};
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (!arg.startsWith('--')) continue;
    final raw = arg.substring(2);
    final equals = raw.indexOf('=');
    if (equals > 0) {
      values[raw.substring(0, equals)] = raw.substring(equals + 1);
      continue;
    }
    if (raw == 'help' || raw == 'json' || raw == 'include-attachment') {
      values[raw] = 'true';
      continue;
    }
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      stderr.writeln('Missing value for --$raw');
      values['help'] = 'true';
      return values;
    }
    values[raw] = args[index + 1];
    index += 1;
  }
  return values;
}

int? _intOption(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) return null;
  return int.tryParse(value.trim());
}

bool? _boolOption(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) return null;
  final normalized = value.trim().toLowerCase();
  if (['1', 'true', 'yes', 'y'].contains(normalized)) return true;
  if (['0', 'false', 'no', 'n'].contains(normalized)) return false;
  return null;
}

MailLiveSmokeMode _modeOption(String? value) {
  return value?.trim().toLowerCase() == 'roundtrip'
      ? MailLiveSmokeMode.roundtrip
      : MailLiveSmokeMode.validate;
}

MailboxAuthType _authTypeOption(String? value) {
  return value?.trim().toLowerCase() == 'oauth2'
      ? MailboxAuthType.oauth2
      : MailboxAuthType.password;
}

String _newToken() {
  final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
  final random = Random.secure().nextInt(1 << 32).toRadixString(16);
  return 'nyamail-smoke-$stamp-${random.padLeft(8, '0')}';
}

String _redactedSummary(MailLiveSmokeConfig config) {
  final provider = config.providerConfig;
  return [
    'Mode: ${config.mode.name}',
    'Provider: ${provider.provider}',
    'Address: ${provider.address}',
    'Username: ${provider.username}',
    'Auth: ${provider.authType.name}',
    'IMAP: ${provider.imapHost}:${provider.imapPort}',
    'SMTP: ${provider.smtpHost}:${provider.smtpPort}',
    'TLS: ${provider.useTls}',
    'Recipient: ${config.recipient.isEmpty ? 'none' : config.recipient}',
    'Expect inbox delivery: ${config.expectInboxDelivery}',
    'Include attachment: ${config.includeAttachment}',
    'Attachment filename: ${config.attachmentFilename}',
    'Token: ${config.token}',
    'Secret: ${provider.secret.isEmpty ? 'missing' : 'redacted'}',
  ].join('\n');
}

void _usage() {
  stdout.writeln('''
Usage:
  dart run tool/live_mail_smoke.dart --provider gmail --address me@gmail.com --secret-env NYAMAIL_MAIL_SECRET
  dart run tool/live_mail_smoke.dart --provider gmail --address me@gmail.com --secret-env NYAMAIL_MAIL_SECRET --mode roundtrip --recipient me@gmail.com

Modes:
  validate    Authenticate IMAP/SMTP and fetch Inbox metadata. Does not send mail.
  roundtrip   Send a uniquely tagged test message, verify it in Sent, and optionally wait for Inbox delivery.

Options:
  --provider gmail|outlook|icloud|imap
  --address <mailbox address>
  --username <login username, defaults to address>
  --auth password|oauth2
  --secret <app password/token>          Avoid this in shell history when possible.
  --secret-env <environment variable>    Preferred for local smoke tests.
  --mode validate|roundtrip              Defaults to validate.
  --recipient <email>                    Required for roundtrip mode.
  --expect-inbox true|false              Defaults to true only when recipient equals address.
  --include-attachment                   Add and verify a generated text attachment in roundtrip mode.
  --attachment-name <filename>           Defaults to nyamail-smoke-attachment.txt.
  --limit <message count>                Defaults to 20.
  --poll-attempts <count>                Defaults to 6.
  --poll-seconds <seconds>               Defaults to 5.
  --subject-prefix <text>
  --token <unique token>
  --imap-host <host> --imap-port <port>
  --smtp-host <host> --smtp-port <port>
  --tls true|false
  --json
''');
}
