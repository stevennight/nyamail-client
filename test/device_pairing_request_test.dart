import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/security/device_pairing_request.dart';

void main() {
  test('pairing request round trips encoded package', () {
    final request = DevicePairingRequest.forDevice(
      userId: 'usr_1',
      device: _device(),
    );

    final decoded = DevicePairingRequest.decode(request.encode());

    expect(request.encode(), startsWith(DevicePairingRequest.prefix));
    expect(request.encode(), isNot(contains('signing-key')));
    expect(request.encode(), isNot(contains('Android phone')));
    expect(decoded.userId, 'usr_1');
    expect(decoded.device.id, 'dev_2');
    expect(decoded.device.publicKey, 'signing-key');
    expect(decoded.device.keyAgreementPublicKey, 'box-key');
    expect(decoded.pairingCode, request.pairingCode);
  });

  test('pairing request decodes json package for QR and clipboard use', () {
    final request = DevicePairingRequest.forDevice(
      userId: 'usr_1',
      device: _device(),
    );

    final decoded = DevicePairingRequest.decode(jsonEncode(request.toJson()));

    expect(decoded.pairingCode, request.pairingCode);
  });

  test('pairing request rejects tampered pairing code', () {
    final request = DevicePairingRequest.forDevice(
      userId: 'usr_1',
      device: _device(),
    );
    final json = request.toJson();
    json['pairing_code'] = '0000-0000';

    expect(
      () => DevicePairingRequest.decode(jsonEncode(json)),
      throwsA(isA<DevicePairingRequestException>()),
    );
  });

  test('pairing request rejects missing prefix', () {
    expect(
      () => DevicePairingRequest.decode('not-a-package'),
      throwsA(isA<DevicePairingRequestException>()),
    );
  });
}

DeviceSummary _device() {
  return const DeviceSummary(
    id: 'dev_2',
    name: 'Android phone',
    platform: 'android',
    publicKey: 'signing-key',
    keyAgreementPublicKey: 'box-key',
    trusted: false,
  );
}
