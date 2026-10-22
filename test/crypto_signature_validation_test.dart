import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/crypto_signature_validation.dart';

void main() {
  test('unsigned retained subkey cannot be treated as trusted', () {
    final subkey = matrix.MatrixCrossSigningKey.fromJson({
      'user_id': '@test:example.org',
      'usage': ['self_signing'],
      'keys': {'ed25519:subkey': 'subkey'},
    });
    expect(
      isSubkeySignedByMaster(
        subkey,
        userId: '@test:example.org',
        masterPublicKey: 'synthetic-master-public-key',
      ),
      isFalse,
    );
    expect(subkey.toJson()['keys'], {'ed25519:subkey': 'subkey'});
  });
}
