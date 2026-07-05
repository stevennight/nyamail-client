import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/api/nyamail_api.dart';
import 'package:nyamail/src/release/android_update_installer.dart';
import 'package:nyamail/src/release/release_service.dart';

void main() {
  test('windows updater script expands zip and starts current executable', () {
    final script = ReleaseService.windowsUpdaterScript(
      zipPath: r"C:\Users\Me\AppData\update's\nya.zip",
      installRoot: r'C:\Users\Me\AppData\installed',
      currentExe: r'C:\Old\nyamail.exe',
    );

    expect(script, contains('Expand-Archive -LiteralPath \$zip'));
    expect(script, contains('New-Item -ItemType Junction'));
    expect(script, contains('Start-Process -FilePath \$nextExe'));
    expect(script, contains('[System.IO.Directory]::Delete'));
    expect(script, contains(r"C:\Users\Me\AppData\update''s\nya.zip"));
  });

  test('android installer handoff is used only for Android APK files', () {
    expect(
      shouldUseAndroidPackageInstaller(
        isAndroid: true,
        path: '/data/user/0/app/cache/update.apk',
      ),
      isTrue,
    );
    expect(
      shouldUseAndroidPackageInstaller(
        isAndroid: true,
        path: '/data/user/0/app/cache/update.zip',
      ),
      isFalse,
    );
    expect(
      shouldUseAndroidPackageInstaller(
        isAndroid: false,
        path: '/tmp/update.apk',
      ),
      isFalse,
    );
  });

  test('release check sends the current artifact architecture', () async {
    late Uri requestedUri;
    final api = NyaMailApi(
      baseUrl: 'https://updates.example.test',
      client: MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({'update_available': false, 'reason': 'none'}),
          200,
        );
      }),
    );

    await api.checkRelease(
      platform: 'windows',
      channel: 'stable',
      build: 100,
      arch: 'amd64',
    );

    expect(requestedUri.path, '/v1/release/latest');
    expect(requestedUri.queryParameters['platform'], 'windows');
    expect(requestedUri.queryParameters['channel'], 'stable');
    expect(requestedUri.queryParameters['build'], '100');
    expect(requestedUri.queryParameters['arch'], 'amd64');
  });

  test(
    'release service maps the current runtime to a release architecture',
    () {
      final service = ReleaseService(
        api: NyaMailApi(baseUrl: 'http://localhost'),
        channel: 'dev',
      );

      expect(service.currentArch, isNotEmpty);
      expect(['amd64', 'arm64', 'universal'], contains(service.currentArch));
    },
  );

  test(
    'downloadAndVerify writes a verified update through a temp file',
    () async {
      final supportDir = await Directory.systemTemp.createTemp(
        'nyamail_release_test_',
      );
      final bytes = utf8.encode('verified update bytes');
      try {
        final service = ReleaseService(
          api: NyaMailApi(baseUrl: 'https://updates.example.test'),
          channel: 'dev',
          httpClient: MockClient((request) async {
            expect(
              request.url.toString(),
              'https://updates.example.test/downloads/update.zip',
            );
            return http.Response.bytes(bytes, 200);
          }),
          supportDirectoryProvider: () async => supportDir,
        );

        final file = await service.downloadAndVerify(
          _releaseArtifact(sha256Value: sha256.convert(bytes).toString()),
        );

        expect(await file.readAsBytes(), bytes);
        expect(await File('${file.path}.download').exists(), isFalse);
      } finally {
        await supportDir.delete(recursive: true);
      }
    },
  );

  test(
    'downloadAndVerify does not overwrite an existing file on hash mismatch',
    () async {
      final supportDir = await Directory.systemTemp.createTemp(
        'nyamail_release_test_',
      );
      final existingFile = File('${supportDir.path}/updates/update.zip');
      final oldBytes = utf8.encode('old verified update');
      final wrongBytes = utf8.encode('tampered update');
      try {
        await existingFile.parent.create(recursive: true);
        await existingFile.writeAsBytes(oldBytes);
        final service = ReleaseService(
          api: NyaMailApi(baseUrl: 'https://updates.example.test'),
          channel: 'dev',
          httpClient: MockClient(
            (_) async => http.Response.bytes(wrongBytes, 200),
          ),
          supportDirectoryProvider: () async => supportDir,
        );

        await expectLater(
          service.downloadAndVerify(
            _releaseArtifact(
              sha256Value: sha256.convert(utf8.encode('expected')).toString(),
            ),
          ),
          throwsA(isA<StateError>()),
        );

        expect(await existingFile.readAsBytes(), oldBytes);
        expect(await File('${existingFile.path}.download').exists(), isFalse);
      } finally {
        await supportDir.delete(recursive: true);
      }
    },
  );
}

ReleaseArtifact _releaseArtifact({required String sha256Value}) {
  return ReleaseArtifact(
    id: 'client-windows-amd64',
    component: 'client',
    platform: 'windows',
    arch: 'amd64',
    channel: 'dev',
    version: '0.1.0',
    build: 2,
    commit: 'tree-test',
    url: 'https://updates.example.test/downloads/update.zip',
    sha256: sha256Value,
    signature: 'unsigned-dev-build',
    minApiVersion: '1',
    force: false,
    rollout: 100,
    notes: 'Test update',
  );
}
