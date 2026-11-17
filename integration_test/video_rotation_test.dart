// How a portrait recording plays on a real Android device or emulator:
//   flutter test integration_test/video_rotation_test.dart -d <device>
//
// A phone camera stores a portrait video as landscape frames plus a rotation
// flag. The video plugin reports the size it is shown at (portrait) together
// with a rotation correction for its own widget. If a plugin upgrade ever
// changes that, these tests fail and videoDisplayAspectRatio needs another
// look; host tests cannot see it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:parallax/features/media/media_content.dart';
import 'package:parallax/features/media/video_prep.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'video_rotation_fixture.dart';

class _Clip implements MediaTempFile {
  _Clip(this.path);

  @override
  final String path;

  @override
  Future<void> delete() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late File clip;

  setUpAll(() async {
    final directory = await getTemporaryDirectory();
    clip = File('${directory.path}/rotated-portrait-clip.mp4');
    await clip.writeAsBytes(rotatedPortraitClip, flush: true);
  });

  tearDownAll(() async {
    if (clip.existsSync()) await clip.delete();
  });

  testWidgets('the plugin reports a rotated recording at its shown size', (
    tester,
  ) async {
    final controller = VideoPlayerController.file(clip);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(
      controller.value.size,
      Size(
        rotatedPortraitClipWidth.toDouble(),
        rotatedPortraitClipHeight.toDouble(),
      ),
      reason: 'rotationCorrection ${controller.value.rotationCorrection}',
    );
  });

  testWidgets('the sender reads a rotated recording as portrait', (
    tester,
  ) async {
    // What goes into the message: its size and its poster picture.
    final info = await VideoTools.instance.probe(clip.path);
    expect(info, isNotNull);
    expect(info!.width, rotatedPortraitClipWidth);
    expect(info.height, rotatedPortraitClipHeight);
    expect(info.thumbnail, isNotNull);
    expect(info.thumbnailHeight!, greaterThan(info.thumbnailWidth!));
  });

  testWidgets('a compressed portrait recording plays in a portrait box', (
    tester,
  ) async {
    // Long or very large recordings are re-encoded before they are sent.
    final output = await VideoTools.instance.compress(
      clip.path,
      shortSide: rotatedPortraitClipWidth,
      videoBitrate: 500000,
    );
    addTearDown(() => VideoTools.instance.delete(output));
    final info = await VideoTools.instance.probe(output);
    expect(info, isNotNull);
    expect(info!.height!, greaterThan(info.width!));
    expect(info.thumbnailHeight!, greaterThan(info.thumbnailWidth!));

    final player = createNativeMediaPlayer(_Clip(output), 'video/mp4');
    addTearDown(player.disposePlayer);
    await player.initialize();
    expect(
      player.value.aspectRatio,
      closeTo(rotatedPortraitClipWidth / rotatedPortraitClipHeight, 0.02),
    );
  });

  testWidgets('a rotated portrait recording plays in a portrait box', (
    tester,
  ) async {
    final player = createNativeMediaPlayer(_Clip(clip.path), 'video/mp4');
    addTearDown(player.disposePlayer);
    await player.initialize();
    final aspect = player.value.aspectRatio;
    expect(
      aspect,
      closeTo(rotatedPortraitClipWidth / rotatedPortraitClipHeight, 0.01),
    );

    // The timeline bubble sizes itself like this while a video plays.
    final box = mediaPreviewSizeForAspect(aspect);
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
    await tester.pump();
    // The video fills the box, so nothing is stretched or letterboxed.
    final video = tester.getSize(find.byType(VideoPlayer));
    expect(video.width, closeTo(box.width, 1));
    expect(video.height, closeTo(box.height, 1));
  });
}
