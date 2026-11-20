import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/media_disk_cache.dart';
import 'package:path/path.dart' as path;

Uint8List _bytes(int length, [int value = 7]) =>
    Uint8List.fromList(List.filled(length, value));

/// Delegates to a real store and keeps each background write, so a test can
/// wait for the save itself instead of guessing how long it takes.
class _RecordingStore implements ThumbnailStore {
  _RecordingStore(this._inner);
  final ThumbnailStore _inner;
  final writes = <Future<bool>>[];

  @override
  Future<bool> contains(String key) => _inner.contains(key);
  @override
  Future<Uint8List?> read(String key) => _inner.read(key);
  @override
  Future<bool> write(String key, Uint8List bytes) {
    final write = _inner.write(key, bytes);
    writes.add(write);
    return write;
  }

  @override
  Future<MediaCacheUsage> usage() => _inner.usage();
  @override
  Future<void> clear() => _inner.clear();
}

void main() {
  // Real files in ordinary tests (not testWidgets), under the ignored build/.
  late Directory root;

  setUp(() {
    final base = Directory('build/test_media_disk_cache')
      ..createSync(recursive: true);
    root = base.createTempSync('run');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('keys', () {
    test('a download URL keys by its mxc URI, matching the mxc key', () {
      for (final download in [
        'https://matrix.example/_matrix/client/v1/media/download/example.org/abc',
        'https://matrix.example/_matrix/media/v3/download/example.org/abc',
      ]) {
        expect(
          mediaCacheKeyForDownload(Uri.parse(download)),
          'mxc://example.org/abc',
        );
      }
      expect(
        mediaCacheKeyForDownload(
          Uri.parse(
            'https://hs/_matrix/client/v1/media/download/example.org:8448/x',
          ),
        ),
        mediaCacheKeyForMxc(Uri.parse('mxc://example.org:8448/x')),
      );
      expect(
        mediaCacheKeyForMxc(Uri.parse('mxc://example.org/abc')),
        'mxc://example.org/abc',
      );
    });

    test('other URLs have no key', () {
      for (final other in [
        'https://hs/_matrix/client/v1/media/thumbnail/example.org/abc',
        'https://hs/_matrix/client/v1/media/download/example.org',
        'https://hs/_matrix/client/v1/media/download/example.org/abc/name.jpg',
      ]) {
        expect(
          mediaCacheKeyForDownload(Uri.parse(other)),
          isNull,
          reason: other,
        );
      }
    });

    test('avatars are keyed apart from the full image', () {
      final mxc = Uri.parse('mxc://example.org/face');
      expect(avatarCacheKey(mxc), isNot(mediaCacheKeyForMxc(mxc)));
    });

    test('account folders differ per homeserver, user and device', () {
      final hs = Uri.parse('https://matrix.example');
      final a = mediaCacheAccount(hs, '@a:example.org', 'DEV1');
      expect(a, hasLength(32));
      expect(mediaCacheAccount(hs, '@a:example.org', 'DEV1'), a);
      expect(mediaCacheAccount(hs, '@a:example.org', 'DEV2'), isNot(a));
      expect(mediaCacheAccount(hs, '@b:example.org', 'DEV1'), isNot(a));
    });
  });

  test('saves, reads and counts files, and clears them', () async {
    final cache = await MediaDiskCache.open('acct', root: root);
    expect(await cache.read('k1'), isNull);
    expect(await cache.contains('k1'), isFalse);
    expect(await cache.write('k1', _bytes(10, 1)), isTrue);
    expect(await cache.write('k2', _bytes(20, 2)), isTrue);
    // Saving an existing key again is fine.
    expect(await cache.write('k1', _bytes(10, 1)), isTrue);
    expect(await cache.contains('k1'), isTrue);
    expect(await cache.read('k1'), _bytes(10, 1));
    final usage = await cache.usage();
    expect(usage.files, 2);
    expect(usage.bytes, 30);
    // File names don't reveal the media IDs.
    final names = cache.directory.listSync().map((e) => path.basename(e.path));
    expect(names.any((name) => name.contains('k1')), isFalse);

    await cache.clear();
    expect(await cache.read('k1'), isNull);
    expect((await cache.usage()).files, 0);
  });

  test('skips empty and oversized files', () async {
    final cache = MediaDiskCache(
      Directory(path.join(root.path, 'small'))..createSync(),
      maxFileBytes: 100,
    );
    expect(await cache.write('empty', Uint8List(0)), isFalse);
    expect(await cache.write('big', _bytes(101)), isFalse);
    expect(await cache.write('ok', _bytes(100)), isTrue);
    expect((await cache.usage()).files, 1);
  });

  test('evicts the least recently used files past its size limit', () async {
    final dir = Directory(path.join(root.path, 'lru'))..createSync();
    final cache = MediaDiskCache(dir, maxBytes: 1000);
    await cache.write('old', _bytes(400, 1));
    await cache.write('used', _bytes(400, 2));
    // Make the ages explicit (file times can have one-second resolution).
    final now = DateTime.now();
    for (final file in dir.listSync().whereType<File>()) {
      file.setLastModifiedSync(now.subtract(const Duration(hours: 2)));
    }
    final used = await cache.read('used');
    expect(used, isNotNull);
    // read() refreshes the time in the background.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // 1,200 bytes > 1,000: trims to 900 by dropping the oldest ("old").
    await cache.write('new', _bytes(400, 3));
    expect(await cache.contains('old'), isFalse);
    expect(await cache.contains('used'), isTrue);
    expect(await cache.contains('new'), isTrue);
    expect((await cache.usage()).bytes, 800);
  });

  test('a closed cache neither reads nor writes', () async {
    final cache = await MediaDiskCache.open('acct', root: root);
    await cache.write('k', _bytes(5));
    cache.close();
    expect(await cache.read('k'), isNull);
    expect(await cache.contains('k'), isFalse);
    expect(await cache.write('k2', _bytes(5)), isFalse);
  });

  test('a write never recreates a deleted folder (sign-out)', () async {
    final cache = await MediaDiskCache.open('acct', root: root);
    await cache.directory.delete(recursive: true);
    expect(await cache.write('k', _bytes(5)), isFalse);
    expect(cache.directory.existsSync(), isFalse);
  });

  test('opening one account deletes folders left by others', () async {
    final old = await MediaDiskCache.open('old-account', root: root);
    await old.write('k', _bytes(5));
    final current = await MediaDiskCache.open('new-account', root: root);
    expect(old.directory.existsSync(), isFalse);
    expect(current.directory.existsSync(), isTrue);
    await MediaDiskCache.deleteAll(root: root);
    expect(root.existsSync(), isFalse);
  });

  group('cachedMediaDownload', () {
    final download = Uri.parse(
      'https://hs/_matrix/client/v1/media/download/example.org/abc',
    );

    test('reads a saved file instead of downloading', () async {
      final cache = await MediaDiskCache.open('acct', root: root);
      await cache.write('mxc://example.org/abc', _bytes(8, 4));
      var downloads = 0;
      final bytes = await cachedMediaDownload(cache, download, 100, (_) async {
        downloads++;
        return _bytes(8, 9);
      });
      expect(bytes, _bytes(8, 4));
      expect(downloads, 0);
    });

    test('downloads once, then serves the saved copy', () async {
      final cache = _RecordingStore(
        await MediaDiskCache.open('acct', root: root),
      );
      var downloads = 0;
      Future<Uint8List> fetch(Uri _) async {
        downloads++;
        return _bytes(8, 5);
      }

      expect(
        await cachedMediaDownload(cache, download, 100, fetch),
        _bytes(8, 5),
      );
      // The save runs in the background; wait for it rather than a fixed
      // delay, which a loaded CI machine can outlast.
      expect(cache.writes, hasLength(1));
      expect(await cache.writes.single, isTrue);
      expect(
        await cachedMediaDownload(cache, download, 100, fetch),
        _bytes(8, 5),
      );
      expect(downloads, 1);
    });

    test('a saved file over the caller\'s limit is downloaded again', () async {
      final cache = await MediaDiskCache.open('acct', root: root);
      await cache.write('mxc://example.org/abc', _bytes(50));
      var downloads = 0;
      await cachedMediaDownload(cache, download, 10, (_) async {
        downloads++;
        return _bytes(5);
      });
      expect(downloads, 1);
    });

    test('without a store, or for other URLs, it just downloads', () async {
      var downloads = 0;
      Future<Uint8List> fetch(Uri _) async {
        downloads++;
        return _bytes(3);
      }

      await cachedMediaDownload(null, download, 100, fetch);
      final cache = await MediaDiskCache.open('acct', root: root);
      await cachedMediaDownload(
        cache,
        Uri.parse('https://hs/_matrix/client/v1/media/thumbnail/x/y'),
        100,
        fetch,
      );
      expect(downloads, 2);
      expect((await cache.usage()).files, 0);
    });
  });
}
