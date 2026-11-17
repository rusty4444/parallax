// Visual QA for zooming a picture in the media viewer. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/media_zoom_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';

import 'media_test_support.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];

Future<void> _loadFonts() async {
  final grotesk = FontLoader('SpaceGrotesk')
    ..addFont(
      File(
        'assets/fonts/SpaceGrotesk.ttf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  await grotesk.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  }
}

/// A landscape "photo" whose edges and corners are easy to recognise.
Future<ui.Image> _photo() async {
  const width = 1600.0;
  const height = 1066.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(width, height),
        [
          const Color(0xff1d3557),
          const Color(0xff2a9d8f),
          const Color(0xffe9c46a),
        ],
        const [0, 0.55, 1],
      ),
  );
  final grid = Paint()
    ..color = const Color(0x55ffffff)
    ..strokeWidth = 3;
  for (var x = 0.0; x <= width; x += 100) {
    canvas.drawLine(Offset(x, 0), Offset(x, height), grid);
  }
  for (var y = 0.0; y <= height; y += 100) {
    canvas.drawLine(Offset(0, y), Offset(width, y), grid);
  }
  canvas.drawCircle(
    const Offset(width / 2, height / 2),
    180,
    Paint()..color = const Color(0xfff4a261),
  );
  canvas.drawCircle(
    const Offset(width / 2, height / 2),
    60,
    Paint()..color = const Color(0xff264653),
  );
  const corner = 140.0;
  for (final (offset, colour) in [
    (Offset.zero, const Color(0xff2ecc71)),
    (const Offset(width - corner, 0), const Color(0xff3498db)),
    (const Offset(0, height - corner), const Color(0xfff1c40f)),
    (const Offset(width - corner, height - corner), const Color(0xffe84393)),
  ]) {
    canvas.drawRect(
      offset & const Size(corner, corner),
      Paint()..color = colour,
    );
  }
  canvas.drawRect(
    const Rect.fromLTWH(8, 8, width - 16, height - 16),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..color = const Color(0xffe63946),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width.toInt(), height.toInt());
  } finally {
    picture.dispose();
  }
}

Future<void> _pinch(
  WidgetTester tester,
  Offset centre, {
  required double from,
  required double to,
}) async {
  final first = await tester.startGesture(
    centre - Offset(from / 2, 0),
    pointer: 7,
  );
  final second = await tester.startGesture(
    centre + Offset(from / 2, 0),
    pointer: 8,
  );
  await tester.pump();
  for (var step = 1; step <= 12; step++) {
    final half = (from + (to - from) * step / 12) / 2;
    await first.moveTo(centre - Offset(half, 0));
    await second.moveTo(centre + Offset(half, 0));
    await tester.pump();
  }
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });

  testWidgets('zooming a landscape photo', skip: _dir == null, (tester) async {
    final image = (await tester.runAsync(_photo))!;
    final backend = FakeMediaBackend()
      ..original = (id) => DownloadedAttachment(
        name: 'image-1689993.jpg',
        mimeType: 'image/jpeg',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
    final entry = mediaEntry(
      'photo',
      EntryKind.image,
      body: 'image-1689993.jpg',
    );
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    tester.view.padding = const FakeViewPadding(top: 80, bottom: 60);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(VisualTheme.parallax),
          home: MediaViewerPager(
            backend: backend,
            roomId: roomId,
            items: mediaViewerItems(
              backend,
              roomId,
              entry.id,
              entries: [entry],
            ),
            imageDecoder: (_) async => image,
          ),
        ),
      ),
    );
    await settle(tester);

    Future<void> shoot(String name) => tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final shot = await boundary.toImage(pixelRatio: 2);
      final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
      await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });

    final centre = tester.getCenter(find.byType(RawImage));
    await shoot('media_zoom_1_rest');
    await _pinch(tester, centre, from: 100, to: 230);
    await shoot('media_zoom_2_part');
    await _pinch(tester, centre, from: 60, to: 330);
    await shoot('media_zoom_3_filled');
    await tester.dragFrom(centre, const Offset(3000, 3000));
    await tester.pumpAndSettle();
    await shoot('media_zoom_4_corner');
  });
}
