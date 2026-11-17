import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/file_preview/document_loader.dart';
import 'package:parallax/features/file_preview/inline_document_preview.dart';
import 'package:parallax/features/file_preview/pdf_thumbnails.dart';
import 'package:parallax/features/file_preview/pdf_tools.dart';
import 'package:parallax/features/file_preview/pdf_view.dart';
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/features/media/media_hooks.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';

import 'media_test_support.dart';
import 'pdf_fixtures.dart';

/// A renderer that hands out copies of one image and records what it was
/// asked. The real one is exercised on a device by
/// integration_test/pdf_tools_test.dart.
class FakePdfTools implements PdfTools {
  FakePdfTools(this._page);
  final ui.Image _page;

  PdfFailure? failure;
  int pages = 3;
  List<ui.Size> sizes = const [ui.Size(595, 842)];

  /// Pages whose next render fails.
  final failing = <int>{};
  final log = <String>[];

  /// Documents opened and not yet closed.
  int live = 0;

  @override
  Future<PdfDocument> open(Uint8List bytes) async {
    log.add('open ${bytes.length}');
    final failure = this.failure;
    if (failure != null) throw PdfException(failure);
    live++;
    return _FakeDocument(this);
  }
}

class _FakeDocument implements PdfDocument {
  _FakeDocument(this.tools);
  final FakePdfTools tools;
  bool closed = false;

  @override
  int get pageCount => tools.pages;

  @override
  ui.Size pageSize(int index) =>
      tools.sizes[index < tools.sizes.length ? index : tools.sizes.length - 1];

  @override
  Future<ui.Image> render(int index, {required int width, int? height}) async {
    tools.log.add('render $index ${width}x${height ?? 'page'}');
    if (closed || tools.failing.remove(index)) {
      throw const PdfException(PdfFailure.unreadable);
    }
    return tools._page.clone();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    tools.live--;
    tools.log.add('close');
  }
}

DownloadedAttachment pdfFile([Uint8List? bytes]) => DownloadedAttachment(
  name: 'Lease.pdf',
  mimeType: 'application/pdf',
  bytes: bytes ?? samplePdf,
);

ChatEntry pdfEntry(String id, {int? size, String name = 'Lease.pdf'}) =>
    mediaEntry(
      id,
      EntryKind.file,
      body: name,
      content: {
        'info': {'mimetype': 'application/pdf', 'size': ?size},
      },
    );

