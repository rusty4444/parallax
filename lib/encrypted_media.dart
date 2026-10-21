import 'package:matrix/matrix.dart' as matrix;

/// Uploads ciphertext before asking the SDK to send an encrypted room event.
/// This avoids Room.sendFileEvent's plaintext-upload fallback if crypto drops
/// during thumbnail generation or server media-config requests.
Future<void> sendEncryptedMedia({
  required matrix.Client client,
  required matrix.Room room,
  required matrix.MatrixFile file,
  required bool Function() canSend,
  int? shrinkImageMaxDimension,
}) async {
  void requireCrypto() {
    if (!room.encrypted || !client.encryptionEnabled || !canSend()) {
      throw StateError('Encrypted media send is unavailable');
    }
  }

  requireCrypto();
  matrix.MatrixFile prepared = file;
  if (file is matrix.MatrixImageFile && shrinkImageMaxDimension != null) {
    prepared = await matrix.MatrixImageFile.shrink(
      bytes: file.bytes,
      name: file.name,
      mimeType: file.mimeType,
      maxDimension: shrinkImageMaxDimension,
      nativeImplementations: client.nativeImplementations,
      customImageResizer: client.customImageResizer,
    );
  }
  requireCrypto();
  final encrypted = await prepared.encrypt();
  requireCrypto();
  final uri = await client.uploadContent(
    encrypted.data,
    filename: 'crypt',
    contentType: 'application/octet-stream',
  );
  requireCrypto();
  final sentId = await room.sendEvent({
    'msgtype': prepared.msgType,
    'body': prepared.name,
    'filename': prepared.name,
    'info': prepared.info,
    'file': encryptedFileContent(uri, prepared.mimeType, encrypted),
  });
  if (sentId == null) throw StateError('Encrypted attachment was not sent');
}

Map<String, dynamic> encryptedFileContent(
  Uri uri,
  String mimeType,
  matrix.EncryptedFile encrypted,
) => {
  'url': uri.toString(),
  'mimetype': mimeType,
  'v': 'v2',
  'key': {
    'alg': 'A256CTR',
    'ext': true,
    'k': encrypted.k,
    'key_ops': ['encrypt', 'decrypt'],
    'kty': 'oct',
  },
  'iv': encrypted.iv,
  'hashes': {'sha256': encrypted.sha256},
};
