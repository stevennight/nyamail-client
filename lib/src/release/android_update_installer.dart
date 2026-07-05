import 'dart:io' show File;

import 'package:flutter/services.dart';

class AndroidUpdateInstaller {
  const AndroidUpdateInstaller();

  static const _channel = MethodChannel('app.nyamail.client/update_installer');

  Future<void> installApk(File file) async {
    if (!file.path.toLowerCase().endsWith('.apk')) {
      throw StateError('Android update artifact is not an APK: ${file.path}');
    }
    await _channel.invokeMethod<void>('installApk', {'path': file.path});
  }
}

bool shouldUseAndroidPackageInstaller({
  required bool isAndroid,
  required String path,
}) {
  return isAndroid && path.toLowerCase().endsWith('.apk');
}
