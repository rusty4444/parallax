import 'dart:async';
import 'dart:ui' as ui;

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../media/media_features.dart';
import 'document_loader.dart';
import 'pdf_tools.dart';

/// The top of the first page of PDFs, for the timeline, kept for the
/// signed-in session only.
///
/// One file is worked on at a time: each needs the renderer, which holds
/// few documents at once, and the viewer should never wait behind a queue
/// of thumbnails.
class PdfThumbnails {
  PdfThumbnails._(this.backend);

  static final _instances = Expando<PdfThumbnails>('pdf thumbnails');

  static PdfThumbnails of(ChatBackend backend) =>
      _instances[backend] ??= PdfThumbnails._(backend);

  static const _max = 24;

  final ChatBackend backend;
  Object? _session;
  int _generation = 0;

  /// A null value: looked at, and there is nothing to show.
  final _images = <String, ui.Image?>{};
  final _loading = <String, Future<void>>{};
  final _failedAt = <String, DateTime>{};
  Future<void> _queue = Future.value();

  /// Drops everything when the account changed or signed out.
  void _checkSession() {
    final session = backend.connection == SessionStatus.signedOut
        ? null
        : (backend.userId, BackendSessionOwner.keyFor(backend));
    if (session == _session) return;
    _session = session;
    _generation++;
    for (final image in _images.values) {
      image?.dispose();
    }
    _images.clear();
    _loading.clear();
    _failedAt.clear();
  }

  static String _key(String roomId, String eventId) => '$roomId/$eventId';

  /// Whether this file was already looked at; [imageFor] then has the
  /// result.
  bool has(String roomId, String eventId) {
    _checkSession();
    return _images.containsKey(_key(roomId, eventId));
  }

  /// The caller's own handle on the thumbnail, to dispose when done, or
  /// null when there is nothing to show.
  ui.Image? imageFor(String roomId, String eventId) {
    _checkSession();
    return _images[_key(roomId, eventId)]?.clone();
  }

  /// Fetches the file and draws the top [height] pixels of its first page,
  /// [width] pixels wide. Never throws; ask [imageFor] afterwards.
  Future<void> load(
    String roomId,
    String eventId, {
    required int width,
    required int height,
  }) {
    _checkSession();
    final key = _key(roomId, eventId);
    if (_images.containsKey(key)) return Future.value();
    final failed = _failedAt[key];
    if (failed != null &&
        DateTime.now().difference(failed) < DocumentPreviews.retryAfter) {
      return Future.value();
    }
    final waiting = _loading[key];
    if (waiting != null) return waiting;
    final generation = _generation;
    final work = _queue
        .then((_) => _load(roomId, eventId, width, height, generation))
        // Nothing here should throw; if it does, the queue carries on.
        .catchError((Object _) {});
    _queue = work;
    return _loading[key] = work.whenComplete(() {
      if (generation == _generation) _loading.remove(key);
    });
  }

  Future<void> _load(
    String roomId,
    String eventId,
    int width,
    int height,
    int generation,
  ) async {
    final key = _key(roomId, eventId);
    if (generation != _generation) return;
    final DownloadedAttachment file;
    try {
      final features = mediaFeaturesOf(backend);
      file = features != null
          ? await features.loadOriginal(
              roomId,
              eventId,
              maxBytes: DocumentPreviews.inlineMaxBytes,
            )
          : await backend.loadAttachment(roomId, eventId);
    } catch (_) {
      if (generation == _generation) _failedAt[key] = DateTime.now();
      return;
    }
    if (generation != _generation) return;
    ui.Image? image;
    if (file.bytes.length <= DocumentPreviews.inlineMaxBytes) {
      PdfDocument? document;
      try {
        document = await PdfTools.instance.open(file.bytes);
        image = await document.render(0, width: width, height: height);
      } catch (_) {
        // Locked, damaged or not a PDF: the file card is all there is.
        image = null;
      } finally {
        if (document != null) unawaited(document.close());
      }
    }
    if (generation != _generation) {
      image?.dispose();
      return;
    }
    _images[key] = image;
    while (_images.length > _max) {
      _images.remove(_images.keys.first)?.dispose();
    }
  }
}
