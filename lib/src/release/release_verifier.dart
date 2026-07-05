import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto_graphy;

import '../api/models.dart';

class ReleaseVerifier {
  ReleaseVerifier({
    required String publicKey,
    crypto_graphy.Ed25519? algorithm,
  })  : _publicKey = publicKey.trim(),
        _algorithm = algorithm ?? crypto_graphy.Ed25519();

  static const signaturePayloadVersion = 'nyamail-release-v1';

  final String _publicKey;
  final crypto_graphy.Ed25519 _algorithm;

  Future<bool> verify(ReleaseArtifact artifact) async {
    final signature = artifact.signature.trim();
    if (_publicKey.isEmpty ||
        signature.isEmpty ||
        signature == 'unsigned-dev-build') {
      return false;
    }
    try {
      final publicKey = crypto_graphy.SimplePublicKey(
        _decodeBase64(_publicKey),
        type: crypto_graphy.KeyPairType.ed25519,
      );
      return _algorithm.verify(
        utf8.encode(releaseSignaturePayload(artifact)),
        signature: crypto_graphy.Signature(
          _decodeBase64(signature),
          publicKey: publicKey,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  static String releaseSignaturePayload(ReleaseArtifact artifact) {
    final payload = <String, Object?>{
      'payload_version': signaturePayloadVersion,
      'id': artifact.id,
      'component': artifact.component,
      'platform': artifact.platform,
      'arch': artifact.arch,
      'channel': artifact.channel,
      'version': artifact.version,
      'build': artifact.build,
      'commit': artifact.commit,
      'sha256': artifact.sha256.toLowerCase(),
      'min_api_version': artifact.minApiVersion,
      'force': artifact.force,
      'rollout': artifact.rollout,
      'required_version': artifact.requiredVersion,
    };
    return jsonEncode(payload);
  }

  List<int> _decodeBase64(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), '');
    try {
      return base64Decode(normalized);
    } on FormatException {
      return base64Url.decode(base64Url.normalize(normalized));
    }
  }
}
