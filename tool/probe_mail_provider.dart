import 'dart:convert';
import 'dart:io';

import 'package:nyamail/src/mail/mail_provider_probe.dart';
import 'package:nyamail/src/mail/mail_transport.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options.containsKey('help')) {
    _usage();
    return;
  }

  final secretEnv = options['secret-env'];
  final secret = options['secret'] ??
      (secretEnv == null ? null : Platform.environment[secretEnv]);
  final address = options['address'];
  if (address == null || secret == null) {
    _usage();
    exitCode = 64;
    return;
  }

  final config = MailProviderProbeConfig.fromProvider(
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
  final result = await const MailProviderProbe().run(config);
  if (options['json'] == 'true') {
    const encoder = JsonEncoder.withIndent('  ');
    stdout.writeln(encoder.convert(result.toJson()));
  } else if (result.ok) {
    stdout.writeln('Mail provider probe succeeded.');
    stdout.writeln(_redactedSummary(config));
    stdout.writeln('Elapsed: ${result.elapsed.inMilliseconds} ms');
  } else {
    stderr.writeln('Mail provider probe failed.');
    stderr.writeln(_redactedSummary(config));
    stderr.writeln(result.diagnostic);
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
    if (raw == 'help') {
      values[raw] = 'true';
      continue;
    }
    if (raw == 'json') {
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

String _redactedSummary(MailProviderProbeConfig config) {
  return [
    'Provider: ${config.provider}',
    'Address: ${config.address}',
    'Username: ${config.username}',
    'Auth: ${config.authType.name}',
    'IMAP: ${config.imapHost}:${config.imapPort}',
    'SMTP: ${config.smtpHost}:${config.smtpPort}',
    'TLS: ${config.useTls}',
    'Secret: ${config.secret.isEmpty ? 'missing' : 'redacted'}',
  ].join('\n');
}

MailboxAuthType _authTypeOption(String? value) {
  return value?.trim().toLowerCase() == 'oauth2'
      ? MailboxAuthType.oauth2
      : MailboxAuthType.password;
}

void _usage() {
  stdout.writeln('''
Usage:
  dart run tool/probe_mail_provider.dart --provider gmail --address me@gmail.com --secret-env NYAMAIL_MAIL_SECRET

Options:
  --provider gmail|outlook|icloud|imap
  --address <mailbox address>
  --username <login username, defaults to address>
  --auth password|oauth2                Defaults to password.
  --secret <app password/token>          Avoid this in shell history when possible.
  --secret-env <environment variable>    Preferred for local probes.
  --imap-host <host> --imap-port <port>
  --smtp-host <host> --smtp-port <port>
  --tls true|false
  --json
''');
}
