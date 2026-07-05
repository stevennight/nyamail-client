import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

class OAuthPkce {
  OAuthPkce({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  OAuthPkcePair createPair() {
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return OAuthPkcePair(
      verifier: verifier,
      challenge: challenge,
      challengeMethod: 'S256',
    );
  }

  String createState() => _randomString(32);

  String _randomString(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(
      length,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }
}

class OAuthPkcePair {
  const OAuthPkcePair({
    required this.verifier,
    required this.challenge,
    required this.challengeMethod,
  });

  final String verifier;
  final String challenge;
  final String challengeMethod;
}
