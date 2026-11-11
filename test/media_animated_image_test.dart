import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parallax/features/media/animated_media_image.dart';

import 'media_test_support.dart';

Uint8List twoFrameGif() {
  final first = img.Image(width: 4, height: 4)..frameDuration = 40;
  img.fill(first, color: img.ColorRgb8(255, 0, 0));
  final second = img.Image(width: 4, height: 4)..frameDuration = 40;
  img.fill(second, color: img.ColorRgb8(0, 0, 255));
  first.addFrame(second);
  return img.encodeGif(first);
}

void main() {
  testWidgets('animated GIF advances frames and releases them on dispose', (
    tester,
  ) async {
    final poster = (await tester.runAsync(() => makeImage(4, 4)))!;
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 40,
          height: 40,
          child: AnimatedMediaImage(bytes: twoFrameGif(), poster: poster),
        ),
      ),
    );
    ui.Image? shown() => tester.widget<RawImage>(find.byType(RawImage)).image;
    var advanced = false;
    for (var i = 0; i < 20 && !advanced; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final image = shown();
      advanced = image != null && !image.isCloneOf(poster);
    }
    expect(advanced, isTrue, reason: 'decoded frames replace the poster');
    await tester.pumpWidget(const SizedBox());
    expect(poster.debugDisposed, isFalse, reason: 'poster is not owned');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion keeps the first-frame poster', (tester) async {
    final poster = (await tester.runAsync(() => makeImage(4, 4)))!;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AnimatedMediaImage(bytes: twoFrameGif(), poster: poster),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(image.isCloneOf(poster), isTrue);
  });

  testWidgets('corrupt animation data falls back to the poster', (
    tester,
  ) async {
    final poster = (await tester.runAsync(() => makeImage(4, 4)))!;
    await tester.pumpWidget(
      host(
        AnimatedMediaImage(
          bytes: Uint8List.fromList([0x47, 0x49, 0x46, 1, 2, 3]),
          poster: poster,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image!.isCloneOf(poster),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
