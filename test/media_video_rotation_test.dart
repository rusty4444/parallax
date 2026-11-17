// How a playing video is sized from what the video plugin reports.
//
// A phone camera stores a portrait recording as landscape frames plus a
// rotation flag. The Android plugin reports such a video at the size it is
// shown (portrait) together with a rotation correction that its own widget
// uses to turn the frames. integration_test/video_rotation_test.dart checks
// on a device that the plugin really reports this.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/link_previews/link_video_player.dart';
import 'package:parallax/features/media/media_content.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _frames = Key('video frames');

/// Reports one video the way the platform plugin would.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  _FakeVideoPlatform({required this.size, required this.rotationCorrection});

  final Size size;
  final int rotationCorrection;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 7;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 3),
      size: size,
      rotationCorrection: rotationCorrection,
    ),
  );

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: _frames);

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

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

  setUp(() => original = VideoPlayerPlatform.instance);
  tearDown(() => VideoPlayerPlatform.instance = original);

  void report(Size size, int rotationCorrection) {
    VideoPlayerPlatform.instance = _FakeVideoPlatform(
      size: size,
      rotationCorrection: rotationCorrection,
    );
  }

  testWidgets('a phone-camera portrait recording plays in a portrait box', (
    tester,
  ) async {
    report(const Size(1080, 1920), 90);
    // The plugin's controller is opened and closed on the real event loop.
    final player = (await tester.runAsync(() async {
      final player = createNativeMediaPlayer(_Clip(), 'video/mp4');
      await player.initialize();
      return player;
    }))!;
    expect(player.value.aspectRatio, closeTo(1080 / 1920, 0.001));

    // The timeline bubble sizes itself like this while a video plays.
    final box = mediaPreviewSizeForAspect(player.value.aspectRatio);
    expect(box.height, greaterThan(box.width));
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: box,
            child: Builder(builder: player.buildVideo),
          ),
        ),
      ),
    );
    // The video fills the box: no bars, nothing stretched.
    expect(tester.getSize(find.byType(VideoPlayer)), box);
    // The plugin's widget turns the landscape frames upright by itself.
    expect(tester.getSize(find.byKey(_frames)), box.flipped);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(player.disposePlayer);
  });

  test('other recordings keep the reported shape', () async {
    for (final (size, correction, expected) in [
      (const Size(1080, 1920), 270, 1080 / 1920),
      (const Size(1080, 1920), 0, 1080 / 1920),
      (const Size(1920, 1080), 0, 1920 / 1080),
      (const Size(1920, 1080), 180, 1920 / 1080),
    ]) {
      report(size, correction);
      final player = createNativeMediaPlayer(_Clip(), 'video/mp4');
      await player.initialize();
      expect(
        player.value.aspectRatio,
        closeTo(expected, 0.001),
        reason: '$size with correction $correction',
      );
      await player.disposePlayer();
    }
  });

  test('a linked portrait video plays in a portrait box', () async {
    report(const Size(1080, 1920), 90);
    final controller = createNetworkLinkVideoController(
      Uri.parse('https://example.org/clip.mp4'),
    );
    await controller.initialize();
    expect(controller.aspectRatio, closeTo(1080 / 1920, 0.001));
    await controller.dispose();
  });
}
