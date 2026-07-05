import 'package:flutter_test/flutter_test.dart';
import 'package:nyamail/src/security/vault_crypto.dart';

void main() {
  test('vault item ids are unique and prefixed', () {
    const crypto = VaultCrypto();
    final first = crypto.newVaultItemId('me@example.com');
    final second = crypto.newVaultItemId('me@example.com');
    expect(first, startsWith('vault_'));
    expect(second, startsWith('vault_'));
    expect(first, isNot(second));
  });
}
