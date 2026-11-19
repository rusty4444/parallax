import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_bubbles.dart';
import 'package:parallax/features/media/media_content.dart';
import 'package:parallax/gallery_bubble.dart';
import 'package:parallax/message_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_test_support.dart';

/// A real (1×1) PNG so Image.memory decodes under the test binding.
Uint8List get pngBytes => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

ChatEntry gifEntry(
  String id, {
  int? w,
  int? h,
  String mime = 'image/gif',
  int size = 2048,
}) => mediaEntry(
  id,
  EntryKind.image,
  body: '$id.gif',
  content: {
    'msgtype': 'm.image',
    'info': {'mimetype': mime, 'size': size, 'w': ?w, 'h': ?h},
  },
);

FakeMediaBackend gifBackend() => FakeMediaBackend()
  ..previewBytes = pngBytes
  ..original = (eventId) => DownloadedAttachment(
    name: '$eventId.gif',
    mimeType: 'image/gif',
    bytes: pngBytes,
  );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    debugDecodeImageSize = null;
  });

  group('gifPreviewSize', () {
    test('keeps the media aspect with no minimum height', () {
      // Wide GIF: a short strip, not a cropped 110-high box.
      expect(gifPreviewSize(2.5, maxWidth: 240), const Size(240, 96));
      expect(gifPreviewSize(5, maxWidth: 240), const Size(240, 48));
      // Square and portrait.
      expect(gifPreviewSize(1, maxWidth: 240), const Size(240, 240));
      expect(gifPreviewSize(0.5, maxWidth: 240), const Size(160, 320));
      // Unknown aspect keeps the caller's fallback box.
      expect(
        gifPreviewSize(null, maxWidth: 228, fallbackHeight: 170),
        const Size(228, 170),
      );
      // Hostile ratios stay clamped.
      expect(gifPreviewSize(100, maxWidth: 240), const Size(240, 48));
      expect(gifPreviewSize(0.001, maxWidth: 240), const Size(64, 320));
    });
  });

  group('GIF previews fit their own shape', () {
    testWidgets('the real probe returns intrinsic dimensions', (tester) async {
      final size = await tester.runAsync(() => probeImageSize(pngBytes));
      expect(size, const Size(1, 1));
    });

    testWidgets('the real probe preserves extreme portrait and wide sizes', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final size in [const Size(8, 1600), const Size(1600, 8)]) {
          final image = await makeImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          try {
            final encoded = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            expect(encoded, isNotNull);
            // The probe frame is fitted to 64×64, but callers need the
            // original dimensions, not the tiny frame's rounded aspect.
            expect(await probeImageSize(encoded!.buffer.asUint8List()), size);
          } finally {
            image.dispose();
          }
        }
      });
    });

    testWidgets(
      'a late probe cannot size a replacement entry with the same ID',
      (tester) async {
        final decoded = Completer<Size>();
        var probes = 0;
        debugDecodeImageSize = (_) {
          probes++;
          return decoded.future;
        };
        final backend = gifBackend();
        Widget preview(ChatEntry entry) => host(
          MessageImage(
            key: const ValueKey('preview'),
            backend: backend,
            palette: palette,
            roomId: roomId,
            eventId: entry.id,
            entry: entry,
          ),
        );
        final original = gifEntry('g');
        await tester.pumpWidget(preview(original));
        await settle(tester);
        expect(probes, 1);
        expect(tester.getSize(find.byType(MessageImage)), const Size(228, 170));

        final replacement = gifEntry('g');
        expect(identical(original, replacement), isFalse);
        await tester.pumpWidget(preview(replacement));
        decoded.complete(const Size(300, 600));
        await settle(tester);
        expect(tester.getSize(find.byType(MessageImage)), const Size(228, 170));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('declared dimensions size the preview without cropping', (
      tester,
    ) async {
      final backend = gifBackend();
      await tester.pumpWidget(
        host(
          ImageMessageBody(
            ctx: hookFor(backend, gifEntry('g', w: 400, h: 200)),
          ),
        ),
      );
      await settle(tester);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 240);
      expect(image.height, 120);
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('a wide GIF is a strip, not a cropped box', (tester) async {
      final backend = gifBackend();
      await tester.pumpWidget(
        host(
          ImageMessageBody(
            ctx: hookFor(backend, gifEntry('g', w: 1000, h: 200)),
          ),
        ),
      );
      await settle(tester);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.width, 240);
      expect(image.height, 48);
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('a tall GIF is capped in height and keeps its aspect', (
      tester,
    ) async {
      final backend = gifBackend();
      await tester.pumpWidget(
        host(
          ImageMessageBody(
            ctx: hookFor(backend, gifEntry('g', w: 200, h: 800)),
          ),
        ),
      );
      await settle(tester);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.height, 320);
      expect(image.width, 80);
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('no declared dimensions: decoded size drives the box', (
      tester,
    ) async {
      debugDecodeImageSize = (_) async => const Size(300, 600);
      final backend = gifBackend();
      await tester.pumpWidget(
        host(ImageMessageBody(ctx: hookFor(backend, gifEntry('g')))),
      );
      await settle(tester);
      final image = tester.widget<Image>(find.byType(Image));
      // 240 wide would be 480 tall; the 320 cap scales it to 160×320.
      expect(image.width, 160);
      expect(image.height, 320);
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('the placeholder uses the declared aspect before loading', (
      tester,
    ) async {
      final backend = gifBackend()
        ..previewBytes = null
        ..original = (_) => throw StateError('original unavailable');
      await tester.pumpWidget(
        host(
          ImageMessageBody(
            ctx: hookFor(backend, gifEntry('g', w: 400, h: 200)),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Image unavailable'), findsOneWidget);
      final box = tester.getSize(find.byType(MessageImage));
      expect(box.width, 240);
      expect(box.height, 120);
    });

    testWidgets('static images keep the fixed cover box', (tester) async {
      final backend = gifBackend();
      await tester.pumpWidget(
        host(
          ImageMessageBody(
            ctx: hookFor(
              backend,
              mediaEntry(
                'p',
                EntryKind.image,
                content: {
                  'msgtype': 'm.image',
                  'info': {'mimetype': 'image/jpeg'},
                },
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.cover);
      expect(image.width, 240);
      expect(image.height, closeTo(240 * 0.72, 0.01));
    });

    testWidgets('gallery mosaics keep their fixed grid cells', (tester) async {
      final backend = gifBackend();
      final entries = [
        gifEntry('a', w: 400, h: 200),
        gifEntry('b', w: 200, h: 800),
      ];
      await tester.pumpWidget(
        host(
          GalleryBubble(
            entries: entries,
            backend: backend,
            roomId: roomId,
            palette: palette,
            onHeart: (ChatEntry _) {},
            onAction: (ChatEntry _) {},
            onReaction: (ChatEntry _, String _) {},
          ),
        ),
      );
      await settle(tester);
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images.length, 2);
      for (final image in images) {
        expect(image.fit, BoxFit.cover);
        expect(image.height, 170);
      }
    });
  });
}
