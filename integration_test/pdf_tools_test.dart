// The native PDF renderer on a real Android device or emulator:
//   flutter test integration_test/pdf_tools_test.dart -d <device>
// While it runs, `adb shell ps -A | grep parallax` shows the renderer as its
// own process (net.samrussell.parallax:pdf) under an isolated user ID.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parallax/features/file_preview/pdf_tools.dart';

import '../test/pdf_fixtures.dart';

/// RGBA of the pixel at ([x], [y]).
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

  for (final viaFile in [false, true]) {
    final how = viaFile ? 'a temporary file' : 'memory';
    final tools = PlatformPdfTools(viaFile: viaFile);

    testWidgets('pages render at the asked size, handed over through $how', (
      tester,
    ) async {
      final document = await tools.open(samplePdf);
      addTearDown(document.close);
      expect(document.pageCount, 3);
      expect(document.pageSize(0), const ui.Size(595, 842));
      expect(document.pageSize(1), const ui.Size(842, 595));
      expect(document.pageSize(2), const ui.Size(200, 200));

      final first = await document.render(0, width: 595);
      expect((first.width, first.height), (595, 842));
      // Paper is white; the block (y is measured from the top here) is black.
      expect(await pixel(first, 5, 5), [255, 255, 255, 255]);
      expect(await pixel(first, 200, 692), [0, 0, 0, 255]);
      expect(await pixel(first, 400, 692), [255, 255, 255, 255]);
      // The title is drawn (some pixel in its band is not white).
      final band = await first.toByteData(format: ui.ImageByteFormat.rawRgba);
      var ink = 0;
      for (var y = 60; y < 90; y++) {
        for (var x = 72; x < 330; x++) {
          if (band!.getUint8((y * 595 + x) * 4) < 128) ink++;
        }
      }
      expect(ink, greaterThan(200));
      first.dispose();

      final second = await document.render(1, width: 421);
      expect((second.width, second.height), (421, 298));
      expect(await pixel(second, 300, 200), [255, 0, 0, 255]);
      second.dispose();

      final third = await document.render(2, width: 100);
      expect((third.width, third.height), (100, 100));
      expect(await pixel(third, 50, 50), [0, 0, 255, 255]);
      third.dispose();
    });
  }

  testWidgets('a strip is the top of the page; huge requests are scaled down', (
    tester,
  ) async {
    final document = await PdfTools.instance.open(samplePdf);
    addTearDown(document.close);
    final strip = await document.render(0, width: 726, height: 270);
    expect((strip.width, strip.height), (726, 270));
    expect(await pixel(strip, 5, 5), [255, 255, 255, 255]);
    strip.dispose();

    // A4 at 4000 px wide would be 22 megapixels.
    final huge = await document.render(0, width: 4000);
    expect(huge.width * huge.height, lessThanOrEqualTo(8000000));
    expect(huge.width / huge.height, closeTo(595 / 842, 0.01));
    // Still the whole page: the block is where it should be.
    final scale = huge.width / 595;
    expect(await pixel(huge, (200 * scale).round(), (692 * scale).round()), [
      0,
      0,
      0,
      255,
    ]);
    huge.dispose();
  });

  testWidgets('locked and damaged files are refused, and the renderer '
      'carries on', (tester) async {
    await expectLater(
      PdfTools.instance.open(lockedPdf),
      throwsA(
        isA<PdfException>().having(
          (e) => e.failure,
          'failure',
          PdfFailure.passwordProtected,
        ),
      ),
    );
    for (final bytes in [
      Uint8List.fromList('not a pdf at all'.codeUnits),
      // A real header followed by nothing useful.
      Uint8List.fromList([...samplePdf.take(40), ...List.filled(400, 0x41)]),
      Uint8List.sublistView(samplePdf, 0, samplePdf.length ~/ 3),
    ]) {
      await expectLater(
        PdfTools.instance.open(bytes),
        throwsA(
          isA<PdfException>().having(
            (e) => e.failure,
            'failure',
            PdfFailure.unreadable,
          ),
        ),
      );
    }
    final document = await PdfTools.instance.open(samplePdf);
    expect(document.pageCount, 3);
    await expectLater(
      document.render(7, width: 100),
      throwsA(isA<PdfException>()),
    );
    final page = await document.render(2, width: 50);
    expect(page.width, 50);
    page.dispose();
    await document.close();
    // Closed means closed.
    await expectLater(
      document.render(0, width: 100),
      throwsA(isA<PdfException>()),
    );
  });

  testWidgets('only a few documents are open at once', (tester) async {
    final documents = <PdfDocument>[];
    for (var i = 0; i < 4; i++) {
      documents.add(await PdfTools.instance.open(samplePdf));
    }
    await expectLater(
      PdfTools.instance.open(samplePdf),
      throwsA(isA<PdfException>()),
    );
    await documents.removeLast().close();
    documents.add(await PdfTools.instance.open(samplePdf));
    // Renders are answered in order, whichever document they are for.
    final pages = await Future.wait([
      for (final document in documents) document.render(2, width: 64),
    ]);
    for (final page in pages) {
      expect(await pixel(page, 32, 32), [0, 0, 255, 255]);
      page.dispose();
    }
    for (final document in documents) {
      await document.close();
    }
  });

  testWidgets('a larger file crosses to the renderer intact', (tester) async {
    // Padding after %%EOF: PDF readers ignore it, and it makes the hand-over
    // several megabytes.
    final padded = Uint8List(6 * 1024 * 1024 + samplePdf.length)
      ..setAll(0, samplePdf)
      ..fillRange(samplePdf.length, 6 * 1024 * 1024 + samplePdf.length, 0x0A);
    final document = await PdfTools.instance.open(padded);
    expect(document.pageCount, 3);
    final page = await document.render(1, width: 200);
    expect(await pixel(page, 100, 70), [255, 0, 0, 255]);
    page.dispose();
    await document.close();
  });
}
