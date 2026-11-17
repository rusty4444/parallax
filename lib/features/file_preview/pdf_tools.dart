import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Why a PDF can't be shown.
enum PdfFailure {
  /// It asks for a password, which the previewer can't supply.
  passwordProtected,

  /// Damaged, not a PDF, too slow to open, or no renderer on this platform.
  unreadable,
}

class PdfException implements Exception {
  const PdfException(this.failure);
  final PdfFailure failure;

  @override
  String toString() => 'PdfException(${failure.name})';
}

/// PDF pages as images. On Android the system's PdfRenderer draws them in an
/// isolated process (PdfRenderService.kt): the file comes from someone else,
/// and that process has no access to the app's data. Replace [instance] in
/// tests.
abstract class PdfTools {
  static PdfTools instance = PlatformPdfTools();

  /// Opens [bytes]. Throws [PdfException]. The caller closes the document.
  Future<PdfDocument> open(Uint8List bytes);
}

/// An open PDF. Rendering is serialised by the renderer; [close] it when
/// done (it holds a process and the decrypted file in memory).
abstract class PdfDocument {
  int get pageCount;

  /// Size of page [index] in points (1/72 inch).
  ui.Size pageSize(int index);

  /// Page [index] drawn [width] pixels wide on white. With [height], only
  /// that much of the top of the page. The caller disposes the image.
  /// Throws [PdfException].
  Future<ui.Image> render(int index, {required int width, int? height});

  Future<void> close();
}

/// [PdfTools] over the `parallax/pdf` method channel.
class PlatformPdfTools implements PdfTools {
  PlatformPdfTools({
    this.openTimeout = const Duration(seconds: 30),
    this.renderTimeout = const Duration(seconds: 20),
    @visibleForTesting this.viaFile = false,
  });

  static const _channel = MethodChannel('parallax/pdf');

  final Duration openTimeout;
  final Duration renderTimeout;

  /// Hand the file over as an unlinked temporary file even where memory
  /// would be used (the path Android 7–10 take), to test it on any device.
  final bool viaFile;

  /// Calls the renderer. A request that never answers (a file that hangs
  /// the PDF library) abandons that renderer process.
  static Future<T?> _call<T>(
    String method,
    Object arguments,
    Duration timeout,
  ) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments).timeout(timeout);
    } on TimeoutException {
      try {
        await _channel.invokeMethod<void>('reset');
      } catch (_) {
        // Nothing more can be done from here.
      }
      throw const PdfException(PdfFailure.unreadable);
    } on PlatformException catch (error) {
      throw PdfException(
        error.code == 'PASSWORD'
            ? PdfFailure.passwordProtected
            : PdfFailure.unreadable,
      );
    } on MissingPluginException {
      throw const PdfException(PdfFailure.unreadable);
    }
  }

  @override
  Future<PdfDocument> open(Uint8List bytes) async {
    final opened = await _call<Map<Object?, Object?>>('open', {
      'bytes': bytes,
      'file': viaFile,
    }, openTimeout);
    final id = opened?['id'];
    final pages = opened?['pages'];
    final sizes = opened?['sizes'];
    if (id is! int || pages is! int || pages <= 0 || sizes is! List) {
      if (id is int) unawaited(_closeQuietly(id));
      throw const PdfException(PdfFailure.unreadable);
    }
    return _PlatformPdfDocument(id, pages, [
      for (var index = 0; index + 1 < sizes.length; index += 2)
        ui.Size(_positive(sizes[index]), _positive(sizes[index + 1])),
    ], renderTimeout);
  }

  static double _positive(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toDouble() : 1;

  static Future<void> _closeQuietly(int id) async {
    try {
      await _channel.invokeMethod<void>('close', {'id': id});
    } catch (_) {
      // The renderer is gone, and its documents with it.
    }
  }
}

class _PlatformPdfDocument implements PdfDocument {
  _PlatformPdfDocument(this._id, this.pageCount, this._sizes, this._timeout);

  final int _id;
  final List<ui.Size> _sizes;
  final Duration _timeout;
  bool _closed = false;

  @override
  final int pageCount;

  @override
  ui.Size pageSize(int index) {
    // Sizes are read for the first pages only; later ones are assumed to
    // match the last one read (A4 if none was).
    if (_sizes.isEmpty) return const ui.Size(595, 842);
    return _sizes[index < 0
        ? 0
        : index >= _sizes.length
        ? _sizes.length - 1
        : index];
  }

  @override
  Future<ui.Image> render(int index, {required int width, int? height}) async {
    if (_closed || index < 0 || index >= pageCount || width <= 0) {
      throw const PdfException(PdfFailure.unreadable);
    }
    final page = await PlatformPdfTools._call<Map<Object?, Object?>>('render', {
      'id': _id,
      'page': index,
      'width': width,
      'height': height ?? 0,
    }, _timeout);
    final pixels = page?['pixels'];
    final drawnWidth = page?['width'];
    final drawnHeight = page?['height'];
    if (pixels is! Uint8List ||
        drawnWidth is! int ||
        drawnHeight is! int ||
        drawnWidth <= 0 ||
        drawnHeight <= 0 ||
        pixels.length != drawnWidth * drawnHeight * 4) {
      throw const PdfException(PdfFailure.unreadable);
    }
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      drawnWidth,
      drawnHeight,
      ui.PixelFormat.rgba8888,
      decoded.complete,
    );
    return decoded.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await PlatformPdfTools._closeQuietly(_id);
  }
}
