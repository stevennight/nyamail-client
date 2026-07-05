import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto_graphy;

import '../api/models.dart';
import 'vault_share_crypto.dart';

class DeviceApprovalCrypto {
  const DeviceApprovalCrypto({
    crypto_graphy.Ed25519? algorithm,
  }) : _algorithm = algorithm;

  static const deviceApprovalVersion = 'nyamail-device-approval-v1';
  static const vaultShareApprovalVersion = 'nyamail-vault-share-approval-v1';

  final crypto_graphy.Ed25519? _algorithm;

  Future<String> signDeviceApproval({
    required String userId,
    required DeviceSummary fromDevice,
    required DeviceSummary toDevice,
    required String privateKey,
  }) {
    return _sign(
      payload: _deviceApprovalPayload(
        userId: userId,
        fromDevice: fromDevice,
        toDevice: toDevice,
      ),
      privateKey: privateKey,
    );
  }

  Future<String> signVaultShareApproval({
    required String userId,
    required DeviceSummary fromDevice,
    required DeviceSummary toDevice,
    required VaultSharePayload share,
    required String pairingCode,
    required String privateKey,
  }) {
    return _sign(
      payload: _vaultShareApprovalPayload(
        userId: userId,
        fromDevice: fromDevice,
        toDevice: toDevice,
        share: share,
        pairingCode: pairingCode,
      ),
      privateKey: privateKey,
    );
  }

  Future<String> _sign({
    required String payload,
    required String privateKey,
  }) async {
    final algorithm = _algorithm ?? crypto_graphy.Ed25519();
    final keyPair =
        await algorithm.newKeyPairFromSeed(_decodeBytes(privateKey));
    final signature = await algorithm.sign(
      utf8.encode(payload),
      keyPair: keyPair,
    );
    return base64Encode(signature.bytes);
  }

  String _deviceApprovalPayload({
    required String userId,
    required DeviceSummary fromDevice,
    required DeviceSummary toDevice,
  }) {
    return [
      deviceApprovalVersion,
      userId,
      fromDevice.id,
      fromDevice.publicKey,
      toDevice.id,
      toDevice.publicKey,
      toDevice.keyAgreementPublicKey,
    ].join('\n');
  }

  String _vaultShareApprovalPayload({
    required String userId,
    required DeviceSummary fromDevice,
    required DeviceSummary toDevice,
    required VaultSharePayload share,
    required String pairingCode,
  }) {
    return [
      vaultShareApprovalVersion,
      userId,
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
  }

  List<int> _decodeBytes(String value) {
    try {
      return base64.decode(value);
    } on FormatException catch (error) {
      throw DeviceApprovalCryptoException(
        'device signing key is invalid: ${error.message}',
      );
    }
  }
}

class DeviceApprovalCryptoException implements Exception {
  const DeviceApprovalCryptoException(this.message);

  final String message;

  @override
  String toString() => 'DeviceApprovalCryptoException: $message';
}