void main() {
  Future<FakePdfTools> install(WidgetTester tester) async {
    final image = (await tester.runAsync(() => makeImage(60, 85)))!;
    final tools = FakePdfTools(image);
    PdfTools.instance = tools;
    addTearDown(() {
      PdfTools.instance = PlatformPdfTools();
      image.dispose();
    });
    return tools;
  }

  Widget bubbleBody(FakeMediaBackend backend, ChatEntry entry) => host(
    Builder(
      builder: (context) =>
          mediaEntryBody(context, hookFor(backend, entry)) ??
          const Text('none'),
    ),
  );

  const inline = ValueKey('document.inline');
  const inlinePage = ValueKey('document.inline.pdf');

  group('in the timeline', () {
    testWidgets('a PDF shows the top of its first page under the file card', (
      tester,
    ) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await tester.pumpWidget(
        bubbleBody(backend, pdfEntry(r'$pdf', size: samplePdf.length)),
      );
      // The box is there, at its final size, before the page is drawn.
      expect(
        tester.getSize(find.byKey(inline)),
        const Size(InlineDocumentPreview.width, InlineDocumentPreview.height),
      );
      expect(find.byKey(inlinePage), findsNothing);
      await settle(tester);
      expect(find.byKey(inlinePage), findsOneWidget);
      expect(
        tester.getSize(find.byKey(inline)),
        const Size(InlineDocumentPreview.width, InlineDocumentPreview.height),
      );
      // One strip of page one, at the screen's pixel density (3 in tests),
      // and the document is closed again straight away.
      expect(tools.log, [
        'open ${samplePdf.length}',
        'render 0 792x294',
        'close',
      ]);
      expect(tools.live, 0);
      expect(backend.loads, [r'$pdf']);
      expect(find.text('Lease.pdf'), findsOneWidget);
      expect(find.bySemanticsLabel('Preview of Lease.pdf'), findsOneWidget);
    });

    testWidgets('a bubble built again reuses the thumbnail', (tester) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      final entry = pdfEntry(r'$pdf');
      await tester.pumpWidget(bubbleBody(backend, entry));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(bubbleBody(backend, entry));
      // Already there on the first frame.
      expect(find.byKey(inlinePage), findsOneWidget);
      await settle(tester);
      expect(tools.log.where((line) => line.startsWith('open')), hasLength(1));
      expect(backend.loads, [r'$pdf']);
    });

    testWidgets('a locked or damaged PDF leaves just the card', (tester) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile(lockedPdf);
      for (final failure in PdfFailure.values) {
        tools
          ..failure = failure
          ..log.clear();
        final entry = pdfEntry('\$${failure.name}');
        await tester.pumpWidget(bubbleBody(backend, entry));
        await settle(tester);
        expect(find.byKey(inline), findsNothing, reason: failure.name);
        expect(find.text('Lease.pdf'), findsOneWidget);
        // Not tried again each time the bubble is rebuilt.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(bubbleBody(backend, entry));
        await settle(tester);
        expect(tools.log, ['open ${lockedPdf.length}'], reason: failure.name);
      }
      expect(tools.live, 0);
    });

    testWidgets('a page that cannot be drawn leaves just the card', (
      tester,
    ) async {
      final tools = await install(tester);
      tools.failing.add(0);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await tester.pumpWidget(bubbleBody(backend, pdfEntry(r'$pdf')));
      await settle(tester);
      expect(find.byKey(inline), findsNothing);
      // The document was still closed.
      expect(tools.log.last, 'close');
      expect(tools.live, 0);
    });

    testWidgets('a download that fails is not retried on every rebuild', (
      tester,
    ) async {
      final tools = await install(tester);
      var failures = 0;
      final backend = FakeMediaBackend()
        ..original = (_) {
          failures++;
          throw StateError('Attachment unavailable');
        };
      final entry = pdfEntry(r'$gone');
      await tester.pumpWidget(bubbleBody(backend, entry));
      await settle(tester);
      expect(find.byKey(inline), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(bubbleBody(backend, entry));
      await settle(tester);
      expect(failures, 1);
      expect(tools.log, isEmpty);
    });

    testWidgets('a large PDF is not fetched for a thumbnail', (tester) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await tester.pumpWidget(
        bubbleBody(
          backend,
          pdfEntry(r'$big', size: DocumentPreviews.inlineMaxBytes + 1),
        ),
      );
      await settle(tester);
      expect(find.byKey(inline), findsNothing);
      expect(backend.loads, isEmpty);
      expect(tools.log, isEmpty);
    });

    testWidgets('files are drawn one at a time', (tester) async {
      final tools = await install(tester);
      final gate = Completer<void>();
      var waiting = 0;
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      // Hold every download until released.
      final thumbnails = PdfThumbnails.of(backend);
      backend.original = (_) {
        waiting++;
        return pdfFile();
      };
      final first = thumbnails.load(roomId, r'$a', width: 10, height: 5);
      final second = thumbnails.load(roomId, r'$b', width: 10, height: 5);
      // Asking twice for the same file shares the work.
      expect(
        identical(thumbnails.load(roomId, r'$a', width: 10, height: 5), first),
        isTrue,
      );
      gate.complete();
      await tester.runAsync(() => Future.wait([first, second]));
      expect(waiting, 2);
      expect(tools.log, [
        'open ${samplePdf.length}',
        'render 0 10x5',
        'close',
        'open ${samplePdf.length}',
        'render 0 10x5',
        'close',
      ]);
      final image = thumbnails.imageFor(roomId, r'$a');
      expect(image, isNotNull);
      image!.dispose();
    });

    testWidgets('thumbnails are dropped when the account signs out', (
      tester,
    ) async {
      await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await tester.pumpWidget(bubbleBody(backend, pdfEntry(r'$pdf')));
      await settle(tester);
      final thumbnails = PdfThumbnails.of(backend);
      expect(thumbnails.has(roomId, r'$pdf'), isTrue);
      backend.signOut();
      await tester.pumpWidget(bubbleBody(backend, pdfEntry(r'$pdf')));
      await settle(tester);
      expect(find.byKey(inlinePage), findsNothing);
      expect(thumbnails.has(roomId, r'$pdf'), isFalse);
      expect(thumbnails.imageFor(roomId, r'$pdf'), isNull);
    });
  });

  group('in the viewer', () {
    Future<void> open(
      WidgetTester tester,
      FakeMediaBackend backend,
      ChatEntry entry,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewerPager(
            backend: backend,
            roomId: roomId,
            items: mediaViewerItems(
              backend,
              roomId,
              entry.id,
              entries: [entry],
            ),
          ),
        ),
      );
      await settle(tester);
    }

    const list = ValueKey('document.pdf');

    testWidgets('a PDF opens as its pages, with a page counter', (
      tester,
    ) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf', size: samplePdf.length));
      expect(find.byKey(list), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Page 1 of 3'), findsOneWidget);
      expect(find.byType(RawImage), findsOneWidget);
      // An 800 dp wide test screen at 3 px per dp asks for more than the
      // limit, so the page is drawn at the widest allowed.
      expect(tools.log, ['open ${samplePdf.length}', 'render 0 1600xpage']);
      // A4 keeps its shape: 784 dp wide between the margins.
      final page = tester.getSize(
        find.byKey(const ValueKey('document.pdf.page.0')),
      );
      expect(page.width, 784);
      expect(page.height, closeTo(784 * 842 / 595, 0.01));
      expect(find.textContaining('can’t be previewed'), findsNothing);

      // Scrolling draws the next page and moves the counter.
      // (Each touch also starts the double-tap detector's 40 ms clock.)
      await tester.drag(find.byKey(list), const Offset(0, -1000));
      await tester.pump(const Duration(milliseconds: 50));
      await settle(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      expect(tools.log, contains('render 1 1600xpage'));
      await tester.drag(find.byKey(list), const Offset(0, -3000));
      await tester.pump(const Duration(milliseconds: 50));
      await settle(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(tools.log, contains('render 2 1600xpage'));

      // Closing the viewer closes the document.
      expect(tools.live, 1);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      expect(tools.live, 0);
      expect(tools.log.last, 'close');
    });

    testWidgets('pages of different shapes keep their own shape', (
      tester,
    ) async {
      final tools = await install(tester);
      tools.sizes = const [
        ui.Size(595, 842),
        ui.Size(842, 595),
        ui.Size(200, 200),
      ];
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      final controller = tester.widget<ListView>(find.byKey(list)).controller!;
      controller.jumpTo(1200);
      await settle(tester);
      final landscape = tester.getSize(
        find.byKey(const ValueKey('document.pdf.page.1')),
      );
      expect(landscape.width, 784);
      expect(landscape.height, closeTo(784 * 595 / 842, 0.01));
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle(tester);
      expect(
        tester.getSize(find.byKey(const ValueKey('document.pdf.page.2'))),
        const Size(784, 784),
      );
      expect(find.bySemanticsLabel('Page 3 of 3'), findsOneWidget);
      expect(find.text('3 / 3'), findsOneWidget);
    });

    testWidgets('at the end, the counter shows the last page however short', (
      tester,
    ) async {
      final tools = await install(tester);
      tools
        ..pages = 2
        // A full page, then a short strip (a signature page, a banner).
        ..sizes = const [ui.Size(595, 842), ui.Size(842, 200)];
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      expect(find.text('1 / 2'), findsOneWidget);
      final controller = tester.widget<ListView>(find.byKey(list)).controller!;
      // (Until the last page has been laid out the list only estimates its
      // length, so go to the end first.)
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle(tester);
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      // Just short of the end: the strip is on screen but page one fills it.
      controller.jumpTo(controller.position.maxScrollExtent - 40);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      controller.jumpTo(controller.position.maxScrollExtent);
      await settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      controller.jumpTo(0);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
    });

    testWidgets('a one-page PDF has no counter', (tester) async {
      final tools = await install(tester);
      tools.pages = 1;
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.text('1 / 1'), findsNothing);
    });

    testWidgets('double-tap zooms in and the page is drawn again, sharper', (
      tester,
    ) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      final viewer = find.byType(InteractiveViewer);
      double scale() => tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(scale(), 1);

      Future<void> doubleTap() async {
        await tester.tapAt(const Offset(400, 300));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(const Offset(400, 300));
        await tester.pumpAndSettle();
      }

      await doubleTap();
      expect(scale(), closeTo(2.5, 0.001));
      expect(tools.log.last, 'render 0 2200xpage');
      expect(find.byType(RawImage), findsOneWidget);

      // Back out: the sharper page is kept, not drawn a third time.
      await doubleTap();
      expect(scale(), closeTo(1, 0.001));
      expect(tools.log.where((line) => line.startsWith('render 0')), [
        'render 0 1600xpage',
        'render 0 2200xpage',
      ]);
    });

    testWidgets('a locked PDF says so', (tester) async {
      final tools = await install(tester);
      tools.failure = PdfFailure.passwordProtected;
      final backend = FakeMediaBackend()..original = (_) => pdfFile(lockedPdf);
      await open(tester, backend, pdfEntry(r'$locked'));
      expect(find.text('This PDF is locked with a password.'), findsOneWidget);
      expect(
        find.text('Save or share it to open it in another app.'),
        findsOneWidget,
      );
      expect(find.byKey(list), findsNothing);
      // Save and Share still work from the bar.
      expect(find.byTooltip('Save'), findsOneWidget);
      expect(find.byTooltip('Share'), findsOneWidget);
    });

    testWidgets('a damaged PDF keeps the file card', (tester) async {
      final tools = await install(tester);
      tools.failure = PdfFailure.unreadable;
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$bad', size: 1237));
      expect(find.textContaining('can’t be previewed'), findsOneWidget);
      expect(find.text('PDF · 1.2 KB'), findsOneWidget);
    });

    testWidgets('where there is no PDF renderer, the file card stays', (
      tester,
    ) async {
      // Nothing implements the channel, as on a platform without a renderer.
      const channel = MethodChannel('parallax/pdf');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) => throw MissingPluginException(),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      PdfTools.instance = PlatformPdfTools();
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      expect(find.textContaining('can’t be previewed'), findsOneWidget);
    });

    testWidgets('a failed download offers Retry', (tester) async {
      final tools = await install(tester);
      var attempts = 0;
      final backend = FakeMediaBackend()
        ..original = (_) {
          // The loader asks the open timeline, then the room's history.
          if (attempts++ < 2) throw StateError('offline');
          return pdfFile();
        };
      await open(tester, backend, pdfEntry(r'$r'));
      expect(find.text('Couldn’t load this file.'), findsOneWidget);
      expect(tools.log, isEmpty);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.byKey(list), findsOneWidget);
      expect(find.byType(RawImage), findsOneWidget);
    });

    testWidgets('a page that fails to draw can be tapped to try again', (
      tester,
    ) async {
      final tools = await install(tester);
      tools.failing.add(0);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(tester, backend, pdfEntry(r'$pdf'));
      expect(find.text('Couldn’t draw Page 1. Tap to retry.'), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      // Anywhere on the page will do (its middle is below this screen). A
      // single tap is told apart from a double tap after a short wait.
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byType(RawImage), findsOneWidget);
      expect(find.textContaining('Tap to retry'), findsNothing);
    });

    testWidgets('a PDF over the download limit is not fetched', (tester) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend()..original = (_) => pdfFile();
      await open(
        tester,
        backend,
        pdfEntry(r'$huge', size: maxOriginalBytes + 1),
      );
      expect(find.textContaining('can’t be previewed'), findsOneWidget);
      expect(backend.loads, isEmpty);
      expect(tools.log, isEmpty);
    });

    testWidgets('signing out while it loads shows nothing and closes it', (
      tester,
    ) async {
      final tools = await install(tester);
      final backend = FakeMediaBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfDocumentPage(
              backend: backend,
              loader: () async {
                await null;
                backend.signOut();
                return pdfFile();
              },
              fallback: const Text('card'),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(list), findsNothing);
      expect(find.byType(RawImage), findsNothing);
      // The other account's file was never handed to the renderer.
      expect(tools.log, isEmpty);
      expect(tools.live, 0);
    });
  });

  group('the platform channel', () {
    const channel = MethodChannel('parallax/pdf');
    final calls = <MethodCall>[];
    Future<Object?> Function(MethodCall call)? answer;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
            calls.add(call);
            return answer!(call);
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('opens, draws and closes a document', (tester) async {
      answer = (call) async => switch (call.method) {
        'open' => {
          'id': 7,
          'pages': 2,
          'sizes': [595.0, 842.0, 842.0, 595.0],
        },
        'render' => {
          'width': 2,
          'height': 1,
          'pixels': Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
        },
        _ => null,
      };
      final image = await tester.runAsync(() async {
        final document = await PlatformPdfTools().open(samplePdf);
        expect(document.pageCount, 2);
        expect(document.pageSize(0), const ui.Size(595, 842));
        expect(document.pageSize(1), const ui.Size(842, 595));
        // Past what was measured: assumed to match the last one read.
        expect(document.pageSize(9), const ui.Size(842, 595));
        final image = await document.render(1, width: 2, height: 1);
        await document.close();
        await document.close();
        // Closed means closed: nothing more is sent.
        await expectLater(
          document.render(0, width: 2),
          throwsA(isA<PdfException>()),
        );
        return image;
      });
      expect((image!.width, image.height), (2, 1));
      image.dispose();
      expect(calls.map((call) => call.method), ['open', 'render', 'close']);
      expect(calls[0].arguments, {'bytes': samplePdf, 'file': false});
      expect(calls[1].arguments, {'id': 7, 'page': 1, 'width': 2, 'height': 1});
      expect(calls[2].arguments, {'id': 7});
    });

    testWidgets('a password error is told apart from an unreadable file', (
      tester,
    ) async {
      for (final (code, failure) in [
        ('PASSWORD', PdfFailure.passwordProtected),
        ('UNREADABLE', PdfFailure.unreadable),
        ('MEMORY', PdfFailure.unreadable),
      ]) {
        answer = (_) async => throw PlatformException(code: code);
        await expectLater(
          PlatformPdfTools().open(samplePdf),
          throwsA(
            isA<PdfException>().having((e) => e.failure, 'failure', failure),
          ),
          reason: code,
        );
      }
    });

    testWidgets('answers that make no sense are refused', (tester) async {
      // No pages: the document is closed again and reported unreadable.
      answer = (call) async =>
          call.method == 'open' ? {'id': 3, 'pages': 0, 'sizes': []} : null;
      await expectLater(
        PlatformPdfTools().open(samplePdf),
        throwsA(isA<PdfException>()),
      );
      expect(calls.map((call) => call.method), ['open', 'close']);

      // Pixels that don't match the stated size never reach the decoder.
      calls.clear();
      answer = (call) async => switch (call.method) {
        'open' => {
          'id': 4,
          'pages': 1,
          'sizes': [595.0, 842.0],
        },
        'render' => {'width': 100, 'height': 100, 'pixels': Uint8List(16)},
        _ => null,
      };
      final document = await PlatformPdfTools().open(samplePdf);
      await expectLater(
        document.render(0, width: 100),
        throwsA(isA<PdfException>()),
      );
      // Out of range is refused before asking.
      await expectLater(
        document.render(1, width: 100),
        throwsA(isA<PdfException>()),
      );
      expect(calls.map((call) => call.method), ['open', 'render']);
    });

    testWidgets('a renderer that never answers is abandoned', (tester) async {
      answer = (call) => call.method == 'open'
          ? Completer<Object?>().future
          : Future<Object?>.value();
      final tools = PlatformPdfTools(openTimeout: const Duration(seconds: 5));
      Object? error;
      unawaited(
        tools
            .open(samplePdf)
            .then<void>((_) {}, onError: (Object e) => error = e),
      );
      await tester.pump(const Duration(seconds: 4));
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(
        error,
        isA<PdfException>().having(
          (e) => e.failure,
          'failure',
          PdfFailure.unreadable,
        ),
      );
      // The stuck process is dropped so the next file gets a new one.
      expect(calls.map((call) => call.method), ['open', 'reset']);
    });
  });
}
