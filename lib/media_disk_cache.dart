/// Thumbnails and avatars kept on disk, so they show straight away after a
/// restart or without a connection.
///
/// Entries hold exactly the bytes the homeserver returned for a media ID:
/// thumbnails from encrypted rooms stay ciphertext, and the SDK decrypts
/// (and checks the hash of) them on each read, as it does for a download.
/// Avatars and media from unencrypted rooms are stored as served. Files live
/// in the app's private cache directory, one folder per signed-in session;
/// the folder is deleted when the session ends, and Android may clear it
/// when the phone runs low on space.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Where thumbnails are saved: the sync in Settings → Media writes to it,
/// and the timeline, media previews and avatars read from it first.
abstract interface class ThumbnailStore {
  Future<bool> contains(String key);
  Future<Uint8List?> read(String key);

  /// Saves [bytes] under [key]; false when not saved (too large, closed).
  Future<bool> write(String key, Uint8List bytes);
  Future<MediaCacheUsage> usage();
  Future<void> clear();
}

/// Backends that keep a [ThumbnailStore] for the signed-in session.
abstract interface class MediaCacheAccess {
  /// The current session's store, or null when unavailable (signed out, no
  /// storage plugin in tests, disk errors).
  Future<ThumbnailStore?> thumbnailStore();
}

/// Size of the saved thumbnails.
class MediaCacheUsage {
  const MediaCacheUsage({required this.files, required this.bytes});
  static const empty = MediaCacheUsage(files: 0, bytes: 0);
  final int files;
  final int bytes;
}

/// Cache key for an avatar as the app draws it (a 96 px server thumbnail).
String avatarCacheKey(Uri mxc) => 'avatar96:$mxc';

/// Cache key for a high-resolution link-preview photo or video poster.
String previewImageCacheKey(Uri mxc) => 'preview800:$mxc';

/// Cache key for the media a download URL serves: its `mxc://` URI. Works
/// for `/_matrix/client/v1/media/download/…` and `/_matrix/media/v3/…`.
String? mediaCacheKeyForDownload(Uri download) {
  final segments = download.pathSegments;
  final at = segments.indexOf('download');
  if (at < 0 || segments.length != at + 3) return null;
  final server = segments[at + 1];
  final id = segments[at + 2];
  if (server.isEmpty || id.isEmpty) return null;
  return 'mxc://$server/$id';
}

/// Cache key for an `mxc://` URI, matching [mediaCacheKeyForDownload].
String mediaCacheKeyForMxc(Uri mxc) => 'mxc://${mxc.authority}${mxc.path}';

/// [download]s [uri] unless [store] already holds its media, then saves the
/// result. Saving happens in the background and never fails the download.
Future<Uint8List> cachedMediaDownload(
  ThumbnailStore? store,
  Uri uri,
  int maxBytes,
  Future<Uint8List> Function(Uri uri) download,
) async {
  final key = store == null ? null : mediaCacheKeyForDownload(uri);
  if (key != null) {
    final saved = await store!.read(key);
    if (saved != null && saved.lengthInBytes <= maxBytes) return saved;
  }
  final bytes = await download(uri);
  if (key != null) unawaited(store!.write(key, bytes));
  return bytes;
}

/// Account-scoped folder name for [homeserver], [user] and [device].
String mediaCacheAccount(Uri? homeserver, String? user, String? device) =>
    sha256
        .convert(utf8.encode(jsonEncode(['$homeserver', user, device])))
        .toString()
        .substring(0, 32);

/// A [ThumbnailStore] in a directory, trimmed to [maxBytes] by evicting the
/// least recently used files.
class MediaDiskCache implements ThumbnailStore {
  MediaDiskCache(
    this.directory, {
    this.maxBytes = defaultMaxBytes,
    this.maxFileBytes = defaultMaxFileBytes,
  });

  static const defaultMaxBytes = 1024 * 1024 * 1024;

  /// Larger files (originals of photos without a thumbnail) aren't kept.
  static const defaultMaxFileBytes = 4 * 1024 * 1024;

  static const _folder = 'media_cache';

  final Directory directory;
  final int maxBytes;
  final int maxFileBytes;
  bool _closed = false;
  int _writes = 0;

