import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:parallax/media_viewer.dart';
import 'package:parallax/messaging_features.dart';

DownloadedAttachment media([String mime = 'audio/ogg']) => DownloadedAttachment(
  name: '../../voice.ogg',
  mimeType: mime,
  bytes: Uint8List.fromList([1, 2, 3]),
);

class FakeFile implements MediaTempFile {
  FakeFile(this.log);
  final List<String> log;
  int deletes = 0;
  @override
  String get path => '/fake/private/clip.ogg';
  @override
  Future<void> delete() async {
    deletes++;
    log.add('delete');
  }
}

class FakePlayer extends MediaPlaybackController {
  FakePlayer(this.log);
  final List<String> log;
  Completer<void>? initialization;
  Completer<void>? disposal;
  Completer<void>? playing;
  bool failInit = false;
  bool failDispose = false;
  int disposals = 0;
  int pauses = 0;
  Duration lastSeek = Duration.zero;
  MediaPlaybackValue state = const MediaPlaybackValue(
    duration: Duration(seconds: 30),
  );
  @override
  MediaPlaybackValue get value => state;
  @override
  Future<void> initialize() async {
    log.add('initialize');
    await initialization?.future;
    if (failInit) throw StateError('codec');
    log.add('initialized');
  }

  @override
  Future<void> play() async {
    log.add('play');
    await playing?.future;
    state = const MediaPlaybackValue(
      duration: Duration(seconds: 30),
      playing: true,
    );
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    pauses++;
    log.add('pause');
    state = const MediaPlaybackValue(duration: Duration(seconds: 30));
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
  }

  @override
  Widget buildVideo(BuildContext context) => const Text('native video');
  @override
  Future<void> disposePlayer() async {
    disposals++;
    log.add('dispose-start');
    await disposal?.future;
    if (failDispose) throw StateError('native release failed');
    log.add('dispose-end');
    super.dispose();
  }
}

class FakeBackend extends ChatBackend {
  String? identity = '@one:example.org';
  SessionStatus status = SessionStatus.ready;
  final requested = <String>[];
  Future<DownloadedAttachment> Function()? loader;
  @override
  String? get userId => identity;
  @override
  SessionStatus get connection => status;
  @override
  Future<DownloadedAttachment> loadAttachment(String roomId, String eventId) {
    requested.add('$roomId/$eventId');
    return loader?.call() ?? Future.value(media());
  }

  void changeAccount(String? id) {
    identity = id;
    if (id == null) status = SessionStatus.signedOut;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeFeatureBackend extends FakeBackend implements MessagingFeatures {
  String key = 'account-session-one';
  @override
  String get accountKey => key;
  void rotateSession() {
    key = 'account-session-two';
    notifyListeners();
  }
}

Future<ui.Image> makeTestImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xffabcdef), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(8, 6);
  } finally {
    picture.dispose();
  }
}

