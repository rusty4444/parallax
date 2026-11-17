// PDF previews end to end on a real Android device or emulator. A fake
// account supplies the file; the isolated renderer, the timeline thumbnail
// and the viewer are the real ones.
//   flutter test integration_test/pdf_preview_test.dart -d <device>
// Add --dart-define=PARALLAX_HOLD=true to pause on each screen (it prints
// PARALLAX_SCREEN <name>) for `adb exec-out screencap -p`.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/file_preview/inline_document_preview.dart';
import 'package:parallax/features/media/media_hooks.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';

import '../test/media_test_support.dart';
import '../test/pdf_fixtures.dart';

const holdForScreenshots = bool.fromEnvironment('PARALLAX_HOLD');

Future<void> hold(WidgetTester tester, String name) async {
  if (!holdForScreenshots) return;
  // ignore: avoid_print
  print('PARALLAX_SCREEN $name');
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps frames until [finder] matches (the renderer is another process).
Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

Future<List<int>> pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final at = (y * image.width + x) * 4;
  return [
    data!.getUint8(at),
    data.getUint8(at + 1),
    data.getUint8(at + 2),
    data.getUint8(at + 3),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  FakeMediaBackend backend() => FakeMediaBackend()
    ..original = (_) => DownloadedAttachment(
      name: 'Quarterly report.pdf',
      mimeType: 'application/pdf',
      bytes: samplePdf,
    );
  final entry = mediaEntry(
    r'$pdf',
    EntryKind.file,
    body: 'Quarterly report.pdf',
    content: {
      'info': {'mimetype': 'application/pdf', 'size': samplePdf.length},
    },
  );

  ui.Image imageOf(WidgetTester tester, Finder within) => tester
      .widget<RawImage>(
        find.descendant(of: within, matching: find.byType(RawImage)),
      )
      .image!;

  testWidgets('a PDF in the timeline shows the top of its first page', (
    tester,
  ) async {
    final account = backend();
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) =>
              mediaEntryBody(context, hookFor(account, entry)) ??
              const Text('none'),
        ),
      ),
    );
    const key = ValueKey('document.inline.pdf');
    await waitFor(tester, find.byKey(key));
    final strip = tester.widget<RawImage>(find.byKey(key)).image!;
    final ratio = tester.view.devicePixelRatio;
    expect(strip.width, (InlineDocumentPreview.width * ratio).round());
    expect(strip.height, (InlineDocumentPreview.height * ratio).round());
    // White paper with the title's ink on it.
    expect(await pixel(strip, 3, 3), [255, 255, 255, 255]);
    final data = await strip.toByteData(format: ui.ImageByteFormat.rawRgba);
    var ink = 0;
    for (var at = 0; at < data!.lengthInBytes; at += 4) {
      if (data.getUint8(at) < 128) ink++;
    }
    expect(ink, greaterThan(300));
    expect(find.text('Quarterly report.pdf'), findsOneWidget);
    expect(account.loads, [r'$pdf']);
    await hold(tester, 'timeline');
  });

  testWidgets('the viewer shows the real pages, scrolls and zooms', (
    tester,
  ) async {
    final account = backend();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewerPager(
          backend: account,
          roomId: roomId,
          items: mediaViewerItems(account, roomId, entry.id, entries: [entry]),
        ),
      ),
    );
    final pageOne = find.byKey(const ValueKey('document.pdf.page.0'));
    final pageTwo = find.byKey(const ValueKey('document.pdf.page.1'));
    await waitFor(
      tester,
      find.descendant(of: pageOne, matching: find.byType(RawImage)),
    );
    expect(find.text('1 / 3'), findsOneWidget);
    final box = tester.getSize(pageOne);
    expect(box.height / box.width, closeTo(842 / 595, 0.01));

    // Drawn at the screen's resolution (up to the limit), A4 in shape, with
    // the fixture's black block where it belongs.
    final ratio = tester.view.devicePixelRatio;
    final first = imageOf(tester, pageOne);
    expect(first.width, math.min(1600, (box.width * ratio).round()));
    expect(first.width / first.height, closeTo(595 / 842, 0.01));
    expect(
      await pixel(
        first,
        (first.width * 200 / 595).round(),
        (first.height * 692 / 842).round(),
      ),
      [0, 0, 0, 255],
    );
    expect(await pixel(first, 4, 4), [255, 255, 255, 255]);
    await hold(tester, 'viewer-page-1');

    // Drag until the second page (landscape, red) is a third of the way
    // down the screen: the counter moves on to it.
    const list = ValueKey('document.pdf');
    final screen = tester.getSize(find.byKey(list)).height;
    final pageTwoTop = 8 + box.height + 8;
    await tester.drag(
      find.byKey(list),
      // 40 past the point where it changes, plus the touch slop.
      Offset(0, -(pageTwoTop - screen / 3 + 40 + 20)),
    );
    await waitFor(
      tester,
      find.descendant(of: pageTwo, matching: find.byType(RawImage)),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    final second = imageOf(tester, pageTwo);
    // Kept as a number: the image is disposed once a sharper one replaces it.
    final secondWidth = second.width;
    expect(second.width / second.height, closeTo(842 / 595, 0.01));
    expect(await pixel(second, second.width ~/ 2, second.height * 3 ~/ 4), [
      255,
      0,
      0,
      255,
    ]);
    await hold(tester, 'viewer-page-2');

    // At the end of the document the counter shows the last page, even
    // though this short one (a 200 point square) is low on the screen.
    await tester.drag(find.byKey(list), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    await hold(tester, 'viewer-end');

    // Double-tap zooms in, and the page is drawn again with more pixels.
    final viewer = find.byType(InteractiveViewer);
    final centre = tester.getCenter(pageTwo);
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis(),
      closeTo(2.5, 0.01),
    );
    for (
      var i = 0;
      i < 100 && imageOf(tester, pageTwo).width <= secondWidth;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final sharper = imageOf(tester, pageTwo);
    expect(sharper.width, greaterThan(secondWidth));
    expect(await pixel(sharper, sharper.width ~/ 2, sharper.height * 3 ~/ 4), [
      255,
      0,
      0,
      255,
    ]);
    await hold(tester, 'viewer-zoomed');

    // Closing the viewer lets go of the document.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });
}
