import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'pack_model.dart';

/// Largest image accepted for a pack (emoji or sticker).
const maxPackImageBytes = 2 * 1024 * 1024;
const maxPackImageDimension = 4096;

/// A validated image ready to upload into a pack.
@immutable
class PreparedPackImage {
  const PreparedPackImage({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    required this.width,
    required this.height,
    required this.suggestedShortcode,
  });
  final Uint8List bytes;
  final String mimeType;
  final String fileName;
  final int width;
  final int height;
  final String suggestedShortcode;

  /// `ImageInfo` for the pack entry and sticker events.
  Map<String, Object?> get info => {
    'w': width,
    'h': height,
    'mimetype': mimeType,
    'size': bytes.length,
  };
}

/// Image type from its magic bytes; the picker's name/MIME is not trusted.
String? sniffPackImageType(Uint8List bytes) {
  bool starts(List<int> prefix, [int offset = 0]) {
    if (bytes.length < offset + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[offset + i] != prefix[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

/// Validates type, size and dimensions (header only; pixels are not
/// decoded). Throws [FormatException] with a user-facing message.
PreparedPackImage preparePackImage(Uint8List bytes, String fileName) {
  if (bytes.isEmpty) throw const FormatException('The image is empty.');
  if (bytes.length > maxPackImageBytes) {
    throw const FormatException('Images must be 2 MB or smaller.');
  }
  final mime = sniffPackImageType(bytes);
  if (mime == null) {
    throw const FormatException('Use a PNG, GIF, WebP or JPEG image.');
  }
  int? width;
  int? height;
  try {
    final img.Decoder decoder = switch (mime) {
      'image/png' => img.PngDecoder(),
      'image/gif' => img.GifDecoder(),
      'image/jpeg' => img.JpegDecoder(),
      _ => img.WebPDecoder(),
    };
    final info = decoder.startDecode(bytes);
    width = info?.width;
    height = info?.height;
  } catch (_) {
    width = null;
  }
  if (width == null ||
      height == null ||
      width < 1 ||
      height < 1 ||
      width > maxPackImageDimension ||
      height > maxPackImageDimension) {
    throw const FormatException('This image couldn’t be read.');
  }
  final base = fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;
  final extension = switch (mime) {
    'image/png' => 'png',
    'image/gif' => 'gif',
    'image/jpeg' => 'jpg',
    _ => 'webp',
  };
  final code = normaliseShortcode(base).toLowerCase();
  return PreparedPackImage(
    bytes: bytes,
    mimeType: mime,
    fileName: '${code.isEmpty ? 'emoji' : code}.$extension',
    width: width,
    height: height,
    suggestedShortcode: code,
  );
}

/// Reads a picked file with the size cap applied before buffering it.
Future<PreparedPackImage> readPackImage(XFile file) async {
  final length = await file.length();
  if (length > maxPackImageBytes) {
    throw const FormatException('Images must be 2 MB or smaller.');
  }
  final bytes = await file.readAsBytes();
  return preparePackImage(bytes, file.name);
}
