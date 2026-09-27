import 'mail_models.dart';

class MailNotificationBaseline {
  MailNotificationBaseline({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Allowance for provider clocks that run a little behind this device.
  static const _clockSkew = Duration(minutes: 5);

  final DateTime Function() _clock;
  final Set<String> _knownIncomingUnreadMessageIds = <String>{};
  final Map<String, DateTime> _latestReceivedAtByAccount = <String, DateTime>{};
  DateTime? _startedAt;
  bool _ready = false;
  bool _startupPending = true;

  bool get ready => _ready;
  bool get startupPending => _startupPending;

  void reset() {
    _knownIncomingUnreadMessageIds.clear();
    _latestReceivedAtByAccount.clear();
    _startedAt = null;
    _ready = false;
    _startupPending = true;
  }

  void prime(Iterable<MailMessage> incomingUnread) {
    _startedAt ??= _clock().toUtc();
    for (final message in incomingUnread) {
      _knownIncomingUnreadMessageIds.add(message.id);
      _advanceWatermark(message);
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
    final previousWatermarks = Map<String, DateTime>.of(
      _latestReceivedAtByAccount,
    );
    // An account with no unread mail at startup has no watermark yet; mail
    // that arrived after the baseline was taken is still new.
    final startedAt = _startedAt!.subtract(_clockSkew);
    for (final message in messages) {
      final firstSeen = _knownIncomingUnreadMessageIds.add(message.id);
      final watermark = previousWatermarks[message.accountId] ?? startedAt;
      if (firstSeen && message.receivedAt.isAfter(watermark)) {
        fresh.add(message);
      }
      _advanceWatermark(message);
    }
    return fresh;
  }

  void _advanceWatermark(MailMessage message) {
    final current = _latestReceivedAtByAccount[message.accountId];
    if (current == null || message.receivedAt.isAfter(current)) {
      _latestReceivedAtByAccount[message.accountId] = message.receivedAt;
    }
  }
}
