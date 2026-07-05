import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/local_cache_crypto.dart';

void main() {
  test('local cache cipher encrypts and decrypts payloads', () async {
    final secret = base64UrlEncode(List<int>.generate(32, (index) => index));
    final cipher = LocalCacheCipher(secret);

    final encrypted = await cipher.encryptText('private message body');
    final decrypted = await cipher.tryDecryptText(encrypted);

    expect(encrypted, contains(LocalCacheCipher.format));
    expect(encrypted, isNot(contains('private message body')));
    expect(decrypted, 'private message body');
  });

  test('local cache cipher treats wrong keys as unreadable cache', () async {
    final firstSecret = base64UrlEncode(
      List<int>.generate(32, (index) => index),
    );
    final secondSecret = base64UrlEncode(
      List<int>.generate(32, (index) => 255 - index),
    );
    final encrypted = await LocalCacheCipher(
      firstSecret,
    ).encryptText('cached body');

    final decrypted = await LocalCacheCipher(
      secondSecret,
    ).tryDecryptText(encrypted);

    expect(decrypted, isNull);
  });

  test('password-derived local cache secret is stable and account scoped', () {
    final first = localCacheSecretFromPassword(
      email: 'Alice@Example.COM ',
      password: 'correct horse battery staple',
    );
    final same = localCacheSecretFromPassword(
      email: 'alice@example.com',
      password: 'correct horse battery staple',
    );
    final otherPassword = localCacheSecretFromPassword(
      email: 'alice@example.com',
      password: 'different',
    );
    final otherAccount = localCacheSecretFromPassword(
      email: 'bob@example.com',
      password: 'correct horse battery staple',
    );

    expect(first, same);
    expect(first, isNot(otherPassword));
    expect(first, isNot(otherAccount));
    expect(base64Url.decode(base64Url.normalize(first)), hasLength(32));
  });
}
