import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/image_editor_screen.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/photo_picker.dart';
import 'package:parallax/rich_message_composer.dart';

Uint8List _blueImage() {
  final image = img.Image(width: 120, height: 80, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(20, 60, 180));
  return img.encodePng(image);
}

void main() {
  test('rotation and crop produce the expected dimensions and JPEG name', () {
    final rotated = processImageEdit(
      ImageEditSpec(
        bytes: _blueImage(),
        name: 'photo.png',
        rotation: 1,
        crop: const Rect.fromLTWH(0, 0, 1, 1),
        strokes: const [],
      ),
    );
    final rotatedPixels = img.decodeJpg(rotated.bytes)!;
    expect(rotatedPixels.width, 80);
    expect(rotatedPixels.height, 120);
    expect(rotated.name, 'photo-edited.jpg');
    expect(rotated.mimeType, 'image/jpeg');

    final cropped = processImageEdit(
      ImageEditSpec(
        bytes: _blueImage(),
        name: 'photo.png',
        rotation: 0,
        crop: const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
        strokes: const [],
      ),
    );
    final croppedPixels = img.decodeJpg(cropped.bytes)!;
    expect(croppedPixels.width, 60);
    expect(croppedPixels.height, 40);
  });

  test('markup is rendered into the exported image', () {
    final edited = processImageEdit(
      ImageEditSpec(
        bytes: _blueImage(),
        name: 'photo.png',
        rotation: 0,
        crop: const Rect.fromLTWH(0, 0, 1, 1),
        strokes: const [
          MarkupStroke(
            color: 0xFFFF5252,
            points: [Offset(0.2, 0.5), Offset(0.8, 0.5)],
          ),
        ],
      ),
    );
    final pixels = img.decodeJpg(edited.bytes)!;
    final centre = pixels.getPixel(60, 40);
    expect(centre.r, greaterThan(150));
    expect(centre.g, lessThan(130));
    expect(centre.b, lessThan(130));
  });

  testWidgets('composer sends the edited image bytes', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    MediaSelection? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RichMessageComposer(
            controller: controller,
            sending: false,
            pickGallery: () async => MediaSelection(
              bytes: _blueImage(),
              name: 'photo.png',
              mimeType: 'image/png',
            ),
            onSend: (_, media) async => sent = media,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Attach media'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo or video'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit image'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit image'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageEditorScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Rotate image'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('photo-edited.jpg'), findsOneWidget);

    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(sent, isNotNull);
    expect(sent!.mimeType, 'image/jpeg');
    final pixels = img.decodeJpg(sent!.bytes)!;
    expect(pixels.width, 80);
    expect(pixels.height, 120);
  });

  testWidgets('photo gallery sends the edited image bytes', (tester) async {
    final backend = _GalleryBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickAndSendImages(
              context,
              backend,
              '!room:example.org',
              picker: () async => [
                XFile.fromData(
                  _blueImage(),
                  path: 'photo.png',
                  name: 'photo.png',
                  mimeType: 'image/png',
                ),
              ],
            ),
            child: const Text('Open gallery'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open gallery'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit photo 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Rotate image'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send photos'));
    await tester.pumpAndSettle();

    final sent = backend.sent!.single;
    expect(sent.name, 'photo-edited.jpg');
    expect(sent.mimeType, 'image/jpeg');
    final pixels = img.decodeJpg(await sent.readAsBytes())!;
    expect(pixels.width, 80);
    expect(pixels.height, 120);
  });

  test('invalid image data is rejected instead of changing the original', () {
    final source = Uint8List.fromList([1, 2, 3]);
    expect(
      () => processImageEdit(
        ImageEditSpec(
          bytes: source,
          name: 'broken.png',
          rotation: 0,
          crop: const Rect.fromLTWH(0, 0, 1, 1),
          strokes: const [],
        ),
      ),
      throwsFormatException,
    );
    expect(source, [1, 2, 3]);
  });
}

class _GalleryBackend extends ChatBackend {
  List<XFile>? sent;

  @override
  bool get sending => false;

  @override
  Future<void> sendImages(String roomId, List<XFile> images) async {
    sent = List.of(images);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
