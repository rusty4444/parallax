import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import '../media/media_features.dart';
import 'document_model.dart';
import 'document_parser.dart';

/// Parses one file away from the UI isolate.
typedef DocumentParseRunner =
    Future<DocumentPreview?> Function(DocumentRequest request);

/// Overridable in tests (fake async cannot wait for a real isolate);
/// production uses [parseDocumentInBackground].
@visibleForTesting
DocumentParseRunner debugDocumentParser = parseDocumentInBackground;

class _Parsed {
  const _Parsed(this.preview);
  final DocumentPreview? preview;
}

void _parseEntry((SendPort, DocumentRequest) message) {
  final (port, request) = message;
  Isolate.exit(port, _Parsed(parseDocument(request)));
}

/// Runs [parseDocument] on its own isolate and stops that isolate after
/// [timeout]: the file comes from someone else, and a parser that never
/// finishes must not keep a core busy. Returns null when the file can't be
/// previewed, the parser failed or it ran out of time.
Future<DocumentPreview?> parseDocumentInBackground(
  DocumentRequest request, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final results = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _parseEntry,
      (results.sendPort, request),
      onExit: results.sendPort,
      onError: results.sendPort,
      debugName: 'parallax.document.preview',
    );
    // The result, or the isolate's error or exit message if it died first.
    final message = await results.first.timeout(timeout);
    return message is _Parsed ? message.preview : null;
  } on TimeoutException {
    return null;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    results.close();
  }
}

/// Document previews for one backend, kept for the signed-in session only.
///
/// The timeline asks for [inline] previews: a small download limit and a
/// few lines of the file, remembered so a bubble built again (scrolling,
/// a sync) costs nothing. The viewer asks for the [full] preview.
class DocumentPreviews {
  DocumentPreviews._(this.backend);

  static final _instances = Expando<DocumentPreviews>('document previews');

  static DocumentPreviews of(ChatBackend backend) =>
      _instances[backend] ??= DocumentPreviews._(backend);

  /// Largest file fetched without being asked, to show under a message.
  static const inlineMaxBytes = 4 * 1024 * 1024;

  /// A failed download isn't retried before this (the timeline rebuilds
  /// bubbles often; a file that is gone would be requested again each time).
  static const retryAfter = Duration(minutes: 1);

  static const _maxInline = 200;
  static const _maxFull = 3;

  final ChatBackend backend;
  Object? _session;
  int _generation = 0;
  final _inline = <String, DocumentPreview?>{};
  final _inlineLoading = <String, Future<DocumentPreview?>>{};
  final _failedAt = <String, DateTime>{};
  final _full = <String, DocumentPreview>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;

  /// Drops everything when the account changed or signed out.
  void _checkSession() {
    final session = backend.connection == SessionStatus.signedOut
        ? null
        : (backend.userId, BackendSessionOwner.keyFor(backend));
    if (session == _session) return;
    _session = session;
    _generation++;
    _inline.clear();
    _inlineLoading.clear();
    _failedAt.clear();
    _full.clear();
  }

  static String _key(String roomId, String eventId) => '$roomId/$eventId';

  /// Whether an inline preview was already loaded; its value (null: nothing
  /// to show) is then in [inlineOrNull].
  bool hasInline(String roomId, String eventId) {
    _checkSession();
    return _inline.containsKey(_key(roomId, eventId));
  }

  DocumentPreview? inlineOrNull(String roomId, String eventId) {
    _checkSession();
    return _inline[_key(roomId, eventId)];
  }

  /// The first lines of a file for the timeline, or null when there is
  /// nothing to show (unsupported, empty, too large, download failed).
  Future<DocumentPreview?> inline(
    String roomId,
    String eventId, {
    required String name,
    String? mimeType,
  }) {
    _checkSession();
    final key = _key(roomId, eventId);
    if (_inline.containsKey(key)) return Future.value(_inline[key]);
    final failed = _failedAt[key];
    if (failed != null && DateTime.now().difference(failed) < retryAfter) {
      return Future.value();
    }
    final generation = _generation;
    return _inlineLoading[key] ??=
        _limited(
          () => _loadInline(roomId, eventId, name, mimeType, generation),
        ).whenComplete(() {
          if (generation == _generation) _inlineLoading.remove(key);
        });
  }

  Future<DocumentPreview?> _loadInline(
    String roomId,
    String eventId,
    String name,
    String? mimeType,
    int generation,
  ) async {
    final key = _key(roomId, eventId);
    if (generation != _generation) return null;
    final DownloadedAttachment file;
    try {
      final features = mediaFeaturesOf(backend);
      file = features != null
          ? await features.loadOriginal(
              roomId,
              eventId,
              maxBytes: inlineMaxBytes,
            )
          : await backend.loadAttachment(roomId, eventId);
    } catch (_) {
      if (generation == _generation) _failedAt[key] = DateTime.now();
      return null;
    }
    if (generation != _generation) return null;
    final format =
        documentFormatFor(name, mimeType) ??
        documentFormatFor(file.name, file.mimeType);
    var preview = format == null || file.bytes.length > inlineMaxBytes
        ? null
        : await debugDocumentParser(
            DocumentRequest(
              bytes: file.bytes,
              format: format,
              name: name,
              limits: DocumentLimits.inline,
            ),
          );
    if (generation != _generation) return null;
    if (preview != null && isEmptyPreview(preview)) preview = null;
    _inline[key] = preview;
    while (_inline.length > _maxInline) {
      _inline.remove(_inline.keys.first);
    }
    return preview;
  }

  /// The whole file for the viewer. Null when it can't be previewed; throws
  /// when it can't be downloaded.
  Future<DocumentPreview?> full(
    String roomId,
    String eventId,
    MediaLoader loader, {
    required String name,
    String? mimeType,
  }) async {
    _checkSession();
    final key = _key(roomId, eventId);
    final cached = _full.remove(key);
    if (cached != null) {
      _full[key] = cached;
      return cached;
    }
    final generation = _generation;
    final file = await loader();
    final format =
        documentFormatFor(name, mimeType) ??
        documentFormatFor(file.name, file.mimeType);
    if (format == null) return null;
    final preview = await debugDocumentParser(
      DocumentRequest(bytes: file.bytes, format: format, name: name),
    );
    if (preview != null && generation == _generation) {
      _full[key] = preview;
      while (_full.length > _maxFull) {
        _full.remove(_full.keys.first);
      }
    }
    return preview;
  }

  Future<T> _limited<T>(Future<T> Function() work) async {
    if (_active >= 2) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await work();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}

/// Whether [preview] has nothing to show.
bool isEmptyPreview(DocumentPreview preview) => switch (preview) {
  TextPreview(:final text) => text.trim().isEmpty,
  RichPreview(:final blocks) => blocks.every((block) => block is SlideBlock),
  SheetPreview(:final sheets) => sheets.every((sheet) => sheet.rows.isEmpty),
};
