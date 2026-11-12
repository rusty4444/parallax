import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'link_previews.dart';

/// Remembers link previews for the session and, per account, on disk, so
/// scrolling back over a link doesn't fetch its page again. Only successes
/// are saved; a site that failed is retried after [negativeTtl].
class LinkPreviewCache {
  LinkPreviewCache(
    this.source, {
    this._directory,
    DateTime Function()? now,
    this.maxEntries = 300,
    this.negativeTtl = const Duration(minutes: 10),
  }) : _now = now ?? DateTime.now;

  /// One cache per backend, kept for as long as the backend is alive.
  static LinkPreviewCache forSource(LinkPreviewSource source) =>
      _shared[source] ??= LinkPreviewCache(source);

  static final _shared = Expando<LinkPreviewCache>('linkPreviewCache');

  final LinkPreviewSource source;
  final Directory? _directory;
  final DateTime Function() _now;

  /// Most previews kept on disk (and in memory, with failures).
  final int maxEntries;
  final Duration negativeTtl;

  final _memory = <String, _Cached>{};
  final _inFlight = <String, Future<LinkPreview?>>{};
  Future<void>? _loading;
  Future<void> _writing = Future.value();
  Timer? _saveTimer;
  var _dirty = false;
  var _disposed = false;

  Future<File?> _file() async {
    final namespace = source.linkPreviewNamespace;
    if (namespace.isEmpty) return null;
    final base = _directory ?? await getApplicationSupportDirectory();
    return File(path.join(base.path, 'link_previews', '$namespace.json'));
  }

  /// The preview for [url], or null when there is nothing to show. One
  /// request per URL at a time, however many bubbles ask.
  Future<LinkPreview?> preview(Uri url, {int? timestamp}) {
    final key = url.toString();
    final hit = _hit(key);
    if (hit != null) return Future.value(hit.preview);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _fetch(key, url, timestamp);
    _inFlight[key] = future;
    return future.whenComplete(() => _inFlight.remove(key));
  }

  _Cached? _hit(String key) {
    final cached = _memory.remove(key);
    if (cached == null) return null;
    if (cached.preview == null && cached.expires <= _millis()) return null;
    // Re-insert at the end: the map doubles as an LRU.
    _memory[key] = cached;
    return cached;
  }

  int _millis() => _now().millisecondsSinceEpoch;

  Future<LinkPreview?> _fetch(String key, Uri url, int? timestamp) async {
    try {
      await _ensureLoaded();
      final hit = _hit(key);
      if (hit != null) return hit.preview;
      final preview = await source.fetchLinkPreview(url, timestamp: timestamp);
      if (preview == null || preview.isEmpty) {
        _remember(key, null);
        return null;
      }
      _remember(key, preview);
      _scheduleSave();
      return preview;
    } catch (_) {
      _remember(key, null);
      return null;
    }
  }

  void _remember(String key, LinkPreview? preview) {
    _memory.remove(key);
    _memory[key] = _Cached(
      preview,
      preview == null ? _millis() + negativeTtl.inMilliseconds : 0,
    );
    while (_memory.length > maxEntries * 2) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<void> _ensureLoaded() => _loading ??= () async {
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['previews'] is! List) return;
      // Newest last; entries fetched this session win over the file.
      for (final raw in (decoded['previews'] as List).toList().reversed) {
        final preview = LinkPreview.fromJson(raw);
        if (preview == null) continue;
        final key = preview.url.toString();
        if (_memory.containsKey(key)) continue;
        _memory[key] = _Cached(preview, 0);
      }
      while (_memory.length > maxEntries) {
        _memory.remove(_memory.keys.first);
      }
    } catch (_) {
      // A missing or unreadable cache just means fetching again.
    }
  }();

  void _scheduleSave() {
    // Memory-only (no account, or a test): nothing to save, no timer.
    if (_disposed || source.linkPreviewNamespace.isEmpty) return;
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  /// Writes pending previews to disk (debounced by [_scheduleSave]).
  Future<void> flush() {
    _saveTimer?.cancel();
    if (!_dirty) return _writing;
    _dirty = false;
    return _writing = _writing.then((_) => _write()).catchError((Object _) {});
  }

  Future<void> _write() async {
    final file = await _file();
    if (file == null) return;
    final previews = [
      for (final cached in _memory.values)
        if (cached.preview != null) cached.preview!.toJson(),
    ];
    final keep = previews.length <= maxEntries
        ? previews
        : previews.sublist(previews.length - maxEntries);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'previews': keep}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  /// Forgets everything and deletes the saved file.
  Future<void> clear() async {
    _memory.clear();
    _dirty = false;
    _saveTimer?.cancel();
    final file = await _file();
    if (file != null && await file.exists()) await file.delete();
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
  }

  /// Deletes the saved previews of an account (sign-out, session end).
  static Future<void> deleteAccount(String namespace, {Directory? root}) async {
    if (namespace.isEmpty) return;
    try {
      final base = root ?? await getApplicationSupportDirectory();
      final file = File(
        path.join(base.path, 'link_previews', '$namespace.json'),
      );
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class _Cached {
  const _Cached(this.preview, this.expires);
  final LinkPreview? preview;

  /// When a failure may be retried; 0 for a successful preview.
  final int expires;
}
