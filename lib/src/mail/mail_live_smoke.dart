import 'dart:convert';

import 'mail_models.dart';
import 'mail_provider_probe.dart';
import 'mail_transport.dart';
import 'mailbox_diagnostics.dart';

enum MailLiveSmokeMode { validate, roundtrip }

class MailLiveSmokeConfig {
  const MailLiveSmokeConfig({
    required this.providerConfig,
    required this.mode,
    required this.token,
    this.recipient = '',
    this.expectInboxDelivery = false,
    this.fetchLimit = 20,
    this.pollAttempts = 6,
    this.pollInterval = const Duration(seconds: 5),
    this.subjectPrefix = 'NyaMail live smoke',
    this.includeAttachment = false,
    this.attachmentFilename = 'nyamail-smoke-attachment.txt',
  });

  final MailProviderProbeConfig providerConfig;
  final MailLiveSmokeMode mode;
  final String recipient;
  final bool expectInboxDelivery;
  final int fetchLimit;
  final int pollAttempts;
  final Duration pollInterval;
  final String subjectPrefix;
  final bool includeAttachment;
  final String attachmentFilename;
  final String token;

  MailboxCredential toCredential() => providerConfig.toCredential();

  String get subject => '$subjectPrefix $token'.trim();

  List<String> validate() {
    final errors = providerConfig.validate();
    if (mode == MailLiveSmokeMode.roundtrip && recipient.trim().isEmpty) {
      errors.add('recipient is required for roundtrip mode');
    }
    if (includeAttachment && mode != MailLiveSmokeMode.roundtrip) {
      errors.add('include attachment requires roundtrip mode');
    }
    final trimmedAttachmentFilename = attachmentFilename.trim();
    if (includeAttachment && trimmedAttachmentFilename.isEmpty) {
      errors.add('attachment filename is required when attachment is enabled');
    }
    if (includeAttachment &&
        RegExp(r'[\r\n\\/:*?"<>|]').hasMatch(trimmedAttachmentFilename)) {
      errors.add(
        'attachment filename cannot contain path or control characters',
      );
    }
    if (token.trim().isEmpty) {
      errors.add('token is required');
    }
    if (fetchLimit <= 0) {
      errors.add('fetch limit must be greater than zero');
    }
    if (pollAttempts <= 0) {
      errors.add('poll attempts must be greater than zero');
    }
    if (pollInterval.isNegative) {
      errors.add('poll interval cannot be negative');
    }
    return errors;
  }

  Map<String, Object?> toRedactedJson() {
    return {
      'mode': mode.name,
      'provider': providerConfig.toRedactedJson(),
      'recipient': recipient,
      'expect_inbox_delivery': expectInboxDelivery,
      'fetch_limit': fetchLimit,
      'poll_attempts': pollAttempts,
      'poll_interval_ms': pollInterval.inMilliseconds,
      'subject_prefix': subjectPrefix,
      'include_attachment': includeAttachment,
      'attachment_filename': attachmentFilename.trim(),
      if (includeAttachment) 'attachment_size': smokeAttachmentSize(this),
      'token': token,
    };
  }
}

class MailLiveSmokeStep {
  const MailLiveSmokeStep({
    required this.name,
    required this.ok,
    required this.elapsed,
    this.detail,
    this.diagnostic,
  });

  final String name;
  final bool ok;
  final Duration elapsed;
  final String? detail;
  final String? diagnostic;

  Map<String, Object?> toJson() {
    return {
      'name': name,
      'ok': ok,
      'elapsed_ms': elapsed.inMilliseconds,
      if (detail != null) 'detail': detail,
      if (diagnostic != null) 'diagnostic': diagnostic,
    };
  }
}

class MailLiveSmokeResult {
  const MailLiveSmokeResult({
    required this.ok,
    required this.config,
    required this.elapsed,
    required this.steps,
    this.diagnostic,
  });

