import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../api/models.dart';

class DevicePairingCode {
  const DevicePairingCode();

  static const version = 'nyamail-device-pairing-code-v1';
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  String codeFor({
    required String userId,
    required DeviceSummary device,
  }) {
    final payload = [
      version,
      userId,
      device.id,
      device.publicKey,
      device.keyAgreementPublicKey,
    ].join('\n');
    final bytes = sha256.convert(utf8.encode(payload)).bytes;
    final buffer = StringBuffer();
    var bitBuffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      bitBuffer = (bitBuffer << 8) | byte;
      bits += 8;
      while (bits >= 5 && buffer.length < 8) {
        bits -= 5;
        buffer.write(_alphabet[(bitBuffer >> bits) & 31]);
      }
      if (buffer.length == 8) break;
    }
    final raw = buffer.toString();
    return '${raw.substring(0, 4)}-${raw.substring(4)}';
  }

  String normalize(String value) {
    final cleaned = value
        .toUpperCase()
        .replaceAll(RegExp(r'[^0-9A-Z]'), '')
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (cleaned.length <= 4) return cleaned;
    return '${cleaned.substring(0, 4)}-${cleaned.substring(4)}';
  }
}
