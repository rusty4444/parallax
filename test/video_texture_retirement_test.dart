// Native video textures must leave the screen before their player releases
// them, and media files need a temporary folder that exists.
//
// Releasing a texture the raster thread is still drawing crashes the app on
// macOS (SIGSEGV in EmbedderExternalTextureMetal::ResolveTexture,
// flutter/flutter#195730); video_player_win has the same unsafe pattern.
// On macOS the platform temporary folder (Library/Caches/<bundle id>) is not
// created by path_provider, so every inline video failed to open.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/link_previews/link_video_player.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _frames = Key('video frames');

/// Records what the app asks of the native video plugin.
class _RecordingVideoPlatform extends VideoPlayerPlatform {
  final calls = <String>[];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('create');
    return 7;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 3),
      size: const Size(640, 360),
    ),
  );

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: _frames);

  @override
  Future<void> dispose(int playerId) async => calls.add('dispose');

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) async {}
}

class _Clip implements MediaTempFile {
  @override
  String get path => '/clip.mp4';

  @override
  Future<void> delete() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VideoPlayerPlatform original;
  late _RecordingVideoPlatform platform;

  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _RecordingVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = original;
    debugVideoTextureRetirement = waitForFramesWithoutVideoTexture;
  });

  testWidgets('a retiring texture leaves the screen, then frames are drawn', (
    tester,
  ) async {
    final gate = VideoTextureGate();
    await tester.pumpWidget(
      MaterialApp(home: gate.build(const SizedBox.expand(key: _frames))),
    );
    expect(find.byKey(_frames), findsOneWidget);

    var retired = false;
    unawaited(gate.retire().then((_) => retired = true));
    await tester.pump();
    // Off screen from the next frame, but not yet safe to release.
    expect(find.byKey(_frames), findsNothing);
    expect(retired, isFalse);

    await tester.pump();
    expect(retired, isTrue);
    // Retiring twice is the same retirement.
    await gate.retire();
  });

  test('waiting for frames ends when the window draws none', () async {
    final clock = Stopwatch()..start();
    await waitForFramesWithoutVideoTexture(
      limit: const Duration(milliseconds: 100),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('a video message player is released only after its texture '
      'has retired, and is paused first', () async {
    final retirement = Completer<void>();
    debugVideoTextureRetirement = () => retirement.future;
    final player = createNativeMediaPlayer(_Clip(), 'video/mp4');
    await player.initialize();
    await player.play();

    platform.calls.clear();
    final disposing = player.disposePlayer();
    await pumpEventQueue();
    // Playback stops, but the player is kept while its texture may be drawn.
    expect(platform.calls, ['pause']);

    retirement.complete();
    await disposing;
    expect(platform.calls, ['pause', 'dispose']);
  });

  test('a link preview video is released only after its texture '
      'has retired', () async {
    final retirement = Completer<void>();
    debugVideoTextureRetirement = () => retirement.future;
    final controller = createNetworkLinkVideoController(
      Uri.parse('https://example.org/clip.mp4'),
    );
    await controller.initialize();

    final disposing = controller.dispose();
    await pumpEventQueue();
    expect(platform.calls, isNot(contains('dispose')));

    retirement.complete();
    await disposing;
    expect(platform.calls.last, 'dispose');
  });

  test('a video opens when the temporary folder does not exist yet', () async {
    final base = await Directory.systemTemp.createTemp('parallax-tmp-test-');
    addTearDown(() => base.delete(recursive: true));
    // What path_provider returns inside a fresh macOS sandbox container.
    final missing = Directory('${base.path}/Library/Caches/example.app');
    expect(missing.existsSync(), isFalse);

    final file = await createMediaTempFile(
      DownloadedAttachment(
        name: 'clip.mp4',
        mimeType: 'video/mp4',
        bytes: Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112]),
      ),
      temporaryDirectory: missing,
    );
    expect(File(file.path).existsSync(), isTrue);
    expect(file.path, startsWith(missing.path));
    await file.delete();
    expect(File(file.path).existsSync(), isFalse);
  });
}
