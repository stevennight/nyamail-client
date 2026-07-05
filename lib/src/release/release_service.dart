import 'dart:io' show Directory, File, Platform, Process, ProcessStartMode;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/models.dart';
import '../api/nyamail_api.dart';
import 'android_update_installer.dart';
import 'release_verifier.dart';
import 'windows_updater.dart' as updater;

typedef SupportDirectoryProvider = Future<Directory> Function();

class ReleaseService {
  ReleaseService({
    required NyaMailApi api,
    required String channel,
    ReleaseVerifier? verifier,
    AndroidUpdateInstaller? androidInstaller,
    http.Client? httpClient,
    SupportDirectoryProvider? supportDirectoryProvider,
  }) : _api = api,
       _channel = channel,
       _verifier = verifier,
       _androidInstaller = androidInstaller ?? const AndroidUpdateInstaller(),
       _httpClient = httpClient ?? http.Client(),
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  final NyaMailApi _api;
  final String _channel;
  final ReleaseVerifier? _verifier;
  final AndroidUpdateInstaller _androidInstaller;
  final http.Client _httpClient;
  final SupportDirectoryProvider _supportDirectoryProvider;

  Future<ReleaseCheckResult> check() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final build = int.tryParse(packageInfo.buildNumber) ?? 0;
    return _api.checkRelease(
      platform: currentPlatform,
      arch: currentArch,
      channel: _channel,
      build: build,
    );
  }

  Future<void> openDownload(ReleaseArtifact artifact) async {
    final uri = Uri.parse(artifact.url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open ${artifact.url}');
    }
  }

  Future<void> openDownloadedFile(File file) async {
    if (Platform.isWindows && file.path.toLowerCase().endsWith('.zip')) {
      await _startWindowsUpdater(file);
      return;
    }
    if (shouldUseAndroidPackageInstaller(
      isAndroid: Platform.isAndroid,
      path: file.path,
    )) {
      await _androidInstaller.installApk(file);
      return;
    }
    final uri = file.uri;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open ${file.path}');
    }
  }

  Future<File> downloadAndVerify(ReleaseArtifact artifact) async {
    final uri = Uri.parse(artifact.url);
    final response = await _httpClient.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Download failed with HTTP ${response.statusCode}');
    }
    final actual = sha256.convert(response.bodyBytes).toString();
    if (artifact.sha256.isNotEmpty &&
        actual.toLowerCase() != artifact.sha256.toLowerCase()) {
      throw StateError('Downloaded artifact checksum mismatch');
    }
    final supportDir = await _supportDirectoryProvider();
    final filename = uri.pathSegments.last;
    final file = File('${supportDir.path}/updates/$filename');
    final tempFile = File('${file.path}.download');
    await file.parent.create(recursive: true);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    await tempFile.writeAsBytes(response.bodyBytes, flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tempFile.rename(file.path);
    return file;
  }

  Future<bool> verifyManifestSignature(ReleaseArtifact artifact) async {
    final signature = artifact.signature.trim();
    if (signature.isEmpty || signature == 'unsigned-dev-build') {
      return _channel == 'dev';
    }
    return _verifier?.verify(artifact) ?? false;
  }

  Future<void> _startWindowsUpdater(File zipFile) async {
    final supportDir = await _supportDirectoryProvider();
    final updatesDir = Directory('${supportDir.path}/updates');
    await updatesDir.create(recursive: true);
    final script = File('${updatesDir.path}/install-nyamail-update.ps1');
    final installRoot = '${supportDir.path}/installed';
    final scriptBody = windowsUpdaterScript(
      zipPath: zipFile.path,
      installRoot: installRoot,
      currentExe: Platform.resolvedExecutable,
    );
    await script.writeAsString(scriptBody, flush: true);
    final result = await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
    ], mode: ProcessStartMode.detached);
    final exitCode = await result.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => 0,
    );
    if (exitCode != 0) {
      throw StateError('Could not start Windows updater.');
    }
  }

  static String windowsUpdaterScript({
    required String zipPath,
    required String installRoot,
    required String currentExe,
  }) => updater.windowsUpdaterScript(
    zipPath: zipPath,
    installRoot: installRoot,
    currentExe: currentExe,
  );

  String get currentPlatform => updater.currentReleasePlatform();

  String get currentArch => updater.currentReleaseArch();
}
