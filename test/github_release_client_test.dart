import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nyamail/src/release/github_release_client.dart';

void main() {
  const artifactName = 'nyamail-windows-x64-1.0.5+6.zip';
  const artifactUrl =
      'https://github.com/stevennight/nyamail-client/releases/download/'
      'v1.0.5/nyamail-windows-x64-1.0.5%2B6.zip';
  const checksum =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test(
    'checks the latest GitHub Release and reads its checksum asset',
    () async {
      final requestedPaths = <String>[];
      final client = GitHubReleaseClient(
        apiBaseUri: Uri.parse(
          'https://api.github.test/repos/stevennight/nyamail-client',
        ),
        client: MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path.endsWith('/releases/latest')) {
            return http.Response(
              jsonEncode({
                'tag_name': 'v1.0.5',
                'target_commitish': '3025ac0',
                'body': 'Transparent application icons.',
                'assets': [
                  {'name': artifactName, 'browser_download_url': artifactUrl},
                  {
                    'name': '$artifactName.sha256',
                    'browser_download_url':
                        'https://github.com/stevennight/nyamail-client/releases/'
                        'download/v1.0.5/$artifactName.sha256',
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.endsWith('$artifactName.sha256')) {
            return http.Response('$checksum  $artifactName\n', 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final result = await client.check(
        platform: 'windows',
        arch: 'amd64',
        channel: 'stable',
        currentVersion: '1.0.4',
        currentBuild: 5,
      );

      expect(result.updateAvailable, isTrue);
      expect(result.latest?.version, '1.0.5');
      expect(result.latest?.build, 6);
      expect(result.latest?.sha256, checksum);
      expect(result.latest?.url, artifactUrl);
      expect(requestedPaths, hasLength(2));
    },
  );

  test('does not offer a release that is not newer', () {
    expect(
      GitHubReleaseClient.isNewerRelease(
        currentVersion: '1.0.5',
        currentBuild: 6,
        candidateVersion: '1.0.5',
        candidateBuild: 6,
      ),
      isFalse,
    );
    expect(
      GitHubReleaseClient.isNewerRelease(
        currentVersion: '1.0.5',
        currentBuild: 6,
        candidateVersion: '1.0.6',
        candidateBuild: 1,
      ),
      isTrue,
    );
  });

  test('times out when the GitHub API does not respond', () async {
    final client = GitHubReleaseClient(
      requestTimeout: const Duration(milliseconds: 10),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.check(
        platform: 'windows',
        arch: 'amd64',
        channel: 'stable',
        currentVersion: '1.0.5',
        currentBuild: 6,
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