  final bool ok;
  final MailLiveSmokeConfig config;
  final Duration elapsed;
  final List<MailLiveSmokeStep> steps;
  final String? diagnostic;

  Map<String, Object?> toJson() {
    return {
      'ok': ok,
      'elapsed_ms': elapsed.inMilliseconds,
      'config': config.toRedactedJson(),
      'steps': steps.map((step) => step.toJson()).toList(),
      if (diagnostic != null) 'diagnostic': diagnostic,
    };
  }
}

class MailLiveSmoke {
  const MailLiveSmoke({
    this.transport = const SocketMailTransport(),
    this.diagnostics = const MailboxSetupDiagnostics(),
  });

  final MailTransport transport;
  final MailboxSetupDiagnostics diagnostics;

  Future<MailLiveSmokeResult> run(MailLiveSmokeConfig config) async {
    final total = Stopwatch()..start();
    final errors = config.validate();
    if (errors.isNotEmpty) {
      total.stop();
      return MailLiveSmokeResult(
        ok: false,
        config: config,
        elapsed: total.elapsed,
        steps: const [],
        diagnostic:
            'Invalid live smoke configuration:\n- ${errors.join('\n- ')}',
      );
    }

    final credential = config.toCredential();
    final steps = <MailLiveSmokeStep>[];

    Future<bool> record(String name, Future<String> Function() action) async {
      final stepWatch = Stopwatch()..start();
      try {
        final detail = await action();
        stepWatch.stop();
        steps.add(
          MailLiveSmokeStep(
            name: name,
            ok: true,
            elapsed: stepWatch.elapsed,
            detail: detail,
          ),
        );
        return true;
      } catch (error) {
        stepWatch.stop();
        steps.add(
          MailLiveSmokeStep(
            name: name,
            ok: false,
            elapsed: stepWatch.elapsed,
            diagnostic: diagnostics.message(
              provider: config.providerConfig.provider,
              credential: credential,
              error: error,
            ),
          ),
        );
        return false;
      }
    }

    Future<MailLiveSmokeResult> finish(bool ok) async {
      total.stop();
      return MailLiveSmokeResult(
        ok: ok,
        config: config,
        elapsed: total.elapsed,
        steps: List.unmodifiable(steps),
      );
    }

    if (!await record('validate_credential', () async {
      await transport.validateCredential(credential: credential);
      return 'IMAP and SMTP authentication succeeded.';
    })) {
      return finish(false);
    }

    if (!await record('fetch_inbox', () async {
      final messages = await transport.fetchMessages(
        credential: credential,
        mailbox: MailboxKind.inbox,
        limit: config.fetchLimit,
      );
      return 'Fetched ${messages.length} inbox message(s).';
    })) {
      return finish(false);
    }

    if (config.mode == MailLiveSmokeMode.validate) {
      return finish(true);
    }

    final attachment =
        config.includeAttachment ? smokeAttachmentForConfig(config) : null;
    final outgoing = OutgoingMessage(
      from: credential.address,
      to: [config.recipient.trim()],
      subject: config.subject,
      textBody: [
        'NyaMail live mailbox smoke.',
        'Token: ${config.token}',
        'Generated at: ${DateTime.now().toUtc().toIso8601String()}',
        'This message was sent by an explicit roundtrip smoke test.',
      ].join('\n'),
      attachments: attachment == null ? const [] : [attachment],
    );

    if (!await record('send_roundtrip_message', () async {
      await transport.send(credential: credential, message: outgoing);
      final attachmentDetail =
          attachment == null
              ? ''
              : ' with attachment ${attachment.filename} '
                  '(${attachment.bytes.length} byte(s))';
      return 'Sent roundtrip message to ${config.recipient.trim()}'
          '$attachmentDetail.';
    })) {
      return finish(false);
    }

    if (!await record('verify_sent', () async {
      final match = await _pollForToken(
        credential: credential,
        mailbox: MailboxKind.sent,
        config: config,
      );
      if (match == null) {
        throw MailTransportException(
          'Could not find smoke token ${config.token} in Sent after '
          '${config.pollAttempts} attempt(s).',
        );
      }
      final attachmentDetail =
          config.includeAttachment
              ? ' ${_verifyExpectedAttachment(match, config)}'
              : '';
      return 'Found sent message ${match.id}.$attachmentDetail';
    })) {
      return finish(false);
    }

    if (config.expectInboxDelivery) {
      if (!await record('verify_inbox_delivery', () async {
        final match = await _pollForToken(
          credential: credential,
          mailbox: MailboxKind.inbox,
          config: config,
        );
        if (match == null) {
          throw MailTransportException(
            'Could not find smoke token ${config.token} in Inbox after '
            '${config.pollAttempts} attempt(s).',
          );
        }
        final attachmentDetail =
            config.includeAttachment
                ? ' ${_verifyExpectedAttachment(match, config)}'
                : '';
        return 'Found inbox message ${match.id}.$attachmentDetail';
      })) {
        return finish(false);
      }
    }

    return finish(true);
  }

