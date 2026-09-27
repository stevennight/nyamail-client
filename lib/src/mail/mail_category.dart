/// Who a message comes from, in the sense of Spark's Smart Inbox: a person,
/// an automated service, or a subscription.
enum MailCategory { people, notification, newsletter }

const _newsletterWords = [
  'newsletter',
  'digest',
  'weekly',
  'marketing',
  'promo',
  'deals',
  'offers',
  'news',
];

const _automatedWords = [
  'noreply',
  'no-reply',
  'no_reply',
  'donotreply',
  'do-not-reply',
  'do_not_reply',
  'notification',
  'notify',
  'alert',
  'mailer-daemon',
  'postmaster',
  'security',
  'account',
  'billing',
  'invoice',
  'receipt',
  'order',
  'shipment',
  'shipping',
  'tracking',
  'service',
  'system',
  'automated',
  'bounce',
];

/// Classifies a message from its sender and, when available, its raw headers
/// (lower-case names). Signals checked, strongest first:
///
/// * newsletter words in the sender name or mailbox (`digest`, `newsletter`);
/// * `Auto-Submitted` (RFC 3834) or an automated-looking sender mailbox
///   (`noreply`, `notifications`, `billing`, ...) -> notification;
/// * `List-Unsubscribe` or `Precedence: bulk` -> newsletter.
///
/// Anything else is treated as a person.
MailCategory classifyMailCategory({
  required String from,
  Map<String, String> headers = const {},
}) {
  final address = _senderAddress(from).toLowerCase();
  final at = address.indexOf('@');
  final localPart = at < 0 ? address : address.substring(0, at);
  final name = _senderName(from).toLowerCase();

  bool hasWord(String text, List<String> words) {
    if (text.isEmpty) return false;
    final tokens = text.split(RegExp(r'[^a-z0-9]+'));
    for (final word in words) {
      if (RegExp(r'[-_]').hasMatch(word)) {
        if (text.contains(word)) return true;
        continue;
      }
      for (final token in tokens) {
        if (token == word ||
            token == '${word}s' ||
            (word.length >= 6 && token.startsWith(word))) {
          return true;
        }
      }
    }
    return false;
  }

  if (hasWord(localPart, _newsletterWords) || hasWord(name, _newsletterWords)) {
    return MailCategory.newsletter;
  }
  final autoSubmitted = (headers['auto-submitted'] ?? '').trim().toLowerCase();
  if ((autoSubmitted.isNotEmpty && autoSubmitted != 'no') ||
      hasWord(localPart, _automatedWords)) {
    return MailCategory.notification;
  }
  final precedence = (headers['precedence'] ?? '').trim().toLowerCase();
  if ((headers['list-unsubscribe'] ?? '').trim().isNotEmpty ||
      precedence == 'bulk' ||
      precedence == 'junk') {
    return MailCategory.newsletter;
  }
  return MailCategory.people;
}

MailCategory? mailCategoryFromName(String? name) {
  for (final category in MailCategory.values) {
    if (category.name == name) return category;
  }
  return null;
}

String _senderAddress(String from) {
  final match = RegExp(r'<([^>]+)>').firstMatch(from);
  return (match?.group(1) ?? from).trim();
}

String _senderName(String from) {
  final index = from.indexOf('<');
  if (index <= 0) return '';
  return from.substring(0, index).replaceAll('"', '').trim();
}
