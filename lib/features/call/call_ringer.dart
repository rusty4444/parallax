import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Plays the in-app ring while an incoming call is on screen.
abstract interface class CallRinger {
  Future<void> start();
  Future<void> stop();
}

/// Rings with a generated tone in the Australian ring cadence (0.4 s on,
/// 0.2 s off, 0.4 s on, 2 s off) plus a vibration per cycle. Uses the
/// ringtone audio stream, so the ringer volume applies.
class AudioCallRinger implements CallRinger {
  AudioCallRinger();

  static const _cycle = Duration(seconds: 3);
  static final Uint8List _tone = ringToneWav();

  AudioPlayer? _player;
  Timer? _haptics;
  bool _ringing = false;

  @override
  Future<void> start() async {
    if (_ringing) return;
    _ringing = true;
    _haptics = Timer.periodic(_cycle, (_) => _vibrate());
    _vibrate();
    try {
      final player = AudioPlayer();
      _player = player;
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.notificationRingtone,
            audioFocus: AndroidAudioFocus.gainTransient,
          ),
        ),
      );
      await player.setReleaseMode(ReleaseMode.loop);
      if (!_ringing) return;
      await player.play(BytesSource(_tone, mimeType: 'audio/wav'));
    } catch (_) {
      // Audio is best effort; the overlay and vibration still alert.
    }
  }

  void _vibrate() {
    unawaited(HapticFeedback.vibrate().catchError((Object _) {}));
  }

  @override
  Future<void> stop() async {
    _ringing = false;
    _haptics?.cancel();
    _haptics = null;
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (_) {}
  }
}

/// 8 kHz mono 16-bit PCM WAV: two 400/450 Hz bursts per three-second cycle.
Uint8List ringToneWav() {
  const rate = 8000;
  const seconds = 3;
  final samples = ByteData(rate * seconds * 2);
  void burst(double start, double length) {
    final from = (start * rate).round();
    final count = (length * rate).round();
    const fade = rate ~/ 100;
    for (var i = 0; i < count; i++) {
      final t = i / rate;
      final envelope = min(1.0, min(i, count - i) / fade);
      final value =
          0.32 * envelope * (sin(2 * pi * 400 * t) + sin(2 * pi * 450 * t));
      samples.setInt16(
        (from + i) * 2,
        (value * 32767 / 2).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
  }

  burst(0, 0.4);
  burst(0.6, 0.4);
  final data = samples.buffer.asUint8List();
  final header = ByteData(44);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + data.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, data.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
}
