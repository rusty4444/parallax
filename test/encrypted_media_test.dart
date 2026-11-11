import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/encrypted_media.dart';

void main() {
  test('encrypted media content carries only a ciphertext URL and keys', () {
    final encrypted = matrix.EncryptedFile(
      data: Uint8List.fromList([7, 8, 9]),
      k: 'sample-key',
      iv: 'sample-iv',
      sha256: 'sample-hash',
    );
    final content = encryptedFileContent(
      Uri.parse('mxc://matrix.example/ciphertext'),
      'image/jpeg',
      encrypted,
    );
    expect(content['url'], 'mxc://matrix.example/ciphertext');
    expect(content['mimetype'], 'image/jpeg');
    expect((content['key'] as Map)['k'], 'sample-key');
    expect((content['hashes'] as Map)['sha256'], 'sample-hash');
    expect(content.containsKey('plaintext'), isFalse);
  });
}
