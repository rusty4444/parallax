import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/media/thumbnail_sync.dart';
import 'package:parallax/features/media/thumbnail_sync_section.dart';
import 'package:parallax/media_disk_cache.dart';

/// In-memory store (no file I/O, so it is safe in widget tests).
class _Store implements ThumbnailStore {
  final files = <String, Uint8List>{};
  int clears = 0;

  @override
  Future<bool> contains(String key) async => files.containsKey(key);

  @override
  Future<Uint8List?> read(String key) async => files[key];

  @override
  Future<bool> write(String key, Uint8List bytes) async {
    files[key] = bytes;
    return true;
  }

  @override
  Future<MediaCacheUsage> usage() async => MediaCacheUsage(
    files: files.length,
    bytes: files.values.fold(0, (sum, b) => sum + b.length),
  );

  @override
  Future<void> clear() async {
    clears++;
    files.clear();
  }
}

class _Pass implements ThumbnailSyncPass {
  _Pass(this.store, this.jobs);

  @override
  final ThumbnailStore store;
  final Map<String, List<ThumbnailJob>> jobs;
  bool current = true;
  final asked = <String>[];

  @override
  List<String> get roomIds => jobs.keys.toList();

  @override
  bool get isCurrent => current;

  @override
  Future<List<ThumbnailJob>> jobsFor(String roomId) async {
    asked.add(roomId);
    return jobs[roomId]!;
  }
}

class _Source implements ThumbnailSyncSource {
  _Source(this.store, this.pass);
  final _Store store;
  final _Pass? pass;

  @override
  Future<ThumbnailStore?> thumbnailStore() async => store;

  @override
  Future<ThumbnailSyncPass?> beginThumbnailSync() async => pass;
}

Uint8List _b(int value) => Uint8List.fromList([value, value]);

ThumbnailJob _job(String key, [int value = 1]) =>
    ThumbnailJob(key, () async => _b(value));