void main() {
  testWidgets(
    'production opener pushes a closeable route and requests the exact original',
    (tester) async {
      final backend = FakeBackend()
        ..loader = () async => media('application/pdf');
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  await openMediaViewer(
                    context,
                    backend: backend,
                    roomId: '!original',
                    eventId: 'original-event',
                  );
                  closed = true;
                },
                child: const Text('Open original'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open original'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsOneWidget);
      expect(backend.requested, ['!original/original-event']);
      await tester.tap(find.byTooltip('Close media'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsNothing);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'back navigation starts disposal before its reverse transition completes',
    (tester) async {
      final backend = FakeBackend();
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log);
      late BuildContext navigationContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              navigationContext = context;
              return TextButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => MediaViewer(
                        backend: backend,
                        roomId: '!r',
                        eventId: 'e',
                        fileFactory: (_) async => file,
                        playerFactory: (_, _) => player,
                      ),
                    ),
                  );
                },
                child: const Text('View'),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      Navigator.of(navigationContext).pop();
      await tester.pump();
      expect(player.disposals, 1);
      expect(file.deletes, 1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-user accountKey rotation invalidates the viewer', (
    tester,
  ) async {
    final backend = FakeFeatureBackend();
    final file = FakeFile([]);
    final player = FakePlayer([]);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewer(
          backend: backend,
          roomId: '!r',
          eventId: 'e',
          fileFactory: (_) async => file,
          playerFactory: (_, _) => player,
        ),
      ),
    );
    await tester.pump();
    backend.rotateSession();
    await tester.pump();
    expect(find.text('This media session has ended.'), findsOneWidget);
    expect(file.deletes, 1);
    expect(player.disposals, 1);
  });

  testWidgets(
    'native runtime failure is retryable and releases the reader before file',
    (tester) async {
      final backend = FakeBackend();
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            fileFactory: (_) async => file,
            playerFactory: (_, _) => player,
          ),
        ),
      );
      await tester.pump();
      player.state = const MediaPlaybackValue(error: 'sensitive native path');
      player.notifyListeners();
      await tester.pump();
      expect(find.text('Could not open media.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(log.indexOf('dispose-end'), lessThan(log.indexOf('delete')));
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'real temp files are private unique paths, contain original bytes and delete idempotently',
    () async {
      // Ordinary test, never real filesystem work inside testWidgets fakeAsync.
      final root = await Directory(
        'build/media-viewer-files',
      ).create(recursive: true);
      final fixture = await root.createTemp('case-');
      try {
        final first = await createMediaTempFile(
          media(),
          temporaryDirectory: fixture,
        );
        final second = await createMediaTempFile(
          media(),
          temporaryDirectory: fixture,
        );
        expect(first.path, isNot(second.path));
        expect(first.path, startsWith('${fixture.path}/parallax-media-'));
        expect(first.path, endsWith('/media.ogg'));
        expect(first.path, isNot(contains('../')));
        expect(await File(first.path).readAsBytes(), media().bytes);
        final deleting = first.delete();
        expect(identical(deleting, first.delete()), isTrue);
        await deleting;
        expect(await File(first.path).exists(), isFalse);
        expect(await File(second.path).exists(), isTrue);
        await second.delete();
      } finally {
        await fixture.delete(recursive: true);
      }
    },
  );

  test(
    'real engine image decoder accepts a PNG and rejects malformed data',
    () async {
      final source = await makeTestImage();
      final encoded = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      final image = await decodeMediaImage(encoded!.buffer.asUint8List());
      expect(image.width, 8);
      expect(image.height, 6);
      image.dispose();
      await expectLater(
        decodeMediaImage(Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
    },
  );

  test(
    'empty, oversized and unsupported attachments create no plaintext or player',
    () async {
      for (final attachment in [
        DownloadedAttachment(
          name: 'empty',
          mimeType: 'video/mp4',
          bytes: Uint8List(0),
        ),
        DownloadedAttachment(
          name: 'large',
          mimeType: 'video/mp4',
          bytes: Uint8List(20 * 1024 * 1024 + 1),
        ),
        media('application/pdf'),
      ]) {
        var created = 0;
        final owner = MediaPlayerOwner(
          loader: () async => attachment,
          fileFactory: (_) async {
            created++;
            return FakeFile([]);
          },
        );
        await expectLater(owner.load(), throwsFormatException);
        await owner.close();
        expect(created, 0);
      }
    },
  );

  test(
    'deletion waits for asynchronous native disposal, including duplicate close',
    () async {
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log)..disposal = Completer<void>();
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => player,
      );
      await owner.load();
      final closing = owner.close();
      await Future<void>.delayed(Duration.zero);
      expect(player.disposals, 1);
      expect(file.deletes, 0);
      expect(identical(closing, owner.close()), isTrue);
      player.disposal!.complete();
      await closing;
      expect(log.last, 'delete');
    },
  );

  test(
    'a synchronous player factory failure still releases its plaintext file',
    () async {
      final file = FakeFile([]);
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => throw StateError('native creation failed'),
      );
      await expectLater(owner.load(), throwsStateError);
      await owner.close();
      expect(file.deletes, 1);
    },
  );

  testWidgets(
    'image is zoomable without any disk or player creation and clears on logout',
    (tester) async {
      final image = (await tester.runAsync(makeTestImage))!;
      final backend = FakeBackend()..loader = () async => media('image/png');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            imageDecoder: (_) async => image,
            fileFactory: (_) => throw StateError('images must not touch disk'),
            playerFactory: (_, _) =>
                throw StateError('images must not create players'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, image);
      backend.changeAccount(null);
      await tester.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(image.debugDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late image decode after navigation is owned and disposed', (
    tester,
  ) async {
    final image = (await tester.runAsync(makeTestImage))!;
    final decoded = Completer<ui.Image>();
    final backend = FakeBackend()..loader = () async => media('image/png');
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewer(
          backend: backend,
          roomId: '!r',
          eventId: 'e',
          imageDecoder: (_) => decoded.future,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    decoded.complete(image);
    await tester.pump();
    expect(image.debugDisposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
    'close joins late file creation and deletes it without making a player',
    () async {
      final log = <String>[];
      final file = FakeFile(log);
      final writing = Completer<MediaTempFile>();
      final entered = Completer<void>();
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) {
          entered.complete();
          return writing.future;
        },
        playerFactory: (_, _) => throw StateError('must not create'),
      );
      final loading = owner.load();
      final outcome = expectLater(loading, throwsA(isA<MediaViewerClosed>()));
      await entered.future;
      final closing = owner.close();
      expect(identical(closing, owner.close()), isTrue);
      expect(file.deletes, 0);
      writing.complete(file);
      await outcome;
      await closing;
      expect(log, ['delete']);
    },
  );

  test(
    'close joins initialization then disposes BEFORE deleting plaintext',
    () async {
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log)..initialization = Completer<void>();
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => player,
      );
      final loading = owner.load();
      final outcome = expectLater(loading, throwsA(isA<MediaViewerClosed>()));
      await Future<void>.delayed(Duration.zero);
      final closing = owner.close();
      expect(file.deletes, 0);
      player.initialization!.complete();
      await outcome;
      await closing;
      expect(log, [
        'initialize',
        'initialized',
        'dispose-start',
        'dispose-end',
        'delete',
      ]);
      expect(player.disposals, 1);
    },
  );

  test(
    'initialization error and concurrent close release exactly once',
    () async {
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log)..failInit = true;
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => player,
      );
      await expectLater(owner.load(), throwsStateError);
      await Future.wait([owner.close(), owner.close()]);
      expect(player.disposals, 1);
      expect(file.deletes, 1);
      expect(log.indexOf('dispose-end'), lessThan(log.indexOf('delete')));
    },
  );

  testWidgets(
    'init timeout reports failure but retains file until late init and disposal join',
    (tester) async {
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log)..initialization = Completer<void>();
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => player,
        initializationTimeout: const Duration(seconds: 1),
      );
      final outcome = expectLater(
        owner.load(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await outcome;
      final closing = owner.close();
      expect(file.deletes, 0);
      player.initialization!.complete();
      await tester.pump();
      await closing;
      expect(log.last, 'delete');
    },
  );

  test(
    'native disposal failure never deletes a possibly in-use file',
    () async {
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log)..failDispose = true;
      final owner = MediaPlayerOwner(
        loader: () async => media(),
        fileFactory: (_) async => file,
        playerFactory: (_, _) => player,
      );
      await owner.load();
      await expectLater(owner.close(), throwsStateError);
      expect(file.deletes, 0);
    },
  );

  test('close joins an in-flight playback command before disposal', () async {
    final log = <String>[];
    final file = FakeFile(log);
    final player = FakePlayer(log)..playing = Completer<void>();
    final owner = MediaPlayerOwner(
      loader: () async => media(),
      fileFactory: (_) async => file,
      playerFactory: (_, _) => player,
    );
    await owner.load();
    final playing = owner.play();
    await Future<void>.delayed(Duration.zero);
    final closing = owner.close();
    expect(player.disposals, 0);
    player.playing!.complete();
    await playing;
    await closing;
    expect(log.last, 'delete');
    await owner.play();
    expect(log.where((s) => s == 'play'), hasLength(1));
  });

  testWidgets(
    'downloads exact original, controls playback/seek and pauses on background',
    (tester) async {
      final backend = FakeBackend();
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!room',
            eventId: r'$event',
            fileFactory: (_) async => file,
            playerFactory: (_, _) => player,
          ),
        ),
      );
      await tester.pump();
      expect(backend.requested, [r'!room/$event']);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(find.byTooltip('Pause'), findsOneWidget);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(15000);
      await tester.pump();
      expect(player.lastSeek, const Duration(seconds: 15));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(player.pauses, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(file.deletes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loading, download error and retry are reachable', (
    tester,
  ) async {
    final backend = FakeBackend();
    final pending = Completer<DownloadedAttachment>();
    backend.loader = () => pending.future;
    final log = <String>[];
    final file = FakeFile(log);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewer(
          backend: backend,
          roomId: '!r',
          eventId: 'event',
          fileFactory: (_) async => file,
          playerFactory: (_, _) => FakePlayer(log),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(StateError('private server detail'));
    await tester.pump();
    expect(find.text('Could not open media.'), findsOneWidget);
    expect(find.textContaining('private server detail'), findsNothing);
    backend.loader = () async => media('video/mp4');
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('native video'), findsOneWidget);
    expect(backend.requested, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'logout invalidates and clears playback without waiting for navigation',
    (tester) async {
      final backend = FakeBackend();
      final log = <String>[];
      final file = FakeFile(log);
      final player = FakePlayer(log);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            fileFactory: (_) async => file,
            playerFactory: (_, _) => player,
          ),
        ),
      );
      await tester.pump();
      backend.changeAccount(null);
      await tester.pump();
      expect(find.text('This media session has ended.'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(player.disposals, 1);
      expect(file.deletes, 1);
      backend.changeAccount('@one:example.org');
      await tester.pump();
      expect(find.byType(Slider), findsNothing);
    },
  );

  testWidgets(
    'account switch discards late download without plaintext creation',
    (tester) async {
      final backend = FakeBackend();
      final pending = Completer<DownloadedAttachment>();
      backend.loader = () => pending.future;
      var files = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            backend: backend,
            roomId: '!r',
            eventId: 'e',
            fileFactory: (_) async {
              files++;
              return FakeFile([]);
            },
          ),
        ),
      );
      backend.changeAccount('@two:example.org');
      await tester.pump();
      pending.complete(media());
      await tester.pump();
      expect(files, 0);
      expect(find.text('This media session has ended.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('navigation during download rejects late completion', (
    tester,
  ) async {
    final backend = FakeBackend();
    final pending = Completer<DownloadedAttachment>();
    var files = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewer(
          backend: backend,
          roomId: '!r',
          eventId: 'e',
          loader: () => pending.future,
          fileFactory: (_) async {
            files++;
            return FakeFile([]);
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    pending.complete(media());
    await tester.pump();
    expect(files, 0);
    expect(tester.takeException(), isNull);
  });

  test(
    'image dimensions are checked before allocating full decoded pixels',
    () {
      expect(mediaImageDecodeSize(4000, 3000).width, lessThanOrEqualTo(4096));
      final size = mediaImageDecodeSize(4000, 3000);
      expect(size.width * size.height, lessThanOrEqualTo(4 * 1024 * 1024));
      expect(() => mediaImageDecodeSize(100000, 100000), throwsFormatException);
      expect(() => mediaImageDecodeSize(0, 1), throwsFormatException);
    },
  );
}
