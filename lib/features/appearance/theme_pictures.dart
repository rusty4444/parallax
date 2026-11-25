import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../encrypted_media.dart' show encryptedFileContent;
import '../../media_download.dart';
import '../media/image_optimiser.dart';

/// Downloads the (encrypted) bytes of an `mxc://` URI.
typedef MxcDownloader =
    Future<Uint8List> Function(matrix.Client client, Uri mxc, int maxBytes);

/// Encrypts a file for upload (Matrix attachment encryption, AES-CTR).
typedef FileEncrypter = Future<matrix.EncryptedFile> Function(Uint8List bytes);

/// Decrypts and hash-checks a downloaded file; null when it does not match.
typedef FileDecrypter =
    Future<Uint8List?> Function(matrix.EncryptedFile encrypted);

/// Uploads and downloads chat background pictures, always encrypted on the
/// device (attachment encryption): the homeserver stores only ciphertext, and
/// whoever holds the `file` JSON (its key) can read the picture.
class ThemePictures {
  ThemePictures({
    ImagePreparer? prepareImage,
    MxcDownloader? download,
    FileEncrypter? encrypt,
    FileDecrypter? decrypt,
  }) : _prepareImage = prepareImage ?? prepareImageForUpload,
       _download = download ?? _downloadMxc,
       _encrypt = encrypt ?? matrix.encryptFile,
       _decrypt = decrypt ?? matrix.decryptFileImplementation;

  /// Largest background uploaded unchanged (formats that are not re-encoded).
  static const maxUploadBytes = 8 * 1024 * 1024;

  /// Largest background downloaded.
  static const maxDownloadBytes = 12 * 1024 * 1024;

  final ImagePreparer _prepareImage;
  final MxcDownloader _download;
  final FileEncrypter _encrypt;
  final FileDecrypter _decrypt;

  /// Shrinks (JPEG/PNG to a 2048 px long edge), encrypts and uploads
  /// [original]. Returns `{file, info}` for event or account-data content, or
  /// null when [isCurrent] turned false meanwhile. Throws for non-pictures,
  /// pictures too large to sync and upload failures.
  Future<Map<String, Object?>?> upload(
    matrix.Client client,
    Uint8List original, {
    required bool Function() isCurrent,
  }) async {
    final mimeType = sniffImageMimeType(original);
    if (mimeType == null) throw StateError('Not a picture');
    final prepared = await _prepareImage(
      ImagePrepareRequest(bytes: original, mimeType: mimeType, optimise: true),
    );
    final bytes = prepared?.bytes ?? original;
    if (bytes.length > maxUploadBytes) {
      throw StateError('Background too large to sync');
    }
    final uploadMime = prepared?.mimeType ?? mimeType;
    if (!isCurrent()) return null;
    final encrypted = await _encrypt(bytes);
    if (!isCurrent()) return null;
    final uri = await client.uploadContent(
      encrypted.data,
      filename: 'crypt',
      contentType: 'application/octet-stream',
    );
    if (!isCurrent()) return null;
    return {
      'file': encryptedFileContent(uri, uploadMime, encrypted),
      'info': {
        'mimetype': uploadMime,
        'size': bytes.length,
        'w': ?prepared?.width,
        'h': ?prepared?.height,
      },
    };
  }

  /// Downloads, decrypts and hash-checks the picture described by [file]
  /// (an encrypted-attachment `file` object). Null when it is malformed,
  /// can't be downloaded, fails its hash check or is not a picture.
  Future<Uint8List?> download(
    matrix.Client client,
    Map<String, Object?> file, {
    required bool Function() isCurrent,
  }) async {
    final url = file['url'];
    final key = file['key'];
    final iv = file['iv'];
    final hashes = file['hashes'];
    final k = key is Map ? key['k'] : null;
    final sha256 = hashes is Map ? hashes['sha256'] : null;
    if (url is! String || k is! String || iv is! String || sha256 is! String) {
      return null;
    }
    final mxc = Uri.tryParse(url);
    if (mxc == null ||
        !mxc.isScheme('mxc') ||
        mxc.host.isEmpty ||
        mxc.pathSegments.length != 1) {
      return null;
    }
    try {
      final data = await _download(client, mxc, maxDownloadBytes);
      if (!isCurrent()) return null;
      final plain = await _decrypt(
        matrix.EncryptedFile(data: data, k: k, iv: iv, sha256: sha256),
      );
      if (plain == null || sniffImageMimeType(plain) == null) return null;
      return plain;
    } catch (_) {
      return null; // Offline or gone: keep what this device has.
    }
  }

  static Future<Uint8List> _downloadMxc(
    matrix.Client client,
    Uri mxc,
    int maxBytes,
  ) async {
    final uri = await mxc.getDownloadUri(client);
    final homeserver = client.homeserver;
    final token = client.accessToken;
    if (homeserver == null || token == null) {
      throw StateError('Media session unavailable');
    }
    return downloadMatrixMedia(
      httpClient: client.httpClient,
      homeserver: homeserver,
      uri: uri,
      accessToken: token,
      maxBytes: maxBytes,
    );
  }
}

/// `image/jpeg`, `image/png`, `image/gif` or `image/webp` from the file's
/// first bytes; null for anything else.
@visibleForTesting
String? sniffImageMimeType(Uint8List bytes) {
  bool starts(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
