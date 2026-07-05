import 'dart:convert';
import 'dart:io';

import 'package:nyamail/src/oauth/oauth_loopback_client.dart';
import 'package:nyamail/src/oauth/oauth_provider.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options.containsKey('help')) {
    _usage();
    return;
  }
  final providerName = options['provider'];
  final clientId = options['client-id'] ??
      (options['client-id-env'] == null
          ? null
          : Platform.environment[options['client-id-env']]);
  final clientSecret = options['client-secret'] ??
      (options['client-secret-env'] == null
          ? null
          : Platform.environment[options['client-secret-env']]);
  if (providerName == null || clientId == null || clientId.trim().isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }

  try {
    final provider = oauthProviderConfig(providerName);
    final tokenSet = await OAuthLoopbackClient().authorize(
      provider: provider,
      clientId: clientId.trim(),
      clientSecret: clientSecret,
      loginHint: options['login-hint'],
    );
    const encoder = JsonEncoder.withIndent('  ');
    stdout.writeln(encoder.convert({
      'ok': true,
      'provider': provider.provider,
      'token': tokenSet.toRedactedJson(),
      'imap_host': provider.imapHost,
      'imap_port': provider.imapPort,
      'smtp_host': provider.smtpHost,
      'smtp_port': provider.smtpPort,
    }));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
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

void _usage() {
  stdout.writeln('''
Usage:
  dart run tool/oauth_authorize.dart --provider gmail --client-id-env NYAMAIL_GMAIL_CLIENT_ID --login-hint me@gmail.com

Options:
  --provider gmail|outlook
  --client-id <oauth client id>
  --client-id-env <environment variable>
  --client-secret <oauth client secret>
  --client-secret-env <environment variable>
  --login-hint <email address>
''');
}
