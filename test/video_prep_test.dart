import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:parallax/features/media/video_prep.dart';

class _Tools implements VideoTools {
  _Tools({this.info, this.output, this.throwProbe, this.sample});

  final VideoInfo? info;
  final String? output;
  final Object? throwProbe;
  final VideoFrameSample? Function(String path)? sample;
  final compressed = <(int shortSide, int bitrate)>[];
  final deleted = <String>[];

  @override
  Future<VideoInfo?> probe(String path) async {
    if (throwProbe != null) throw throwProbe!;
    return info;
  }

  @override
  Future<String> compress(
    String path, {
    required int shortSide,
    required int videoBitrate,
  }) async {
    compressed.add((shortSide, videoBitrate));
    return output!;
  }

  @override
  Future<VideoFrameSample?> sampleFrames(
    String path, {
    int maxEdge = 360,
    int maxFrames = 12,
    int maxDurationMs = 3000,
  }) async => sample?.call(path);

  @override
  Future<void> delete(String path) async => deleted.add(path);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('video-prep'));
  tearDown(() => dir.deleteSync(recursive: true));

  XFile file(String name, int bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(Uint8List(bytes));
    return XFile(f.path, name: name);
  }

  const maxBytes = 1000000;

  test('a small video that fits is sent unchanged', () async {
    final tools = _Tools(
      info: const VideoInfo(width: 1280, height: 720, durationMs: 5000),
    );
    final media = await prepareVideoForSending(
      file('clip.mov', 4000),
      mimeType: 'video/quicktime',
      tools: tools,
      maxBytes: maxBytes,
    );
    expect(media.bytes.length, 4000);
    expect(media.mimeType, 'video/quicktime');
    expect(media.durationMs, 5000);
    expect(tools.compressed, isEmpty);
  });

  test(
    'a large video is compressed to 720p with a bitrate that fits',
    () async {
      final out = file('out.mp4', 600000);
      final tools = _Tools(
        info: const VideoInfo(width: 1080, height: 1920, durationMs: 4000),
        output: out.path,
      );
      final media = await prepareVideoForSending(
        file('big.mov', 3000000),
        mimeType: 'video/quicktime',
        tools: tools,
        maxBytes: maxBytes,
      );
      // Portrait 1080x1920: short side 1080 -> 720.
      expect(tools.compressed.single.$1, 720);
      // 90 % of 1 MB over 4 s, less 128 kb/s audio: 1.67 Mb/s.
      expect(tools.compressed.single.$2, 1672000);
      expect(media.mimeType, 'video/mp4');
      expect(media.name, 'big.mp4');
      expect(media.bytes.length, 600000);
      expect(media.durationMs, 4000);
      expect(tools.deleted, [out.path]);
    },
  );

  test('high-resolution video is scaled down even when it fits', () async {
    final out = file('out.mp4', 100);
    final tools = _Tools(
      info: const VideoInfo(width: 3840, height: 2160, durationMs: 2000),
      output: out.path,
    );
    await prepareVideoForSending(
      file('4k.mp4', 500000),
      mimeType: 'video/mp4',
      tools: tools,
      maxBytes: maxBytes,
    );
    expect(tools.compressed.single.$1, 720);
    expect(tools.compressed.single.$2, 2500000);
  });

  test('a video too long to fit is refused before compressing', () async {
    final tools = _Tools(
      info: const VideoInfo(width: 1920, height: 1080, durationMs: 600000),
    );
    await expectLater(
      prepareVideoForSending(
        file('long.mp4', 3000000),
        mimeType: 'video/mp4',
        tools: tools,
        maxBytes: maxBytes,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('too long'),
        ),
      ),
    );
    expect(tools.compressed, isEmpty);
  });

  test('a compressed result that still exceeds the limit is refused', () async {
    final out = file('out.mp4', 2000000);
    final tools = _Tools(
      info: const VideoInfo(width: 1920, height: 1080, durationMs: 3000),
      output: out.path,
    );
    await expectLater(
      prepareVideoForSending(
        file('big.mp4', 3000000),
        mimeType: 'video/mp4',
        tools: tools,
        maxBytes: maxBytes,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(tools.deleted, [out.path]);
  });

  test(
    'without native tools a fitting video is sent and a big one refused',
    () async {
      final tools = _Tools(throwProbe: MissingPluginException());
      final media = await prepareVideoForSending(
        file('clip.mp4', 4000),
        mimeType: 'video/mp4',
        tools: tools,
        maxBytes: maxBytes,
      );
      expect(media.bytes.length, 4000);
      await expectLater(
        prepareVideoForSending(
          file('big.mp4', 3000000),
          mimeType: 'video/mp4',
          tools: tools,
          maxBytes: maxBytes,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('the longest video that fits is about four minutes', () {
    expect(maxVideoLengthLabel, '4 minutes');
  });

  test(
    'sampleVideoBytes passes a temporary file to native tools and cleans up',
    () async {
      String? observedPath;
      Uint8List? observedBytes;
      final tools = _Tools(
        sample: (path) {
          observedPath = path;
          observedBytes = File(path).readAsBytesSync();
          return VideoFrameSample(
            frames: [
              Uint8List.fromList([1, 2, 3]),
            ],
            delayMs: 220,
          );
        },
      );
      final result = await sampleVideoBytes(
        Uint8List.fromList([9, 8, 7, 6]),
        tools: tools,
        cacheDir: dir,
      );
      expect(result, isNotNull);
      expect(result!.delayMs, 220);
      expect(result.frames.single, [1, 2, 3]);
      expect(observedBytes, [9, 8, 7, 6]);
      expect(File(observedPath!).existsSync(), isFalse);
      expect(File(observedPath!).parent.existsSync(), isFalse);
    },
  );
}
