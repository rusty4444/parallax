import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_content.dart';
import 'package:parallax/features/media/voice_waveform.dart';

void main() {
  group('MediaInfo', () {
    test('caption only when a distinct filename exists', () {
      final captioned = MediaInfo.fromContent({
        'body': 'Sunset at the beach',
        'filename': 'IMG_1234.jpg',
      });
      expect(captioned.caption, 'Sunset at the beach');
      expect(captioned.name, 'IMG_1234.jpg');

      final same = MediaInfo.fromContent({
        'body': 'IMG_1234.jpg',
        'filename': 'IMG_1234.jpg',
      });
      expect(same.caption, isNull);

      final legacy = MediaInfo.fromContent({'body': 'IMG_1234.jpg'});
      expect(legacy.caption, isNull);
      expect(legacy.name, 'IMG_1234.jpg');
    });

    test('reads bounded info and rejects hostile values', () {
      final info = MediaInfo.fromContent({
        'body': 'clip.mp4',
        'info': {
          'mimetype': 'Video/MP4; codecs="avc1"',
          'size': 2048,
          'w': 1920,
          'h': 1080,
          'duration': 65000,
          'thumbnail_url': 'mxc://example.org/thumb',
        },
      });
      expect(info.mimeType, 'video/mp4');
      expect(info.size, 2048);
      expect(info.aspectRatio, closeTo(1920 / 1080, 0.001));
      expect(info.duration, const Duration(seconds: 65));
      expect(info.hasThumbnail, isTrue);

      final hostile = MediaInfo.fromContent({
        'body': 'x\u0000y',
        'info': {
          'mimetype': '../../etc',
          'size': -5,
          'w': double.infinity,
          'h': 0,
          'duration': 1e20,
        },
      });
      expect(hostile.mimeType, isNull);
      expect(hostile.size, isNull);
      expect(hostile.width, isNull);
      expect(hostile.height, isNull);
      expect(hostile.duration, isNull);
      expect(hostile.name, 'x y');
    });

    test('voice duration and waveform come from MSC1767 audio', () {
      final info = MediaInfo.fromContent({
        'body': 'Voice message',
        'org.matrix.msc1767.audio': {
          'duration': 4200,
          'waveform': [0, 512, 1024, 2048, -1],
        },
      });
      expect(info.duration, const Duration(milliseconds: 4200));
      expect(info.waveform, [0.0, 0.5, 1.0, 1.0, 0.0]);
    });

    test('encrypted files read their MIME type from the file object', () {
      final info = MediaInfo.fromContent({
        'body': 'report.pdf',
        'file': {'mimetype': 'application/pdf'},
      });
      expect(info.mimeType, 'application/pdf');
    });

    test('animated candidates are GIF and WebP only', () {
      bool animated(String mime) => MediaInfo.fromContent({
        'info': {'mimetype': mime},
      }).mayBeAnimated;
      expect(animated('image/gif'), isTrue);
      expect(animated('image/webp'), isTrue);
      expect(animated('image/png'), isFalse);
    });
  });

  test('malformed or oversized waveforms are ignored', () {
    expect(parseWaveform(null), isEmpty);
    expect(parseWaveform(['a', 1]), isEmpty);
    expect(parseWaveform(List.filled(5000, 1)), isEmpty);
    expect(parseWaveform([double.nan]), isEmpty);
  });

  test('resampling averages buckets to the requested bar count', () {
    expect(resampleWaveform([0, 1, 0, 1], 2), [0.5, 0.5]);
    expect(resampleWaveform([1], 3), [1, 1, 1]);
    expect(resampleWaveform(const [], 2), [0, 0]);
  });

  test('formats durations, sizes and type labels', () {
    expect(formatMediaDuration(const Duration(seconds: 5)), '0:05');
    expect(formatMediaDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
    expect(
      formatMediaDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(formatFileSize(512), '512 B');
    expect(formatFileSize(1536), '1.5 KB');
    expect(formatFileSize(5 * 1024 * 1024), '5 MB');
    expect(fileTypeLabel('report.final.pdf', null), 'PDF');
    expect(fileTypeLabel('archive', 'application/zip'), 'ZIP');
    expect(fileTypeLabel('weird.???', null), 'FILE');
    expect(
      fileTypeIcon('a.pdf', 'application/pdf'),
      Icons.picture_as_pdf_outlined,
    );
    expect(fileTypeIcon('a.zip', null), Icons.folder_zip_outlined);
    expect(fileTypeIcon('a.bin', 'audio/ogg'), Icons.audiotrack_rounded);
  });

  test('media kinds split between the gallery tabs', () {
    expect(isVisualMediaKind(EntryKind.image), isTrue);
    expect(isVisualMediaKind(EntryKind.video), isTrue);
    expect(isFileMediaKind(EntryKind.voice), isTrue);
    expect(isFileMediaKind(EntryKind.file), isTrue);
    expect(isMediaKind(EntryKind.sticker), isTrue);
    expect(isMediaKind(EntryKind.text), isFalse);
  });

  test('preview sizes clamp hostile aspect ratios', () {
    final wide = mediaPreviewSize(
      MediaInfo.fromContent({
        'info': {'w': 10000, 'h': 1},
      }),
    );
    expect(wide.height, greaterThanOrEqualTo(110));
    final tall = mediaPreviewSize(
      MediaInfo.fromContent({
        'info': {'w': 1, 'h': 10000},
      }),
    );
    expect(tall.height, 320);
    expect(tall.width, greaterThanOrEqualTo(120));
  });

  group('voice waveform', () {
    test('levels become at most 100 integers in 0..1024', () {
      final levels = [for (var i = 0; i < 1000; i++) -60.0 + (i % 61)];
      final waveform = waveformFromLevels(levels);
      expect(waveform, hasLength(maxWaveformPoints));
      expect(waveform.every((v) => v >= 0 && v <= 1024), isTrue);
      expect(waveformFromLevels([-160, 0, double.nan]), [0, 1024]);
      expect(waveformFromLevels(const []), isEmpty);
      expect(waveformFromLevels([-30]), [512]);
    });

    test('registry links a recorded clip to its waveform by content', () {
      final registry = VoiceMessageRegistry.instance..clear();
      final clip = Uint8List.fromList([1, 2, 3]);
      registry.register(
        clip,
        const VoiceMetadata(durationMs: 900, waveform: [1, 2]),
      );
      final copy = Uint8List.fromList([1, 2, 3]);
      expect(registry.lookup(copy)?.waveform, [1, 2]);
      expect(registry.lookup(Uint8List.fromList([9])), isNull);
      for (var i = 0; i < 10; i++) {
        registry.register(
          Uint8List.fromList([i, 100]),
          const VoiceMetadata(durationMs: 1, waveform: []),
        );
      }
      expect(registry.lookup(copy), isNull, reason: 'bounded LRU');
      registry.clear();
    });

    test('recorder file names are recognised', () {
      expect(
        VoiceMessageRegistry.isRecorderName('voice-1731400000000.m4a'),
        isTrue,
      );
      expect(VoiceMessageRegistry.isRecorderName('voice-notes.m4a'), isFalse);
      expect(VoiceMessageRegistry.isRecorderName('song.mp3'), isFalse);
    });
  });
}
