import 'mail_models.dart';

class MailNotificationContent {
  const MailNotificationContent({required this.title, required this.body});

  factory MailNotificationContent.fromMessage(MailMessage message) {
    final sender = _senderLabel(message.from);
    final subject = mailMessageSubjectLabel(message.subject);
    final preview = _singleLine(message.preview);
    return MailNotificationContent(
      title: sender,
      body:
          preview.isEmpty || preview.toLowerCase() == subject.toLowerCase()
              ? subject
              : '$subject\n${_truncate(preview, 240)}',
    );
  }

  final String title;
  final String body;
}

String _senderLabel(String from) {
  final normalized = _singleLine(from);
  if (normalized.isEmpty) return 'Unknown sender';
  final angleAddress = normalized.lastIndexOf('<');
  if (angleAddress <= 0) return normalized;
  final displayName = normalized.substring(0, angleAddress).trim();
  if (displayName.length >= 2 &&
      displayName.startsWith('"') &&
      displayName.endsWith('"')) {
    return displayName.substring(1, displayName.length - 1).trim();
  }
  return displayName.isEmpty ? normalized : displayName;
}

String _singleLine(String value) {
  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _truncate(String value, int maxLength) {
  if (value.length <= maxLength) return value;
  return '${value.substring(0, maxLength - 3).trimRight()}...';
}
