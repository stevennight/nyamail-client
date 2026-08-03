import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/models.dart';

class GitHubReleaseClient {
  GitHubReleaseClient({http.Client? client, Uri? apiBaseUri})
    : _httpClient = client ?? http.Client(),
      _apiBaseUri =
          apiBaseUri ??
          Uri.parse('https://api.github.com/repos/stevennight/nyamail-client');

  static const repository = 'stevennight/nyamail-client';

  final http.Client _httpClient;
  final Uri _apiBaseUri;

  Future<ReleaseCheckResult> check({
    required String platform,
    required String arch,
    required String channel,
    required String currentVersion,
    required int currentBuild,
  }) async {
    final release = await _getObject(_appendPath('releases/latest'));
    final assets = _parseAssets(release['assets']);
    final candidate = _findCompatibleAsset(
      assets,
      platform: platform,
      arch: arch,
    );
    if (candidate == null) {
      return const ReleaseCheckResult(
        updateAvailable: false,
        reason: 'No compatible GitHub Release asset is available.',
      );
    }

    final parsed = _parseArtifactName(candidate.name);
    if (parsed == null) {
      return const ReleaseCheckResult(
        updateAvailable: false,
        reason: 'The GitHub Release asset has an invalid version name.',
      );
    }
    _GitHubAsset? checksumAsset;
    for (final asset in assets) {
      if (asset.name.toLowerCase() ==
          '${candidate.name.toLowerCase()}.sha256') {
        checksumAsset = asset;
        break;
      }
    }
    if (checksumAsset == null) {
      throw StateError(
        'The GitHub Release is missing the SHA-256 asset for ${candidate.name}.',
      );
    }

    final sha256 = await _readChecksum(
      checksumAsset.url,
      artifactName: candidate.name,
    );
    final releaseTag = release['tag_name'] as String? ?? '';
    final artifact = ReleaseArtifact(
      id: '$releaseTag/${candidate.name}',
      component: 'client',
      platform: parsed.platform,
      arch: parsed.arch,
      channel: channel,
      version: parsed.version,
      build: parsed.build,
      commit: release['target_commitish'] as String? ?? '',
      url: candidate.url,
      sha256: sha256,
      signature: ReleaseArtifact.githubReleaseSignature,
      minApiVersion: '',
      force: false,
      rollout: 100,
      notes: release['body'] as String? ?? '',
    );

    return ReleaseCheckResult(
      updateAvailable: isNewerRelease(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        candidateVersion: artifact.version,
        candidateBuild: artifact.build,
      ),
      latest: artifact,
    );
  }

  Future<Map<String, Object?>> _getObject(Uri uri) async {
    final response = await _httpClient.get(uri, headers: _headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'GitHub Release check failed with HTTP ${response.statusCode}.',
      );
    }
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('GitHub returned an invalid Release response.');
    }
    return decoded.cast<String, Object?>();
  }

  Future<String> _readChecksum(
    String url, {
    required String artifactName,
  }) async {
    final response = await _httpClient.get(Uri.parse(url), headers: _headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'GitHub Release checksum download failed with HTTP ${response.statusCode}.',
      );
    }
    final hashPattern = RegExp(r'^\s*([0-9a-fA-F]{64})\s+(?:\*?)(.+?)\s*$');
    String? firstHash;
    for (final line in response.body.split(RegExp(r'\r?\n'))) {
      final match = hashPattern.firstMatch(line);
      if (match == null) continue;
      firstHash ??= match.group(1);
      final filename = match.group(2)!.trim().replaceFirst(RegExp(r'^\*'), '');
      if (_basename(filename) == artifactName) {
        return match.group(1)!.toLowerCase();
      }
    }
    if (firstHash != null) return firstHash.toLowerCase();
    throw StateError('GitHub Release checksum for $artifactName is invalid.');
  }

  Uri _appendPath(String suffix) {
    final basePath =
        _apiBaseUri.path.endsWith('/')
            ? _apiBaseUri.path.substring(0, _apiBaseUri.path.length - 1)
            : _apiBaseUri.path;
    return _apiBaseUri.replace(path: '$basePath/$suffix');
  }

  List<_GitHubAsset> _parseAssets(Object? value) {
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map)
          _GitHubAsset(
            name: item['name'] as String? ?? '',
            url: item['browser_download_url'] as String? ?? '',
          ),
    ];
  }

  _GitHubAsset? _findCompatibleAsset(
    List<_GitHubAsset> assets, {
    required String platform,
    required String arch,
  }) {
    final pattern = switch (platform) {
      'windows' when arch == 'amd64' => RegExp(
        r'^nyamail-windows-x64-\d+\.\d+\.\d+\+\d+\.zip$',
      ),
      'android' => RegExp(r'^nyamail-android-\d+\.\d+\.\d+\+\d+\.apk$'),
      _ => null,
    };
    if (pattern == null) return null;
    for (final asset in assets) {
      if (pattern.hasMatch(asset.name) && _isHttpsUrl(asset.url)) {
        return asset;
      }
    }
    return null;
  }

  _ParsedArtifact? _parseArtifactName(String name) {
    final windows = RegExp(
      r'^nyamail-windows-x64-(\d+)\.(\d+)\.(\d+)\+(\d+)\.zip$',
    ).firstMatch(name);
    if (windows != null) {
      return _ParsedArtifact(
        platform: 'windows',
        arch: 'amd64',
        version: '${windows.group(1)}.${windows.group(2)}.${windows.group(3)}',
        build: int.parse(windows.group(4)!),
      );
    }
    final android = RegExp(
      r'^nyamail-android-(\d+)\.(\d+)\.(\d+)\+(\d+)\.apk$',
    ).firstMatch(name);
    if (android != null) {
      return _ParsedArtifact(
        platform: 'android',
        arch: 'universal',
        version: '${android.group(1)}.${android.group(2)}.${android.group(3)}',
        build: int.parse(android.group(4)!),
      );
    }
    return null;
  }

  bool _isHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  String _basename(String value) {
    final normalized = value.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static bool isNewerRelease({
    required String currentVersion,
    required int currentBuild,
    required String candidateVersion,
    required int candidateBuild,
  }) {
    final current = _parseVersion(currentVersion);
    final candidate = _parseVersion(candidateVersion);
    if (current == null || candidate == null) {
      return candidateBuild > currentBuild;
    }
    for (var index = 0; index < 3; index++) {
      if (candidate[index] != current[index]) {
        return candidate[index] > current[index];
      }
    }
    return candidateBuild > currentBuild;
  }

  static List<int>? _parseVersion(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value.trim());
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  static const _headers = <String, String>{
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'NyaMail',
  };
}

class _GitHubAsset {
  const _GitHubAsset({required this.name, required this.url});

  final String name;
  final String url;
}

class _ParsedArtifact {
  const _ParsedArtifact({
    required this.platform,
    required this.arch,
    required this.version,
    required this.build,
  });

  final String platform;
  final String arch;
  final String version;
  final int build;
}
