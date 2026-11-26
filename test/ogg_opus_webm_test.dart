import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/media_player_owner.dart';
import 'package:parallax/ogg_opus_webm.dart';

import '../integration_test/audio_playback_fixture.dart';
import 'media_test_support.dart';

/// Minimal EBML reader for checking the muxer's output.
class _El {
  _El(this.id, this.start, this.dataStart, this.size);
  final int id;
  final int start;
  final int dataStart;
  final int size;
  int get end => dataStart + size;
}

int _vintLength(int first) {
  for (var i = 0; i < 8; i++) {
    if (first & (0x80 >> i) != 0) return i + 1;
  }
  throw StateError('bad vint');
}

List<_El> _children(Uint8List b, int from, int to) {
  final out = <_El>[];
  var p = from;
  while (p < to) {
    final start = p;
    final idLength = _vintLength(b[p]);
    var id = 0;
    for (var i = 0; i < idLength; i++) {
      id = (id << 8) | b[p + i];
    }
    p += idLength;
    final sizeLength = _vintLength(b[p]);
    var size = b[p] & (0xFF >> sizeLength);
    for (var i = 1; i < sizeLength; i++) {
      size = (size << 8) | b[p + i];
    }
    p += sizeLength;
    out.add(_El(id, start, p, size));
    p += size;
  }
  expect(p, to, reason: 'children end exactly at their parent');
  return out;
}

int _uint(Uint8List b, _El e) {
  var v = 0;
  for (var i = e.dataStart; i < e.end; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

/// Number of audio packets (after OpusHead and OpusTags) in an Ogg file.
int _oggAudioPackets(Uint8List b) {
  var packets = 0;
  var p = 0;
  while (p + 27 <= b.length) {
    final segments = b[p + 26];
    var data = p + 27 + segments;
    for (var i = 0; i < segments; i++) {
      final length = b[p + 27 + i];
      if (length < 255) packets++;
      data += length;
    }
    p = data;
  }
  return packets - 2;
}

void main() {
  test('recognises Ogg Opus and nothing else', () {
    expect(isOggOpus(opusVoiceNote), isTrue);
    expect(isOggOpus(aacVoiceNote), isFalse);
    expect(isOggOpus(mp3AudioFile), isFalse);
    expect(isOggOpus(Uint8List(0)), isFalse);
  });

  test('rewraps Ogg Opus as WebM with every packet, cues and duration', () {
    final webm = oggOpusToWebm(opusVoiceNote)!;
    final top = _children(webm, 0, webm.length);
    expect(top.map((e) => e.id), [0x1A45DFA3, 0x18538067]);
    final doc = _children(webm, top[0].dataStart, top[0].end);
    final docType = doc.firstWhere((e) => e.id == 0x4282);
    expect(
      String.fromCharCodes(webm.sublist(docType.dataStart, docType.end)),
      'webm',
    );

    final segment = top[1];
    final parts = _children(webm, segment.dataStart, segment.end);
    expect(parts.take(3).map((e) => e.id), [
      0x1549A966, // Info
      0x1654AE6B, // Tracks
      0x1C53BB6B, // Cues
    ]);

    // Duration (ms) is the stream length less the encoder's pre-skip.
    final info = _children(webm, parts[0].dataStart, parts[0].end);
    final duration = info.firstWhere((e) => e.id == 0x4489);
    final ms = ByteData.sublistView(webm, duration.dataStart).getFloat64(0);
    expect(ms, closeTo(2000, 30));

    // One Opus track carrying OpusHead as its codec private data.
    final entry = _children(webm, parts[1].dataStart, parts[1].end).single;
    final fields = _children(webm, entry.dataStart, entry.end);
    final codec = fields.firstWhere((e) => e.id == 0x86);
    expect(
      String.fromCharCodes(webm.sublist(codec.dataStart, codec.end)),
      'A_OPUS',
    );
    final private = fields.firstWhere((e) => e.id == 0x63A2);
    expect(
      String.fromCharCodes(
        webm.sublist(private.dataStart, private.dataStart + 8),
      ),
      'OpusHead',
    );

    // Every Opus packet became one SimpleBlock, in clusters the cues find.
    final clusters = parts.where((e) => e.id == 0x1F43B675).toList();
    expect(clusters, isNotEmpty);
    var blocks = 0;
    for (final cluster in clusters) {
      blocks += _children(
        webm,
        cluster.dataStart,
        cluster.end,
      ).where((e) => e.id == 0xA3).length;
    }
    expect(blocks, _oggAudioPackets(opusVoiceNote));
    final cuePoints = _children(webm, parts[2].dataStart, parts[2].end);
    expect(cuePoints, hasLength(clusters.length));
    for (var i = 0; i < cuePoints.length; i++) {
      final positions = _children(
        webm,
        cuePoints[i].dataStart,
        cuePoints[i].end,
      ).firstWhere((e) => e.id == 0xB7);
      final position = _children(
        webm,
        positions.dataStart,
        positions.end,
      ).firstWhere((e) => e.id == 0xF1);
      expect(
        segment.dataStart + _uint(webm, position),
        clusters[i].start,
        reason: 'cue $i points at its cluster',
      );
    }
  });

  test('refuses anything that is not a whole Ogg Opus file', () {
    expect(oggOpusToWebm(aacVoiceNote), isNull);
    expect(oggOpusToWebm(Uint8List.fromList('OggS'.codeUnits)), isNull);
    expect(oggOpusToWebm(Uint8List.sublistView(opusVoiceNote, 0, 100)), isNull);
  });

  group('the player gets a format its platform opens', () {
    final voice = DownloadedAttachment(
      name: 'Voice message.ogg',
      mimeType: 'audio/ogg; codecs=opus',
      bytes: opusVoiceNote,
    );

    test('Windows plays Ogg Opus voice notes as WebM', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final playable = playableOnThisPlatform(voice);
        expect(playable.mimeType, 'audio/webm');
        expect(playable.name, 'Voice message.webm');
        expect(playable.bytes.sublist(0, 4), [0x1A, 0x45, 0xDF, 0xA3]);
        // Other audio is left alone.
        final m4a = DownloadedAttachment(
          name: 'voice.m4a',
          mimeType: 'audio/mp4',
          bytes: aacVoiceNote,
        );
        expect(identical(playableOnThisPlatform(m4a), m4a), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('other platforms keep Ogg', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(identical(playableOnThisPlatform(voice), voice), isTrue);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });

    test('the inline player owner hands Windows the WebM copy', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final log = <String>[];
      DownloadedAttachment? written;
      String? playerMime;
      final owner = MediaPlayerOwner(
        loader: () async => voice,
        fileFactory: (attachment) async {
          written = attachment;
          return FakeTempFile(log);
        },
        playerFactory: (file, mime) {
          playerMime = mime;
          return FakePlayer(log);
        },
      );
      try {
        await owner.load();
        expect(written?.mimeType, 'audio/webm');
        expect(playerMime, 'audio/webm');
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await owner.close();
      }
    });
  });
}