  Future<MailMessage?> _pollForToken({
    required MailboxCredential credential,
    required MailboxKind mailbox,
    required MailLiveSmokeConfig config,
  }) async {
    for (var attempt = 0; attempt < config.pollAttempts; attempt += 1) {
      final messages = await transport.fetchMessages(
        credential: credential,
        mailbox: mailbox,
        limit: config.fetchLimit,
      );
      final match =
          messages
              .where(
                (message) => mailMessageMatchesQuery(message, config.token),
              )
              .firstOrNull;
      if (match != null) return match;
      if (attempt + 1 < config.pollAttempts &&
          config.pollInterval > Duration.zero) {
        await Future<void>.delayed(config.pollInterval);
      }
    }
    return null;
  }
}

const String smokeAttachmentContentType = 'text/plain';

OutgoingAttachment smokeAttachmentForConfig(MailLiveSmokeConfig config) {
  final filename = config.attachmentFilename.trim();
  return OutgoingAttachment(
    filename: filename,
    contentType: smokeAttachmentContentType,
    bytes: _smokeAttachmentBytes(config, filename),
  );
}

int smokeAttachmentSize(MailLiveSmokeConfig config) {
  return smokeAttachmentForConfig(config).bytes.length;
}

List<int> _smokeAttachmentBytes(MailLiveSmokeConfig config, String filename) {
  return utf8.encode(
    [
      'NyaMail live smoke attachment.',
      'Token: ${config.token}',
      'Filename: $filename',
      'Do not keep this message after provider verification.',
    ].join('\n'),
  );
}

String _verifyExpectedAttachment(
  MailMessage message,
  MailLiveSmokeConfig config,
) {
  final expected = smokeAttachmentForConfig(config);
  if (!message.hasAttachments || message.attachments.isEmpty) {
    throw MailTransportException(
      'Expected attachment ${expected.filename} on message ${message.id}, '
      'but no attachment metadata was parsed.',
    );
  }
  final match =
      message.attachments
          .where((attachment) => attachment.filename == expected.filename)
          .firstOrNull;
  if (match == null) {
    throw MailTransportException(
      'Expected attachment ${expected.filename} on message ${message.id}, '
      'but found: ${message.attachments.map((a) => a.filename).join(', ')}.',
    );
  }
  if (match.contentType.toLowerCase() != expected.contentType) {
    throw MailTransportException(
      'Expected attachment ${expected.filename} content type '
      '${expected.contentType}, got ${match.contentType}.',
    );
  }
  if (match.size != expected.bytes.length) {
    throw MailTransportException(
      'Expected attachment ${expected.filename} size '
      '${expected.bytes.length}, got ${match.size ?? 'unknown'}.',
    );
  }
  return 'Verified attachment ${match.filename} '
      '(${match.contentType}, ${match.size} byte(s)).';
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
