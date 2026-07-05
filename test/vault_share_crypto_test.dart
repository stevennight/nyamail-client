import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto_graphy;
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/security/device_approval_crypto.dart';
import 'package:nyamail/src/security/device_pairing_code.dart';
import 'package:nyamail/src/security/vault_share_crypto.dart';

void main() {
  test('vault share encrypts for recipient x25519 key', () async {
    const crypto = VaultShareCrypto();
    final keyAgreement = crypto_graphy.X25519();
    final recipientKeyPair = await keyAgreement.newKeyPair();
    final recipientPrivateKey = await recipientKeyPair.extractPrivateKeyBytes();
    final recipientPublicKey = await recipientKeyPair.extractPublicKey();

    final payload = await crypto.encryptForDevice(
      recipientPublicKey: base64Encode(recipientPublicKey.bytes),
      plaintext: 'vault-secret',
    );
    final share = VaultShare(
      id: 'vsh_1',
      fromDeviceId: 'dev_1',
      toDeviceId: 'dev_2',
      senderPublicKey: payload.senderPublicKey,
      algorithm: payload.algorithm,
      nonce: payload.nonce,
      ciphertext: payload.ciphertext,
      mac: payload.mac,
      pairingCode: '',
      approvalVersion: '',
      approvalSignature: '',
    );

    final plaintext = await crypto.decryptFromShare(
      share: share,
      privateKey: base64Encode(recipientPrivateKey),
    );

    expect(payload.algorithm, VaultShareCrypto.algorithm);
    expect(plaintext, 'vault-secret');
  });

  test('device approval signs vault share payload with current device key',
      () async {
    final algorithm = crypto_graphy.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final fromDevice = DeviceSummary(
      id: 'dev_from',
      name: 'Windows',
      platform: 'windows',
      publicKey: base64Encode(publicKey.bytes),
      keyAgreementPublicKey: 'from-box-key',
      trusted: true,
    );
    const toDevice = DeviceSummary(
      id: 'dev_to',
      name: 'Android',
      platform: 'android',
      publicKey: 'to-signing-key',
      keyAgreementPublicKey: 'to-box-key',
      trusted: false,
    );
    const share = VaultSharePayload(
      senderPublicKey: 'ephemeral-sender-key',
      algorithm: VaultShareCrypto.algorithm,
      nonce: 'share-nonce',
      ciphertext: 'encrypted-vault-secret',
      mac: 'share-mac',
    );
    final pairingCode = const DevicePairingCode().codeFor(
      userId: 'usr_1',
      device: toDevice,
    );

    final encodedSignature =
        await const DeviceApprovalCrypto().signVaultShareApproval(
      userId: 'usr_1',
      fromDevice: fromDevice,
      toDevice: toDevice,
      share: share,
      pairingCode: pairingCode,
      privateKey: base64Encode(privateKey),
    );
    final payload = [
      DeviceApprovalCrypto.vaultShareApprovalVersion,
      'usr_1',
      fromDevice.id,
      fromDevice.publicKey,
      toDevice.id,
      toDevice.publicKey,
      toDevice.keyAgreementPublicKey,
      share.senderPublicKey,
      share.algorithm,
      share.nonce,
      share.ciphertext,
      share.mac,
      pairingCode,
    ].join('\n');

    final verified = await algorithm.verify(
      utf8.encode(payload),
      signature: crypto_graphy.Signature(
        base64Decode(encodedSignature),
        publicKey: publicKey,
      ),
    );

    expect(verified, isTrue);
  });

  test('device pairing code is deterministic and normalizes user input', () {
    const device = DeviceSummary(
      id: 'dev_to',
      name: 'Android',
      platform: 'android',
      publicKey: 'to-signing-key',
      keyAgreementPublicKey: 'to-box-key',
      trusted: false,
    );
    const pairing = DevicePairingCode();

    final code = pairing.codeFor(userId: 'usr_1', device: device);

    expect(code, 'K3HA-1M6N');
    expect(pairing.normalize('k3ha 1m6n'), code);
  });
}
