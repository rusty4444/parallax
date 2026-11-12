import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// Maximum points sent in an MSC1767 waveform.
const maxWaveformPoints = 100;

/// Converts recorder levels (dBFS, -160..0) to an MSC1767 waveform: at most
/// [maxWaveformPoints] integers in 0..1024. A -60 dB floor keeps quiet speech
/// visible, as recorder levels are logarithmic.
List<int> waveformFromLevels(
  List<double> levels, {
  int points = maxWaveformPoints,
}) {
  final finite = [
    for (final level in levels)
      if (level.isFinite) ((level.clamp(-60.0, 0.0) + 60) / 60),
  ];
  if (finite.isEmpty || points <= 0) return const [];
  final count = math.min(points, finite.length);
  final result = <int>[];
  for (var i = 0; i < count; i++) {
    final start = (i * finite.length / count).floor();
    final end = math.max(start + 1, ((i + 1) * finite.length / count).floor());
    var sum = 0.0;
    for (var j = start; j < end; j++) {
      sum += finite[j];
    }
    result.add((sum / (end - start) * 1024).round().clamp(0, 1024));
  }
  return List.unmodifiable(result);
}

@immutable
class VoiceMetadata {
  const VoiceMetadata({required this.durationMs, required this.waveform});
  final int durationMs;
  final List<int> waveform;
}

/// Links a just-recorded voice clip to its waveform until it is sent.
///
/// The composer and durable outbox carry [MediaSelection] (bytes, name, MIME,
/// duration) only, so the recorder registers the waveform here under the
/// clip's SHA-256 and the sender looks it up by content. In memory only: a
/// voice clip restored from the outbox after an app restart is still sent as
/// a voice message, without a waveform.
class VoiceMessageRegistry {
  VoiceMessageRegistry._();
  static final instance = VoiceMessageRegistry._();

  static const _capacity = 8;
  final _entries = <String, VoiceMetadata>{};

  static String _key(Uint8List bytes) => sha256.convert(bytes).toString();

  void register(Uint8List bytes, VoiceMetadata metadata) {
    if (bytes.isEmpty) return;
    final key = _key(bytes);
    _entries.remove(key);
    _entries[key] = metadata;
    while (_entries.length > _capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  VoiceMetadata? lookup(Uint8List bytes) {
    if (_entries.isEmpty || bytes.isEmpty) return null;
    return _entries[_key(bytes)];
  }

  /// Whether [name] looks like a clip produced by the in-app recorder.
  static bool isRecorderName(String name) =>
      RegExp(r'^voice-\d{1,20}\.m4a$').hasMatch(name);

  @visibleForTesting
  void clear() => _entries.clear();
}

/// Bars for a voice waveform with a played/unplayed split at [progress].
class WaveformBars extends StatelessWidget {
  const WaveformBars({
    super.key,
    required this.samples,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
    this.height = 32,
    this.onSeek,
  });

  /// Values in 0..1. Empty draws a flat line.
  final List<double> samples;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;
  final double height;

  /// Called with a 0..1 fraction when the user taps or drags the waveform.
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : 160.0;
      void seek(Offset local) =>
          onSeek?.call((local.dx / width).clamp(0.0, 1.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onSeek == null
            ? null
            : (details) => seek(details.localPosition),
        onHorizontalDragUpdate: onSeek == null
            ? null
            : (details) => seek(details.localPosition),
        child: SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: WaveformPainter(
              samples: samples,
              progress: progress,
              playedColor: playedColor,
              unplayedColor: unplayedColor,
            ),
          ),
        ),
      );
    },
  );
}

class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.samples,
    required this.progress,
    required this.playedColor,
    required this.unplayedColor,
  });
  final List<double> samples;
  final double progress;
  final Color playedColor;
  final Color unplayedColor;

  @override
  void paint(Canvas canvas, Size size) {
    const barWidth = 3.0, gap = 2.0;
    final bars = math.max(1, ((size.width + gap) / (barWidth + gap)).floor());
    final values = _resample(bars);
    final played = Paint()..color = playedColor;
    final unplayed = Paint()..color = unplayedColor;
    final split = progress.clamp(0.0, 1.0) * size.width;
    for (var i = 0; i < bars; i++) {
      final left = i * (barWidth + gap);
      final barHeight = math.max(3.0, values[i] * size.height);
      final top = (size.height - barHeight) / 2;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          top,
          left + barWidth,
          top + barHeight,
          const Radius.circular(1.5),
        ),
        left + barWidth / 2 <= split ? played : unplayed,
      );
    }
  }

  List<double> _resample(int bars) {
    if (samples.isEmpty) return List.filled(bars, 0);
    return [
      for (var i = 0; i < bars; i++)
        () {
          final start = (i * samples.length / bars).floor();
          final end = math.max(
            start + 1,
            ((i + 1) * samples.length / bars).floor(),
          );
          var peak = 0.0;
          for (var j = start; j < end && j < samples.length; j++) {
            peak = math.max(peak, samples[j]);
          }
          return peak;
        }(),
    ];
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.progress != progress ||
      !identical(old.samples, samples) ||
      old.playedColor != playedColor ||
      old.unplayedColor != unplayedColor;
}
