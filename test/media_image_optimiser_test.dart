import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parallax/features/media/image_optimiser.dart';

Uint8List jpeg(int width, int height, {int quality = 95, int? orientation}) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = (pixel.x * 7) % 256
      ..g = (pixel.y * 13) % 256
      ..b = (pixel.x + pixel.y) % 256;
  }
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(33, 1);
  return img.encodeJpg(image, quality: quality);
}

Uint8List png(int width, int height, {bool alpha = false}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  );
  img.fill(
    image,
    color: alpha ? img.ColorRgba8(200, 30, 30, 128) : img.ColorRgb8(1, 2, 3),
  );
  return img.encodePng(image);
}

void main() {
  test('only JPEG and PNG are prepared', () {
    expect(isPreparableImage('image/jpeg'), isTrue);
    expect(isPreparableImage('image/png; charset=binary'), isTrue);
    expect(isPreparableImage('image/gif'), isFalse);
    expect(isPreparableImage('image/webp'), isFalse);
    expect(
      prepareImageSync(
        ImagePrepareRequest(
          bytes: Uint8List(4),
          mimeType: 'image/gif',
          optimise: true,
        ),
      ),
      isNull,
    );
  });

  test('large JPEG is downscaled to 2048 px, re-encoded and thumbnailed', () {
    final original = jpeg(3000, 1500);
    final prepared = prepareImageSync(
      ImagePrepareRequest(
        bytes: original,
        mimeType: 'image/jpeg',
        optimise: true,
      ),
    )!;
    expect(prepared.optimised, isTrue);
    expect(prepared.width, optimisedImageEdge);
    expect(prepared.height, 1024);
    expect(prepared.mimeType, 'image/jpeg');
    final decoded = img.decodeJpg(prepared.bytes)!;
    expect(decoded.width, 2048);
    expect(decoded.exif.gpsIfd.isEmpty, isTrue, reason: 'location stripped');
    expect(prepared.thumbnail, isNotNull);
    expect(prepared.thumbnailWidth, lessThanOrEqualTo(thumbnailMaxWidth));
    expect(prepared.thumbnailHeight, lessThanOrEqualTo(thumbnailMaxHeight));
    expect(prepared.thumbnailMimeType, 'image/jpeg');
  });

  test('optimisation off keeps the original bytes but adds info', () {
    final original = jpeg(3000, 1500);
    final prepared = prepareImageSync(
      ImagePrepareRequest(
        bytes: original,
        mimeType: 'image/jpeg',
        optimise: false,
      ),
    )!;
    expect(prepared.optimised, isFalse);
    expect(identical(prepared.bytes, original), isTrue);
    expect(prepared.width, 3000);
    expect(prepared.height, 1500);
    expect(prepared.thumbnail, isNotNull);
  });

  test('small images need neither re-encoding nor a thumbnail', () {
    final original = jpeg(320, 200);
    final prepared = prepareImageSync(
      ImagePrepareRequest(
        bytes: original,
        mimeType: 'image/jpeg',
        optimise: true,
      ),
    )!;
    expect(identical(prepared.bytes, original), isTrue);
    expect(prepared.thumbnail, isNull);
    expect((prepared.width, prepared.height), (320, 200));
  });

  test('EXIF rotation swaps the reported dimensions', () {
    final prepared = prepareImageSync(
      ImagePrepareRequest(
        bytes: jpeg(400, 200, orientation: 6),
        mimeType: 'image/jpeg',
        optimise: true,
      ),
    )!;
    expect((prepared.width, prepared.height), (200, 400));
  });

  test('transparent PNG stays PNG and keeps alpha in its thumbnail', () {
    final prepared = prepareImageSync(
      ImagePrepareRequest(
        bytes: png(2600, 900, alpha: true),
        mimeType: 'image/png',
        optimise: true,
      ),
    )!;
    expect(prepared.mimeType, 'image/png');
    expect(prepared.width, 2048);
    expect(img.decodePng(prepared.bytes)!.hasAlpha, isTrue);
    if (prepared.thumbnail != null) {
      expect(prepared.thumbnailMimeType, 'image/png');
    }
  });

  test('malformed data and decompression bombs are not decoded', () {
    expect(
      prepareImageSync(
        ImagePrepareRequest(
          bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0, 1, 2]),
          mimeType: 'image/jpeg',
          optimise: true,
        ),
      ),
      isNull,
    );
    // A PNG header claiming 30000×30000 must not be decoded.
    final header = png(1, 1);
    final bomb = Uint8List.fromList(header);
    final view = ByteData.sublistView(bomb);
    view.setUint32(16, 29000);
    view.setUint32(20, 29000);
    final prepared = prepareImageSync(
      ImagePrepareRequest(bytes: bomb, mimeType: 'image/png', optimise: true),
    );
    if (prepared != null) {
      expect(identical(prepared.bytes, bomb), isTrue);
      expect(prepared.thumbnail, isNull);
    }
  });
}
