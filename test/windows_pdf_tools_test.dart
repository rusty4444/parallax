import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parallax/features/file_preview/pdf_tools.dart';
import 'package:parallax/features/file_preview/windows_pdf_tools.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:pdfx/src/renderer/interfaces/platform.dart';

/// A 10x20 white PNG, the fake renderer's output.
final _png = Uint8List.fromList(
  img.encodePng(img.Image(width: 10, height: 20)),
);

class _FakePlatform extends PdfxPlatform {
  _FakePlatform(this._open);
  final Future<pdfx.PdfDocument> Function() _open;

  @override
  Future<pdfx.PdfDocument> openData(FutureOr<Uint8List> data, {String? password}) =>
      _open();

  @override
  Future<pdfx.PdfDocument> openFile(String filePath, {String? password}) => _open();

  @override
  Future<pdfx.PdfDocument> openAsset(String name, {String? password}) => _open();
}

class _FakeDocument extends pdfx.PdfDocument {
  _FakeDocument({required int pages})
    : super(sourceName: 'fake', id: 'doc', pagesCount: pages);

  bool closed = false;
  final openedPages = <int>[];

  @override
  Future<pdfx.PdfPage> getPage(int pageNumber, {bool autoCloseAndroid = false}) async {
    openedPages.add(pageNumber);
    return _FakePage(this, pageNumber);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakePage extends pdfx.PdfPage {
  _FakePage(_FakeDocument document, int number)
    : super(
        document: document,
        id: 'page-$number',
        pageNumber: number,
        width: 100,
        height: 200,
        autoCloseAndroid: false,
      );

  @override
  Future<pdfx.PdfPageImage?> render({
    required double width,
    required double height,
    pdfx.PdfPageImageFormat format = pdfx.PdfPageImageFormat.jpeg,
    String? backgroundColor,
    ui.Rect? cropRect,
    int quality = 100,
    bool forPrint = false,
    bool removeTempFile = true,
  }) async => _FakeImage(width.toInt(), height.toInt());

  @override
  Future<pdfx.PdfPageTexture> createTexture() => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

class _FakeImage extends pdfx.PdfPageImage {
  _FakeImage(int width, int height)
    : super(
        id: 'image',
        pageNumber: 1,
        width: width,
        height: height,
        bytes: _png,
        format: pdfx.PdfPageImageFormat.png,
        quality: 100,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDocument document;
  late PdfxPlatform previous;

  setUp(() {
    document = _FakeDocument(pages: 3);
    previous = PdfxPlatform.instance;
    PdfxPlatform.instance = _FakePlatform(() async => document);
  });

  tearDown(() {
    PdfxPlatform.instance = previous;
  });

  test('opens with the page count and first-page sizes', () async {
    final doc = await WindowsPdfTools().open(Uint8List(8));
    expect(doc.pageCount, 3);
    expect(doc.pageSize(0), const ui.Size(100, 200));
    // Later pages fall back to the last size read.
    expect(doc.pageSize(99), const ui.Size(100, 200));
    expect(document.openedPages, [1, 2, 3]);
    await doc.close();
    expect(document.closed, isTrue);
  });

  test('renders a page at the requested width', () async {
    final doc = await WindowsPdfTools().open(Uint8List(8));
    final image = await doc.render(0, width: 10);
    expect(image.width, 10);
    expect(image.height, 20);
    image.dispose();
    await doc.close();
  });

  test('a height limit keeps only the top of the page', () async {
    final doc = await WindowsPdfTools().open(Uint8List(8));
    final image = await doc.render(0, width: 10, height: 5);
    expect(image.width, 10);
    expect(image.height, 5);
    image.dispose();
    await doc.close();
  });

  test('maps password failures', () async {
    PdfxPlatform.instance = _FakePlatform(
      () async => throw PlatformException(code: 'PASSWORD', message: 'locked'),
    );
    expect(
      () => WindowsPdfTools().open(Uint8List(8)),
      throwsA(
        isA<PdfException>().having(
          (e) => e.failure,
          'failure',
          PdfFailure.passwordProtected,
        ),
      ),
    );
  });

  test('maps other failures to unreadable', () async {
    PdfxPlatform.instance = _FakePlatform(() async => throw StateError('broken'));
    expect(
      () => WindowsPdfTools().open(Uint8List(8)),
      throwsA(
        isA<PdfException>().having(
          (e) => e.failure,
          'failure',
          PdfFailure.unreadable,
        ),
      ),
    );
  });

  test('refuses renders after close and out-of-range pages', () async {
    final tools = WindowsPdfTools();
    final doc = await tools.open(Uint8List(8));
    await doc.close();
    expect(() => doc.render(0, width: 10), throwsA(isA<PdfException>()));

    final other = await tools.open(Uint8List(8));
    expect(() => other.render(3, width: 10), throwsA(isA<PdfException>()));
    expect(() => other.render(-1, width: 10), throwsA(isA<PdfException>()));
    expect(() => other.render(0, width: 0), throwsA(isA<PdfException>()));
    await other.close();
  });
}