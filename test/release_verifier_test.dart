import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto_graphy;
import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/api/models.dart';
import 'package:nyamail/src/api/nyamail_api.dart';
import 'package:nyamail/src/release/release_service.dart';
import 'package:nyamail/src/release/release_verifier.dart';

void main() {
  const artifact = ReleaseArtifact(
    id: 'client-windows-amd64-stable-1.0.0-100',
    component: 'client',
    platform: 'windows',
    arch: 'amd64',
    channel: 'stable',
    version: '1.0.0',
    build: 100,
    commit: 'abc123',
    url: 'https://updates.example.test/nyamail.zip',
    sha256: 'abcdef',
    signature: '',
    minApiVersion: '1',
    force: false,
    rollout: 100,
    notes: 'Stable release',
  );

  test(
      'release verifier accepts an Ed25519 signature over stable payload fields',
      () async {
    final algorithm = crypto_graphy.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(
      utf8.encode(ReleaseVerifier.releaseSignaturePayload(artifact)),
      keyPair: keyPair,
    );
    final signed = _copyArtifact(
      artifact,
      signature: base64Encode(signature.bytes),
      url: 'https://mirror.example.test/nyamail.zip',
    );

    final verifier = ReleaseVerifier(publicKey: base64Encode(publicKey.bytes));

    expect(await verifier.verify(signed), isTrue);
  });

  test('release verifier rejects tampered signed fields', () async {
    final algorithm = crypto_graphy.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final signature = await algorithm.sign(
      utf8.encode(ReleaseVerifier.releaseSignaturePayload(artifact)),
      keyPair: keyPair,
    );
    final tampered = _copyArtifact(
      artifact,
      sha256: '000000',
      signature: base64Encode(signature.bytes),
    );

    final verifier = ReleaseVerifier(publicKey: base64Encode(publicKey.bytes));

    expect(await verifier.verify(tampered), isFalse);
  });

  test('release verifier accepts signatures produced by Go releaser', () async {
    const signedByGo = ReleaseArtifact(
      id: 'client-windows-amd64-stable-1.0.0-100',
      component: 'client',
      platform: 'windows',
      arch: 'amd64',
      channel: 'stable',
      version: '1.0.0',
      build: 100,
      commit: 'abc123',
      url: 'https://mirror.example.test/nyamail.zip',
      sha256: 'abcdef',
      signature:
          'AICTB6KXZeJ6qaxL2xrCc3wZeKVKdhFlKTehSiqvpOvEDJnAWGrBX80fnBqREEzZYTxw9fxdTeyR++SY90WFAw==',
      minApiVersion: '1',
      force: false,
      rollout: 100,
      notes: 'Stable release',
    );
    final verifier = ReleaseVerifier(
      publicKey: 'gDjHgTX8oVQTomZtAR8e/6PXOGMSUddjyX5ejWUV1R4=',
    );

    expect(await verifier.verify(signedByGo), isTrue);
  });

  test('release service allows unsigned artifacts only on dev channel',
      () async {
    final devService = ReleaseService(
      api: NyaMailApi(baseUrl: 'http://localhost'),
      channel: 'dev',
      verifier: ReleaseVerifier(publicKey: ''),
    );
    final stableService = ReleaseService(
      api: NyaMailApi(baseUrl: 'http://localhost'),
      channel: 'stable',
      verifier: ReleaseVerifier(publicKey: ''),
    );
    final unsigned = _copyArtifact(artifact, signature: 'unsigned-dev-build');

    expect(await devService.verifyManifestSignature(unsigned), isTrue);
    expect(await stableService.verifyManifestSignature(unsigned), isFalse);
  });
}

ReleaseArtifact _copyArtifact(
  ReleaseArtifact artifact, {
  String? url,
  String? sha256,
  String? signature,
}) {
  return ReleaseArtifact(
    id: artifact.id,
    component: artifact.component,
    platform: artifact.platform,
    arch: artifact.arch,
    channel: artifact.channel,
    version: artifact.version,
    build: artifact.build,
    commit: artifact.commit,
    url: url ?? artifact.url,
    sha256: sha256 ?? artifact.sha256,
    signature: signature ?? artifact.signature,
    minApiVersion: artifact.minApiVersion,
    force: artifact.force,
    rollout: artifact.rollout,
    notes: artifact.notes,
    requiredVersion: artifact.requiredVersion,
  );
}
