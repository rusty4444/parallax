import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Long edge of optimised uploads.
const optimisedImageEdge = 2048;

/// JPEG quality of optimised uploads.
const optimisedImageQuality = 80;

/// Matrix-recommended thumbnail bounds (as used by Element X).
const thumbnailMaxWidth = 800;
const thumbnailMaxHeight = 600;

/// Never decode more pixels than this in the upload isolate.
const _maxDecodePixels = 40 * 1000 * 1000;

@immutable
class ImagePrepareRequest {
  const ImagePrepareRequest({
    required this.bytes,
    required this.mimeType,
    required this.optimise,
  });
  final Uint8List bytes;
  final String mimeType;
  final bool optimise;
}

/// An image ready for upload: possibly re-encoded bytes, its displayed
/// dimensions and an optional thumbnail.
@immutable
class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
    this.optimised = false,
    this.thumbnail,
    this.thumbnailMimeType,
    this.thumbnailWidth,
    this.thumbnailHeight,
  });
  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;

  /// Whether [bytes] differ from the original (resized and/or re-encoded).
  final bool optimised;
  final Uint8List? thumbnail;
  final String? thumbnailMimeType;
  final int? thumbnailWidth;
  final int? thumbnailHeight;
}

typedef ImagePreparer = Future<PreparedImage?> Function(ImagePrepareRequest);

/// Whether the upload path prepares this MIME type (JPEG and PNG only:
/// GIF/WebP may be animated and are sent untouched).
bool isPreparableImage(String mimeType) {
  final mime = mimeType.split(';').first.trim().toLowerCase();
  return mime == 'image/jpeg' || mime == 'image/jpg' || mime == 'image/png';
}

/// Runs [prepareImageSync] in a background isolate.
Future<PreparedImage?> prepareImageForUpload(ImagePrepareRequest request) =>
    compute(prepareImageSync, request);

/// Reads dimensions, optionally downscales/re-encodes (JPEG quality 80, PNG
/// stays PNG) to a 2048 px long edge, and creates a thumbnail for images
/// larger than 800×600. Re-encoding drops EXIF (including location) after
/// applying its orientation. Returns null for unreadable or unsupported
/// images, which are then sent unchanged.
PreparedImage? prepareImageSync(ImagePrepareRequest request) {
  if (!isPreparableImage(request.mimeType)) return null;
  final bytes = request.bytes;
  final jpeg = !request.mimeType.toLowerCase().contains('png');
  final decoder = jpeg ? img.JpegDecoder() : img.PngDecoder();
  final img.DecodeInfo? header;
  try {
    if (!decoder.isValidFile(bytes)) return null;
    header = decoder.startDecode(bytes);
  } catch (_) {
    return null;
  }
  if (header == null) return null;
  final rawWidth = header.width, rawHeight = header.height;
  if (rawWidth <= 0 ||
      rawHeight <= 0 ||
      rawWidth > 30000 ||
      rawHeight > 30000) {
    return null;
  }
  var orientation = 1;
  if (jpeg) {
    final exif = img.decodeJpgExif(bytes);
    orientation = exif?.imageIfd.orientation ?? 1;
  }
  final swapped = orientation >= 5 && orientation <= 8;
  final width = swapped ? rawHeight : rawWidth;
  final height = swapped ? rawWidth : rawHeight;
  final longEdge = math.max(width, height);

  final resize = request.optimise && longEdge > optimisedImageEdge;
  final reencode =
      resize || (request.optimise && jpeg && bytes.length > 1536 * 1024);
  final wantThumbnail =
      width > thumbnailMaxWidth || height > thumbnailMaxHeight;
  final dimensionsOnly = PreparedImage(
    bytes: bytes,
    mimeType: jpeg ? 'image/jpeg' : 'image/png',
    width: width,
    height: height,
  );
  if (!reencode && !wantThumbnail) return dimensionsOnly;

  // Decode at the smallest JPEG scale that still covers the target edge.
  final target = reencode ? optimisedImageEdge : thumbnailMaxWidth;
  var scale = 1;
  if (jpeg) {
    while (scale < 8 && longEdge / (scale * 2) >= target) {
      scale *= 2;
    }
  }
  final pixels = (rawWidth ~/ scale) * (rawHeight ~/ scale);
  if (pixels > _maxDecodePixels) return dimensionsOnly;
  img.Image? decoded;
  try {
    decoded = jpeg
        ? img.decodeJpg(bytes, maxPixels: _maxDecodePixels, scale: scale)
        : img.decodePng(bytes);
  } catch (_) {
    return dimensionsOnly;
  }
  if (decoded == null) return dimensionsOnly;
  // Apply EXIF orientation, then drop all metadata from re-encoded output.
  var oriented = img.bakeOrientation(decoded);
  oriented.exif = img.ExifData();

  var outBytes = bytes;
  var outWidth = width, outHeight = height;
  var optimised = false;
  if (reencode) {
    final edge = math.max(oriented.width, oriented.height);
    final resized = edge > optimisedImageEdge
        ? (oriented.width >= oriented.height
              ? img.copyResize(
                  oriented,
                  width: optimisedImageEdge,
                  interpolation: img.Interpolation.average,
                )
              : img.copyResize(
                  oriented,
                  height: optimisedImageEdge,
                  interpolation: img.Interpolation.average,
                ))
        : oriented;
    resized.exif = img.ExifData();
    final encoded = jpeg
        ? img.encodeJpg(resized, quality: optimisedImageQuality)
        : img.encodePng(resized);
    if (resize || encoded.length < bytes.length) {
      outBytes = encoded;
      outWidth = resized.width;
      outHeight = resized.height;
      optimised = true;
      oriented = resized;
    }
  }

  Uint8List? thumbnail;
  int? thumbWidth, thumbHeight;
  String? thumbMime;
  if (outWidth > thumbnailMaxWidth || outHeight > thumbnailMaxHeight) {
    final ratio = math.min(
      thumbnailMaxWidth / oriented.width,
      thumbnailMaxHeight / oriented.height,
    );
    final thumb = img.copyResize(
      oriented,
      width: math.max(1, (oriented.width * ratio).round()),
      height: math.max(1, (oriented.height * ratio).round()),
      interpolation: img.Interpolation.average,
    );
    thumb.exif = img.ExifData();
    // JPEG would flatten transparency to black; keep alpha images as PNG.
    final alpha = thumb.hasAlpha;
    thumbnail = alpha
        ? img.encodePng(thumb)
        : img.encodeJpg(thumb, quality: 75);
    thumbMime = alpha ? 'image/png' : 'image/jpeg';
    thumbWidth = thumb.width;
    thumbHeight = thumb.height;
    if (thumbnail.length >= outBytes.length) {
      thumbnail = null;
      thumbMime = null;
      thumbWidth = thumbHeight = null;
    }
  }
  return PreparedImage(
    bytes: outBytes,
    mimeType: jpeg ? 'image/jpeg' : 'image/png',
    width: outWidth,
    height: outHeight,
    optimised: optimised,
    thumbnail: thumbnail,
    thumbnailMimeType: thumbMime,
    thumbnailWidth: thumbWidth,
    thumbnailHeight: thumbHeight,
  );
}
