import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

class LocalVaultAuthenticator {
  LocalVaultAuthenticator({LocalAuthentication? auth})
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  String get methodLabel {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android biometrics or device lock';
      case TargetPlatform.iOS:
        return 'Face ID, Touch ID, or device passcode';
      case TargetPlatform.macOS:
        return 'Touch ID or macOS password';
      case TargetPlatform.windows:
        return 'Windows Hello';
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return 'system unlock';
    }
  }

  Future<bool> authenticate({required String reason}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
