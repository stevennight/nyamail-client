import 'mail_models.dart';

class MailNotificationBaseline {
  final Set<String> _knownIncomingUnreadMessageIds = <String>{};
  bool _ready = false;
  bool _startupPending = true;

  bool get ready => _ready;
  bool get startupPending => _startupPending;

  void reset() {
    _knownIncomingUnreadMessageIds.clear();
    _ready = false;
    _startupPending = true;
  }

  void prime(Iterable<MailMessage> incomingUnread) {
    for (final message in incomingUnread) {
      _knownIncomingUnreadMessageIds.add(message.id);
    }
    _ready = true;
  }

  List<MailMessage> freshMessages(
    Iterable<MailMessage> incomingUnread, {
    bool completeStartupBaseline = false,
  }) {
    final messages = incomingUnread.toList();
    if (!_ready || _startupPending) {
      prime(messages);
      if (completeStartupBaseline) {
        _startupPending = false;
      }
      return const [];
    }
    final fresh = <MailMessage>[];
    for (final message in messages) {
      if (_knownIncomingUnreadMessageIds.add(message.id)) {
        fresh.add(message);
      }
    }
    return fresh;
  }
}