  /// Running totals once the folder has been scanned.
  int? _bytes;
  int? _files;
  Future<void>? _scanning;
  Future<void>? _trimming;

  static Future<Directory> _root() async => Directory(
    path.join((await getApplicationCacheDirectory()).path, _folder),
  );

  /// Opens the store for [account] and deletes any other account's folder:
  /// Parallax has one session at a time, so they are left over from a
  /// sign-out that happened while the app wasn't running.
  static Future<MediaDiskCache> open(
    String account, {
    Directory? root,
    int maxBytes = defaultMaxBytes,
  }) async {
    final base = root ?? await _root();
    await base.create(recursive: true);
    await for (final entity in base.list()) {
      if (entity is Directory && path.basename(entity.path) != account) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    }
    final directory = Directory(path.join(base.path, account));
    await directory.create(recursive: true);
    return MediaDiskCache(directory, maxBytes: maxBytes);
  }

  /// Deletes every account's saved thumbnails.
  static Future<void> deleteAll({Directory? root}) async {
    final base = root ?? await _root();
    if (await base.exists()) await base.delete(recursive: true);
  }

  /// Stops reads and writes; used before the folder is deleted.
  void close() => _closed = true;

  File _file(String key) => File(
    path.join(directory.path, sha256.convert(utf8.encode(key)).toString()),
  );

  @override
  Future<bool> contains(String key) async {
    if (_closed) return false;
    try {
      return await _file(key).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Uint8List?> read(String key) async {
    if (_closed) return null;
    final file = _file(key);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // Least recently used eviction goes by modification time.
      unawaited(file.setLastModified(DateTime.now()).catchError((Object _) {}));
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> write(String key, Uint8List bytes) async {
    if (_closed || bytes.isEmpty || bytes.lengthInBytes > maxFileBytes) {
      return false;
    }
    final file = _file(key);
    // Unique per write: the timeline and a sync can save the same key at
    // once, and each rename replaces the file atomically.
    final partial = File('${file.path}.${_writes++}.part');
    try {
      if (await file.exists()) return true;
      // Never recreate the folder: it is deleted at sign-out, possibly while
      // a download is still finishing.
      await partial.writeAsBytes(bytes, flush: true);
      if (_closed) {
        await partial.delete();
        return false;
      }
      await partial.rename(file.path);
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return false;
    }
    if (_bytes == null) {
      // First write since opening: count what's there (includes this file).
      await _scan();
    } else {
      _bytes = _bytes! + bytes.lengthInBytes;
      _files = _files! + 1;
    }
    if ((_bytes ?? 0) > maxBytes) await _trim();
    return true;
  }

  Future<void> _scan() => _scanning ??= () async {
    var bytes = 0;
    var files = 0;
    try {
      await for (final entity in directory.list()) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        try {
          bytes += await entity.length();
          files++;
        } catch (_) {}
      }
    } catch (_) {}
    _bytes = bytes;
    _files = files;
  }();

  /// Deletes the oldest files until the store is under 90% of [maxBytes].
  Future<void> _trim() => _trimming ??= () async {
    try {
      final entries = <(File, DateTime, int)>[];
      await for (final entity in directory.list()) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        try {
          final stat = await entity.stat();
          entries.add((entity, stat.modified, stat.size));
        } catch (_) {}
      }
      entries.sort((a, b) => a.$2.compareTo(b.$2));
      var total = entries.fold<int>(0, (sum, entry) => sum + entry.$3);
      var files = entries.length;
      final target = maxBytes * 9 ~/ 10;
      for (final (file, _, size) in entries) {
        if (total <= target || _closed) break;
        try {
          await file.delete();
          total -= size;
          files--;
        } catch (_) {}
      }
      _bytes = total;
      _files = files;
    } catch (_) {
    } finally {
      _trimming = null;
    }
  }();

  @override
  Future<MediaCacheUsage> usage() async {
    if (_closed) return MediaCacheUsage.empty;
    await _scan();
    return MediaCacheUsage(files: _files ?? 0, bytes: _bytes ?? 0);
  }

  @override
  Future<void> clear() async {
    if (_closed) return;
    try {
      await for (final entity in directory.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    _scanning = null;
    _bytes = 0;
    _files = 0;
  }
}
