import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'messaging_features.dart';

const maxComposerMediaBytes = 20 * 1024 * 1024;

/// Checks both advertised size and the actual stream before allocating a result.
/// Provider metadata is only a hint: a changing/unknown-length file is bounded too.
Future<Uint8List> readComposerMedia(
  Stream<List<int>> stream, {
  int? length,
}) async {
  if (length != null && length > maxComposerMediaBytes) {
    throw const FormatException('Attachments must be 20 MB or smaller.');
  }
  final builder = BytesBuilder(copy: false);
  var count = 0;
  await for (final chunk in stream) {
    count += chunk.length;
    if (count > maxComposerMediaBytes) {
      throw const FormatException('Attachments must be 20 MB or smaller.');
    }
    builder.add(chunk);
  }
  if (count == 0) {
    throw const FormatException('The selected attachment is empty.');
  }
  return builder.takeBytes();
}

/// The composer owns this instance (including injected instances) until dispose.
/// Operations must finish only after their native work has joined. In particular,
/// discard/dispose must not delete files still used by start, stop or playback.
/// stop() transfers durable in-memory bytes, independent of all recorder files;
/// discard/dispose must not invalidate previously returned selections.
abstract interface class VoiceRecorder {
  Stream<bool> get playbackChanges;
  Future<bool> requestPermission();
  Future<void> start();
  Future<MediaSelection> stop();
  Future<void> discard();
  Future<void> playPreview(MediaSelection media);
  Future<void> stopPreview();
  Future<void> dispose();
}

/// Lazy, serial native resource owner. No plugin or permission is touched until
/// the user records. All temporary files are private per-session directories.
class NativeVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerSubscription;
  final _playback = StreamController<bool>.broadcast();
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  Directory? _directory;
  String? _recordingPath;
  bool _recording = false;
  bool _closed = false;
  final _duration = Stopwatch();

  @override
  Stream<bool> get playbackChanges => _playback.stream;

  Future<T> _join<T>(Future<T> Function() action) {
    if (_closed) {
      return Future<T>.error(StateError('Voice recorder is closed.'));
    }
    final task = _tail.then((_) => action());
    // A failed operation must not poison the teardown queue.
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  @override
  Future<bool> requestPermission() => _join(() {
    _recorder ??= AudioRecorder();
    return _recorder!.hasPermission();
  });

  Future<Directory> _temporaryDirectory() async {
    return _directory ??= await (await getTemporaryDirectory()).createTemp(
      'matrixpress-voice-',
    );
  }

  @override
  Future<void> start() => _join(() async {
    await _discardNow();
    _recorder ??= AudioRecorder();
    final directory = await _temporaryDirectory();
    _recordingPath = '${directory.path}/voice.m4a';
    // Set before awaiting acquisition, so partial starts are cleaned on error.
    _recording = true;
    try {
      await _recorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: _recordingPath!,
      );
      _duration
        ..reset()
        ..start();
    } catch (_) {
      await _discardNow();
      rethrow;
    }
  });

  @override
  Future<MediaSelection> stop() => _join(() async {
    if (!_recording) throw StateError('There is no active voice recording.');
    try {
      final path = await _recorder!.stop();
      _recording = false;
      _duration.stop();
      if (path == null) {
        throw StateError('The microphone produced no recording.');
      }
      final file = File(path);
      final bytes = await readComposerMedia(
        file.openRead(),
        length: await file.length(),
      );
      return MediaSelection(
        bytes: bytes,
        name: 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
        mimeType: 'audio/mp4',
        durationMs: _duration.elapsedMilliseconds,
      );
    } finally {
      // Join stop and the entire bounded read before removing the capture file.
      // A failed stop is cancelled before any filesystem cleanup.
      await _discardNow();
    }
  });

  Future<void> _releasePlayer() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
    } catch (_) {
      // Disposal is the release barrier even if stopping playback failed.
    }
    try {
      await _playerSubscription?.cancel();
      _playerSubscription = null;
    } finally {
      // stop() may leave a native reader holding its source. Always dispose it
      // before unlinking the preview, and retain the file if release fails.
      await player.dispose();
      _player = null;
    }
  }

  Future<void> _releaseRecorder({required bool disposing}) async {
    if (_recording) {
      try {
        // record_platform_interface 2.1.0's cancel() does not await its native
        // method call. stop() does: use that join barrier before deleting files.
        await _recorder?.stop();
      } catch (_) {
        // Do not delete a file underneath a possibly still-writing recorder.
        await _recorder?.dispose();
        _recorder = null;
      }
      _recording = false;
    }
    if (disposing) {
      await _recorder?.dispose();
      _recorder = null;
    }
  }

  Future<void> _discardNow({bool disposing = false}) async {
    _duration.stop();
    // Release both independent handles even if one fails. A failed native
    // release retains the directory rather than deleting a possibly live file.
    await Future.wait([
      _releasePlayer(),
      _releaseRecorder(disposing: disposing),
    ]);
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _directory = null;
    _recordingPath = null;
    if (!_playback.isClosed) _playback.add(false);
  }

  @override
  Future<void> discard() => _join(_discardNow);

  @override
  Future<void> playPreview(MediaSelection media) => _join(() async {
    if (_recording) {
      throw StateError('Stop recording before playing a preview.');
    }
    if (media.bytes.isEmpty || media.bytes.length > maxComposerMediaBytes) {
      throw const FormatException(
        'Voice previews must be between 1 byte and 20 MB.',
      );
    }
    await _player?.stop();
    final directory = await _temporaryDirectory();
    final file = File('${directory.path}/preview.m4a');
    await file.writeAsBytes(media.bytes, flush: true);
    if (_player == null) {
      _player = AudioPlayer();
      _playerSubscription = _player!.onPlayerStateChanged.listen(
        (state) {
          if (!_playback.isClosed) _playback.add(state == PlayerState.playing);
        },
        onError: (Object error, StackTrace stack) {
          if (!_playback.isClosed) _playback.addError(error, stack);
        },
      );
    }
    try {
      await _player!.play(
        DeviceFileSource(file.path, mimeType: media.mimeType),
      );
    } catch (_) {
      await _discardNow();
      rethrow;
    }
  });

  @override
  Future<void> stopPreview() => _join(() async {
    await _player?.stop();
    if (!_playback.isClosed) _playback.add(false);
  });

  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    // Invalidate synchronously, then join every previously accepted operation.
    _closed = true;
    return _disposal = _tail.then((_) async {
      try {
        await _discardNow(disposing: true);
      } finally {
        await _playback.close();
      }
    });
  }
}