void main() {
  group('ThumbnailSync', () {
    test(
      'saves new thumbnails, counts saved ones and failures, once each',
      () async {
        final store = _Store()..files['already'] = _b(9);
        final pass = _Pass(store, {
          '!a': [_job('avatar'), _job('already'), _job('photo')],
          // The same avatar in a second chat is saved once.
          '!b': [
            _job('avatar'),
            ThumbnailJob('broken', () async => throw StateError('404')),
            ThumbnailJob('nothing', () async => null),
          ],
        });
        final sync = ThumbnailSync(_Source(store, pass));
        addTearDown(sync.dispose);
        final fractions = <double?>[];
        sync.addListener(() => fractions.add(sync.state.fraction));

        await sync.start();

        final state = sync.state;
        expect(state.running, isFalse);
        expect(state.finished, isTrue);
        expect(state.roomsDone, 2);
        expect(state.roomsTotal, 2);
        expect(state.saved, 2);
        expect(state.alreadySaved, 1);
        expect(state.failed, 2);
        expect(state.error, isNull);
        expect(store.files.keys, containsAll(['avatar', 'photo', 'already']));
        expect(fractions, containsAllInOrder([0.5, 1.0]));
        await pumpEventQueue();
        expect(sync.usage?.files, 3);
      },
    );

    test('runs at most [parallel] downloads at once', () async {
      final store = _Store();
      var running = 0;
      var peak = 0;
      final gates = <Completer<void>>[];
      ThumbnailJob slow(String key) => ThumbnailJob(key, () async {
        running++;
        peak = running > peak ? running : peak;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        running--;
        return _b(1);
      });
      final pass = _Pass(store, {
        '!a': [for (var i = 0; i < 6; i++) slow('a$i')],
        '!b': [for (var i = 0; i < 4; i++) slow('b$i')],
      });
      final sync = ThumbnailSync(_Source(store, pass), parallel: 3);
      addTearDown(sync.dispose);
      final done = sync.start();
      while (!sync.state.finished) {
        await pumpEventQueue();
        for (final gate in gates.where((g) => !g.isCompleted).toList()) {
          gate.complete();
        }
      }
      await done;
      expect(peak, 3);
      expect(sync.state.saved, 10);
    });

    test('stop starts no more downloads', () async {
      final store = _Store();
      final gate = Completer<void>();
      late ThumbnailSync sync;
      final pass = _Pass(store, {
        '!a': [
          ThumbnailJob('a', () async {
            sync.stop();
            await gate.future;
            return _b(1);
          }),
        ],
        '!b': [_job('b')],
      });
      // One at a time: "b" waits for "a"'s slot.
      sync = ThumbnailSync(_Source(store, pass), parallel: 1);
      addTearDown(sync.dispose);
      final done = sync.start();
      await pumpEventQueue();
      expect(sync.state.running, isFalse);
      expect(sync.state.stopped, isTrue);
      gate.complete();
      await done;
      // The download already under way still finished and was saved; "b"
      // never started, and the stopped state is kept.
      expect(store.files.keys, ['a']);
      expect(sync.state.stopped, isTrue);
      expect(sync.state.finished, isFalse);
    });

    test('a pass stops when its session ends', () async {
      final store = _Store();
      late _Pass pass;
      pass = _Pass(store, {
        '!a': [
          ThumbnailJob('a', () async {
            pass.current = false;
            return _b(1);
          }),
        ],
        '!b': [_job('b')],
      });
      final sync = ThumbnailSync(_Source(store, pass), parallel: 1);
      addTearDown(sync.dispose);
      await sync.start();
      expect(store.files.keys, ['a']);
      expect(sync.state.finished, isFalse);
      expect(sync.state.error, contains('signed out'));
    });

    test('reports when it cannot start', () async {
      final sync = ThumbnailSync(_Source(_Store(), null));
      addTearDown(sync.dispose);
      await sync.start();
      expect(sync.state.running, isFalse);
      expect(sync.state.error, contains('can’t be saved'));
    });

    test('clear deletes saved thumbnails and resets progress', () async {
      final store = _Store();
      final sync = ThumbnailSync(
        _Source(
          store,
          _Pass(store, {
            '!a': [_job('a')],
          }),
        ),
      );
      addTearDown(sync.dispose);
      await sync.start();
      await sync.clear();
      expect(store.clears, 1);
      expect(store.files, isEmpty);
      expect(sync.state.finished, isFalse);
      expect(sync.usage?.files, 0);
    });
  });

  test('formats counts and sizes', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(1503), '1,503');
    expect(formatCount(1234567), '1,234,567');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(84 * 1024 * 1024), '84 MB');
    expect(formatBytes(1288490189), '1.2 GB');
  });

  group('settings section', () {
    final palette = paletteFor(VisualTheme.parallax);

    Future<void> pump(WidgetTester tester, ThumbnailSync sync) async {
      tester.view
        ..physicalSize = const Size(800, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [ThumbnailSyncSection(sync: sync, palette: palette)],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('sync shows progress, can stop, and summarises', (
      tester,
    ) async {
      final store = _Store()..files['old'] = _b(1);
      final gate = Completer<void>();
      final pass = _Pass(store, {
        '!a': [_job('a')],
        '!b': [
          ThumbnailJob('b', () async {
            await gate.future;
            return _b(2);
          }),
        ],
      });
      final sync = ThumbnailSync(_Source(store, pass));
      addTearDown(sync.dispose);
      await pump(tester, sync);
      expect(find.text('OFFLINE THUMBNAILS'), findsOneWidget);
      expect(find.text('2 B · 1 file'), findsOneWidget);
      expect(find.byKey(const ValueKey('thumbnails.progress')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('thumbnails.start')));
      await tester.pump();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('1 of 2 chats · 1 saved'), findsOneWidget);
      // Can't clear while syncing.
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('thumbnails.clear')))
            .onPressed,
        isNull,
      );

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Done: 2 saved.'), findsOneWidget);
      expect(find.text('Sync again'), findsOneWidget);
      expect(find.text('6 B · 3 files'), findsOneWidget);

      // Clear asks first.
      await tester.tap(find.byKey(const ValueKey('thumbnails.clear')));
      await tester.pumpAndSettle();
      expect(find.text('Clear saved thumbnails?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();
      expect(store.files, isEmpty);
      expect(find.text('Nothing saved yet'), findsOneWidget);
    });

    testWidgets('stop leaves a summary of what was saved', (tester) async {
      final store = _Store();
      final gate = Completer<void>();
      final pass = _Pass(store, {
        '!a': [
          ThumbnailJob('a', () async {
            await gate.future;
            return _b(1);
          }),
        ],
        '!b': [_job('b')],
      });
      final sync = ThumbnailSync(_Source(store, pass));
      addTearDown(sync.dispose);
      await pump(tester, sync);
      await tester.tap(find.byKey(const ValueKey('thumbnails.start')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Finding your chats…'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('thumbnails.stop')));
      await tester.pump();
      expect(find.textContaining('Stopped after'), findsOneWidget);
      gate.complete();
      await tester.pump();
      await tester.pump();
      // "!b" finished before Stop; "!a" was still downloading.
      expect(find.text('Stopped after 1 of 2 chats: 1 saved.'), findsOneWidget);
    });
  });
}
