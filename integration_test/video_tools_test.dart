// Native video tools on a real Android device or emulator. Push the
// fixtures first (see docs/video-sending.md):
//   adb push video_test.mp4 video_small.mp4 \
//     /sdcard/Android/data/net.samrussell.parallax/files/
//   flutter test integration_test/video_tools_test.dart -d <device>
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:integration_test/integration_test.dart';
import 'package:parallax/features/media/video_prep.dart';
import 'package:parallax/voice_recorder.dart' show maxComposerMediaBytes;
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<String> fixture(String name) async {
    final dir = await getExternalStorageDirectory();
    final path = '${dir!.path}/$name';
    if (!File(path).existsSync()) fail('Push $name to ${dir.path} first');
    return path;
  }

  testWidgets('a 30 MB 1080p video is probed and compressed to fit', (
    tester,
  ) async {
    final path = await fixture('video_test.mp4');
    final original = await File(path).length();
    final info = await PlatformVideoTools().probe(path);
    expect(info, isNotNull);
    expect((info!.width, info.height), (1920, 1080));
    expect(info.durationMs, closeTo(20000, 300));
    expect(info.thumbnail, isNotEmpty);
    expect(info.thumbnailWidth, 800);

    final watch = Stopwatch()..start();
    final media = await prepareVideoForSending(
      XFile(path),
      mimeType: 'video/mp4',
    );
    watch.stop();
    expect(original, greaterThan(maxComposerMediaBytes));
    expect(media.bytes.length, lessThanOrEqualTo(maxComposerMediaBytes));
    expect(media.mimeType, 'video/mp4');
    expect(media.name, 'video_test.mp4');

    final compressed = await probeVideoBytes(media.bytes);
    expect(compressed, isNotNull);
    expect(compressed!.shortSide, 720);
    expect(compressed.width, 1280);
    expect(compressed.durationMs, closeTo(20000, 500));
    expect(compressed.thumbnail, isNotEmpty);
    // ignore: avoid_print
    print(
      'VIDEO original=$original compressed=${media.bytes.length} '
      'in ${watch.elapsedMilliseconds} ms '
      '${compressed.width}x${compressed.height} '
      'thumb=${compressed.thumbnail!.length}B',
    );
  });

  testWidgets('a small 720p video is sent unchanged', (tester) async {
    final path = await fixture('video_small.mp4');
    final media = await prepareVideoForSending(
      XFile(path),
      mimeType: 'video/mp4',
    );
    expect(media.bytes.length, await File(path).length());
    expect(media.durationMs, closeTo(5000, 300));
  });
}
