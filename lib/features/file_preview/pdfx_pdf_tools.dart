// Apple (iOS/macOS) PDF previews: PDFium through pdfx. Android renders
// untrusted PDFs in an isolated process (PdfRenderService.kt); on Apple
// platforms PDFium — the same hardened parser Chrome uses — runs in-process,
// bounded by the same timeouts and an 8 MP pixel cap. See
// docs/security-and-privacy.md.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import 'pdf_tools.dart';

/// Same pixel budget as the Android renderer (about 8 MP).
const _maxRenderPixels = 8 * 1024 * 1024;

class PdfxPdfTools implements PdfTools {
  PdfxPdfTools({
    this.openTimeout = const Duration(seconds: 30),
    this.renderTimeout = const Duration(seconds: 20),
  });

  final Duration openTimeout;
  final Duration renderTimeout;

  @override
  Future<PdfDocument> open(Uint8List bytes) async {
    final pdfx.PdfDocument document;
    try {
      document = await pdfx.PdfDocument.openData(bytes).timeout(openTimeout);
    } on TimeoutException {
      throw const PdfException(PdfFailure.unreadable);
    } catch (error) {
      throw PdfException(
        _isPasswordError(error)
            ? PdfFailure.passwordProtected
            : PdfFailure.unreadable,
      );
    }
    try {
      // Sizes of the first pages only; later ones are assumed to match the
      // last one read, as on Android.
      final sizes = <ui.Size>[];
      final probeCount = document.pagesCount.clamp(0, 5);
      for (var number = 1; number <= probeCount; number++) {
        final page = await document.getPage(number);
        try {
          sizes.add(ui.Size(page.width, page.height));
        } finally {
          await page.close();
        }
      }
      return _PdfxPdfDocument(document, sizes, renderTimeout);
    } catch (_) {
      await document.close().catchError((Object _) {});
      throw const PdfException(PdfFailure.unreadable);
    }
  }

  static bool _isPasswordError(Object error) {
    if (error is PlatformException) {
      final text = '${error.code} ${error.message}'.toLowerCase();
      return text.contains('password');
    }
    return error.toString().toLowerCase().contains('password');
  }
}

class _PdfxPdfDocument implements PdfDocument {
  _PdfxPdfDocument(this._document, this._sizes, this._timeout);

  final pdfx.PdfDocument _document;
  final List<ui.Size> _sizes;
  final Duration _timeout;
  bool _closed = false;

  /// PDFium renders are serialised, like the Android service's single
  /// HandlerThread.
  Future<void> _renderQueue = Future<void>.value();

  @override
  int get pageCount => _document.pagesCount;

  @override
  ui.Size pageSize(int index) {
    if (_sizes.isEmpty) return const ui.Size(595, 842);
    return _sizes[index < 0
        ? 0
        : index >= _sizes.length
        ? _sizes.length - 1
        : index];
  }

  @override
  Future<ui.Image> render(int index, {required int width, int? height}) {
    if (_closed || index < 0 || index >= pageCount || width <= 0) {
      throw const PdfException(PdfFailure.unreadable);
    }
    final result = _renderQueue.then((_) => _render(index, width, height));
    _renderQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ui.Image> _render(int index, int width, int? height) async {
    if (_closed) throw const PdfException(PdfFailure.unreadable);
    final size = pageSize(index);
    var renderWidth = width;
    var fullHeight = (width * size.height / size.width).round();
    if (fullHeight <= 0) fullHeight = 1;
    if (renderWidth * fullHeight > _maxRenderPixels) {
      renderWidth = (_maxRenderPixels / fullHeight).floor();
      fullHeight = (renderWidth * size.height / size.width).round().clamp(
        1,
        _maxRenderPixels,
      );
    }
    if (renderWidth <= 0) throw const PdfException(PdfFailure.unreadable);
    pdfx.PdfPage? page;
    try {
      page = await _document.getPage(index + 1).timeout(_timeout);
      final image = await page
          .render(
            width: renderWidth.toDouble(),
            height: fullHeight.toDouble(),
            format: pdfx.PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          )
          .timeout(_timeout);
      final bytes = image?.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const PdfException(PdfFailure.unreadable);
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      var drawn = frame.image;
      // A height limit shows only the top of the page (timeline previews).
      if (height != null && height > 0 && height < drawn.height) {
        drawn = await _cropTop(drawn, height);
      }
      return drawn;
    } on PdfException {
      rethrow;
    } on TimeoutException {
      throw const PdfException(PdfFailure.unreadable);
    } catch (error) {
      throw PdfException(
        PdfxPdfTools._isPasswordError(error)
            ? PdfFailure.passwordProtected
            : PdfFailure.unreadable,
      );
    } finally {
      try {
        await page?.close();
      } catch (_) {
        // The document close below releases everything anyway.
      }
    }
  }

  /// Keeps the top [height] pixels of [source]; the source is disposed.
  static Future<ui.Image> _cropTop(ui.Image source, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final slice = ui.Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      height.toDouble(),
    );
    canvas.drawImageRect(source, slice, slice, ui.Paint());
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(source.width, height);
    picture.dispose();
    source.dispose();
    return cropped;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Join any accepted render before releasing the document it reads.
    await _renderQueue;
    await _document.close().catchError((Object _) {});
  }
}
