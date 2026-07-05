import 'dart:convert';

import '../api/models.dart';
import 'device_pairing_code.dart';

class DevicePairingRequest {
  const DevicePairingRequest({
    required this.userId,
    required this.device,
    required this.pairingCode,
  });

  factory DevicePairingRequest.forDevice({
    required String userId,
    required DeviceSummary device,
  }) {
    return DevicePairingRequest(
      userId: userId,
      device: device,
      pairingCode: const DevicePairingCode().codeFor(
        userId: userId,
        device: device,
      ),
    );
  }

  factory DevicePairingRequest.decode(String value) {
    final raw = value.trim();
    if (raw.isEmpty) {
      throw const DevicePairingRequestException('pairing package is empty');
    }
    final jsonText = raw.startsWith('{')
        ? raw
        : utf8.decode(
            base64Url.decode(base64Url.normalize(_stripPrefix(raw))),
          );
    final json = (jsonDecode(jsonText) as Map).cast<String, Object?>();
    final version = json['version'] as String? ?? '';
    if (version != versionName) {
      throw DevicePairingRequestException(
        'unsupported pairing package version: $version',
      );
    }
    final userId = json['user_id'] as String? ?? '';
    final deviceJson =
        (json['device'] as Map?)?.cast<String, Object?>() ?? const {};
    final device = DeviceSummary.fromJson({
      ...deviceJson,
      'trusted': false,
    });
    final pairingCode = const DevicePairingCode()
        .normalize(json['pairing_code'] as String? ?? '');
    _validate(userId: userId, device: device, pairingCode: pairingCode);
    return DevicePairingRequest(
      userId: userId,
      device: device,
      pairingCode: pairingCode,
    );
  }

  static const prefix = 'nyamail-pairing-v1.';
  static const versionName = 'nyamail-device-pairing-request-v1';

  final String userId;
  final DeviceSummary device;
  final String pairingCode;

  String encode() {
    final jsonText = jsonEncode(toJson());
    return '$prefix${base64Url.encode(utf8.encode(jsonText)).replaceAll('=', '')}';
  }

  Map<String, Object?> toJson() {
    return {
      'version': versionName,
      'user_id': userId,
      'pairing_code': pairingCode,
      'device': {
        'id': device.id,
        'name': device.name,
        'platform': device.platform,
        'public_key': device.publicKey,
        'key_agreement_public_key': device.keyAgreementPublicKey,
      },
    };
  }

  static String _stripPrefix(String value) {
    if (!value.startsWith(prefix)) {
      throw const DevicePairingRequestException(
        'pairing package prefix is invalid',
      );
    }
    return value.substring(prefix.length);
  }

  static void _validate({
    required String userId,
    required DeviceSummary device,
    required String pairingCode,
  }) {
    if (userId.isEmpty) {
      throw const DevicePairingRequestException('pairing user id is missing');
    }
    if (device.id.isEmpty ||
        device.publicKey.isEmpty ||
        device.keyAgreementPublicKey.isEmpty) {
      throw const DevicePairingRequestException(
        'pairing device keys are missing',
      );
    }
    final expected = const DevicePairingCode().codeFor(
      userId: userId,
      device: device,
    );
    if (pairingCode != expected) {
      throw const DevicePairingRequestException(
        'pairing code does not match device keys',
      );
    }
  }
}

class DevicePairingRequestException implements Exception {
  const DevicePairingRequestException(this.message);

  final String message;

  @override
  String toString() => 'DevicePairingRequestException: $message';
}
