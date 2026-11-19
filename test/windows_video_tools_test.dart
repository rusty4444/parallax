import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/media/windows_video_tools.dart';

/// A 1x1 white JPEG (poster/frame fixture).
final _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
  'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAAB'
  'AAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
);

String _probeJson({int rotation = 0, String duration = '12.5'}) => jsonEncode({
  'streams': [
    {
      'width': 1920,
      'height': 1080,
      'duration': duration,
      if (rotation != 0)
        'side_data_list': [
          {'rotation': rotation},
        ],
    },
  ],
  'format': {'duration': duration},
});

void main() {
  late Directory tools;

  setUp(() {
    tools = Directory.systemTemp.createTempSync('parallax-tools-');
    File('${tools.path}/ffmpeg.exe').writeAsBytesSync([]);
    File('${tools.path}/ffprobe.exe').writeAsBytesSync([]);
  });

  tearDown(() {
    tools.deleteSync(recursive: true);
  });

  WindowsVideoTools make({VideoHelperRunner? runner, String? directory}) =>
      WindowsVideoTools(
        toolDirectory: directory ?? tools.path,
        pathLookup: false,
        helperRunner: runner,
      );

  group('probe', () {
    test('reports display dimensions, duration and a poster frame', () async {
      final calls = <String>[];
      final tools = make(
        runner: (tool, arguments, timeout) async {
          calls.add(tool);
          if (tool.endsWith('ffprobe.exe')) {
            return ProcessResult(0, 0, utf8.encode(_probeJson()), '');
          }
          return ProcessResult(0, 0, _jpeg, '');
        },
      );
      final info = await tools.probe('C:/videos/clip.mp4');
      expect(info, isNotNull);
      expect(info!.width, 1920);
      expect(info.height, 1080);
      expect(info.durationMs, 12500);
      expect(info.thumbnail, _jpeg);
      expect(info.thumbnailWidth, 1);
      expect(info.thumbnailHeight, 1);
      expect(calls.first, endsWith('ffprobe.exe'));
      expect(calls.last, endsWith('ffmpeg.exe'));
    });

    test('swaps dimensions for a 90 degree rotation flag', () async {
      final tools = make(
        runner: (tool, arguments, timeout) async => tool.endsWith('ffprobe.exe')
            ? ProcessResult(0, 0, utf8.encode(_probeJson(rotation: -90)), '')
            : ProcessResult(0, 0, _jpeg, ''),
      );
      final info = await tools.probe('C:/videos/clip.mp4');
      expect(info!.width, 1080);
      expect(info.height, 1920);
      expect(info.shortSide, 1080);
    });

    test('reads the legacy rotate tag', () async {
      final json = jsonEncode({
        'streams': [
          {
            'width': 1920,
            'height': 1080,
            'duration': '2',
            'tags': {'rotate': '270'},
          },
        ],
      });
      final tools = make(
        runner: (tool, arguments, timeout) async => tool.endsWith('ffprobe.exe')
            ? ProcessResult(0, 0, utf8.encode(json), '')
            : ProcessResult(0, 0, _jpeg, ''),
      );
      final info = await tools.probe('C:/videos/clip.mp4');
      expect(info!.width, 1080);
      expect(info.height, 1920);
    });

    test('returns null without the helper binaries', () async {
      final empty = Directory.systemTemp.createTempSync('parallax-empty-');
      addTearDown(() => empty.deleteSync(recursive: true));
      final tools = make(directory: empty.path);
      expect(await tools.probe('C:/videos/clip.mp4'), isNull);
    });

    test('returns null when ffprobe fails', () async {
      final tools = make(
        runner: (tool, arguments, timeout) async =>
            ProcessResult(1, 0, [], 'bad'),
      );
      expect(await tools.probe('C:/videos/clip.mp4'), isNull);
    });
  });

  group('compress', () {
    test('re-encodes to the requested short side and bitrate', () async {
      List<String>? captured;
      final tools = make(
        runner: (tool, arguments, timeout) async {
          captured = arguments;
          File(arguments.last).writeAsBytesSync([0]);
          return ProcessResult(0, 0, [], '');
        },
      );
      final output = await tools.compress(
        'C:/videos/clip.mp4',
        shortSide: 720,
        videoBitrate: 2500000,
      );
      expect(File(output).existsSync(), isTrue);
      expect(
        captured,
        contains("scale=w='if(gt(iw,ih),-2,720)':h='if(gt(iw,ih),720,-2)'"),
      );
      expect(captured, containsAllInOrder(['-b:v', '2500000']));
      expect(captured, containsAllInOrder(['-c:v', 'libx264']));
      expect(captured, containsAllInOrder(['-c:a', 'aac']));
      expect(captured, contains('-movflags'));
      await tools.delete(output);
      expect(File(output).existsSync(), isFalse);
    });

    test('throws when the helper fails', () async {
      final tools = make(
        runner: (tool, arguments, timeout) async =>
            ProcessResult(1, 0, [], 'bad'),
      );
      expect(
        () => tools.compress(
          'C:/videos/clip.mp4',
          shortSide: 720,
          videoBitrate: 1000000,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws without the helper binaries', () async {
      final empty = Directory.systemTemp.createTempSync('parallax-empty-');
      addTearDown(() => empty.deleteSync(recursive: true));
      final tools = make(directory: empty.path);
      expect(
        () => tools.compress(
          'C:/videos/clip.mp4',
          shortSide: 720,
          videoBitrate: 1000000,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('sampleFrames', () {
    test('splits the MJPEG stream into frames with a delay', () async {
      final tools = make(
        runner: (tool, arguments, timeout) async {
          if (tool.endsWith('ffprobe.exe')) {
            return ProcessResult(
              0,
              0,
              utf8.encode(_probeJson(duration: '2')),
              '',
            );
          }
          return ProcessResult(0, 0, [..._jpeg, ..._jpeg], '');
        },
      );
      final sample = await tools.sampleFrames('C:/videos/clip.mp4');
      expect(sample, isNotNull);
      expect(sample!.frames.length, 2);
      expect(sample.frames.first, _jpeg);
      // 2 s sampled across 2 frames.
      expect(sample.delayMs, 1000);
    });

    test('returns null when no frames come back', () async {
      final tools = make(
        runner: (tool, arguments, timeout) async => tool.endsWith('ffprobe.exe')
            ? ProcessResult(0, 0, utf8.encode(_probeJson()), '')
            : ProcessResult(0, 0, [], ''),
      );
      expect(await tools.sampleFrames('C:/videos/clip.mp4'), isNull);
    });
  });

  group('delete', () {
    test('removes only its own work directory', () async {
      final tools = make();
      final work = Directory.systemTemp.createTempSync('parallax-video-');
      final file = File('${work.path}/out.mp4')..writeAsBytesSync([0]);
      await tools.delete(file.path);
      expect(work.existsSync(), isFalse);

      final other = Directory.systemTemp.createTempSync('parallax-other-');
      final kept = File('${other.path}/out.mp4')..writeAsBytesSync([0]);
      await tools.delete(kept.path);
      expect(kept.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      other.deleteSync(recursive: true);
    });
  });
}
