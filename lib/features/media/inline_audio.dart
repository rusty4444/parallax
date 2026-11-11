import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../media_player_owner.dart';

/// Element X voice playback speeds, in toggle order.
const voicePlaybackSpeeds = [1.0, 1.5, 2.0, 0.5];

/// Last chosen voice speed, shared by every voice message (as in Element X).
final voicePlaybackSpeed = ValueNotifier<double>(1.0);

String formatSpeed(double speed) =>
    '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 1)}×';

enum InlineAudioStatus { idle, loading, ready, failed }

/// Factories for inline players. Tests replace them to avoid platform
/// channels and filesystem work in a fake-async zone.
@visibleForTesting
MediaFileFactory debugInlineFileFactory = createMediaTempFile;
@visibleForTesting
MediaPlayerFactory debugInlinePlayerFactory = createNativeMediaPlayer;

/// Downloads an audio attachment only when the user first presses play, then
/// owns one [MediaPlayerOwner] until [close]. Only one inline player plays at
/// a time; the app going to the background pauses it and never auto-resumes.
class InlineAudioController extends ChangeNotifier {
  InlineAudioController({
    required this.loader,
    MediaFileFactory? fileFactory,
    MediaPlayerFactory? playerFactory,
    this.knownDuration,
  }) : _fileFactory = fileFactory ?? debugInlineFileFactory,
       _playerFactory = playerFactory ?? debugInlinePlayerFactory;

  final MediaLoader loader;
  final MediaFileFactory _fileFactory;
  final MediaPlayerFactory _playerFactory;

  /// Duration declared by the event, shown before the file is downloaded.
  final Duration? knownDuration;

  MediaPlayerOwner? _owner;
  MediaPlaybackController? _player;
  Future<void>? _loading;
  InlineAudioStatus _status = InlineAudioStatus.idle;
  bool _closed = false;
  double _speed = 1;
  int _generation = 0;

  InlineAudioStatus get status => _status;
  bool get closed => _closed;
  bool get playing => _player?.value.playing ?? false;
  double get speed => _speed;

  Duration get duration {
    final value = _player?.value.duration ?? Duration.zero;
    return value > Duration.zero ? value : (knownDuration ?? Duration.zero);
  }

  Duration get position => _player?.value.position ?? Duration.zero;

  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  void _changed() {
    if (_closed) return;
    if (_player?.value.error != null) {
      _fail();
      return;
    }
    if (playing) InlinePlaybackCoordinator.instance.activate(this);
    notifyListeners();
  }

  void _fail() {
    _status = InlineAudioStatus.failed;
    _release();
    if (!_closed) notifyListeners();
  }

  Future<void> _ensureLoaded() {
    if (_owner != null && _status == InlineAudioStatus.ready) {
      return Future.value();
    }
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _status = InlineAudioStatus.loading;
    notifyListeners();
    final owner = MediaPlayerOwner(
      loader: loader,
      fileFactory: _fileFactory,
      playerFactory: _playerFactory,
    );
    _owner = owner;
    try {
      await owner.load();
    } catch (_) {
      if (identical(_owner, owner)) _owner = null;
      _observe(owner.close());
      if (!_closed && generation == _generation) {
        _status = InlineAudioStatus.failed;
        notifyListeners();
      }
      rethrow;
    }
    if (_closed || generation != _generation || !identical(_owner, owner)) {
      _observe(owner.close());
      throw const MediaViewerClosed();
    }
    _player = owner.player;
    _player?.addListener(_changed);
    _status = InlineAudioStatus.ready;
    if (_speed != 1) await owner.setSpeed(_speed);
    notifyListeners();
  }

  /// Play or pause. The first play downloads and prepares the attachment.
  Future<void> toggle() async {
    if (_closed) return;
    if (playing) return pause();
    try {
      await _ensureLoaded();
      final owner = _owner;
      if (_closed || owner == null) return;
      InlinePlaybackCoordinator.instance.activate(this);
      final value = _player?.value;
      if (value != null &&
          value.duration > Duration.zero &&
          value.position >= value.duration) {
        await owner.seek(Duration.zero);
      }
      await owner.play();
    } on MediaViewerClosed {
      return;
    } catch (_) {
      if (!_closed) _fail();
    }
  }

  Future<void> pause() async {
    final owner = _owner;
    if (owner == null || _closed) return;
    try {
      await owner.pause();
    } catch (_) {
      if (!_closed) _fail();
    }
  }

  Future<void> seekFraction(double fraction) async {
    final owner = _owner;
    final total = duration;
    if (owner == null || _closed || total <= Duration.zero) return;
    try {
      await owner.seek(total * fraction.clamp(0.0, 1.0));
    } catch (_) {
      if (!_closed) _fail();
    }
  }

  Future<void> setSpeed(double speed) async {
    if (_closed || !speed.isFinite || speed <= 0) return;
    _speed = speed;
    notifyListeners();
    final owner = _owner;
    if (owner == null || _status != InlineAudioStatus.ready) return;
    try {
      await owner.setSpeed(speed);
    } catch (_) {
      // Speed is cosmetic; playback continues at the previous rate.
    }
  }

  void _release() {
    _generation++;
    _player?.removeListener(_changed);
    _player = null;
    final owner = _owner;
    _owner = null;
    InlinePlaybackCoordinator.instance.release(this);
    if (owner != null) _observe(owner.close());
  }

  Future<void>? _closing;

  void _observe(Future<void> cleanup) {
    unawaited(
      cleanup.catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError('Inline media cleanup failed.'),
            stack: stack,
            library: 'media module',
          ),
        );
      }),
    );
  }

  /// Invalidates synchronously; completes after native disposal and temp-file
  /// deletion have joined. Idempotent.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _generation++;
    _player?.removeListener(_changed);
    _player = null;
    final owner = _owner;
    _owner = null;
    InlinePlaybackCoordinator.instance.release(this);
    return _closing = owner?.close() ?? Future<void>.value();
  }

  @override
  void dispose() {
    _observe(close());
    super.dispose();
  }
}

/// Ensures a single inline player plays at a time and pauses it when the
/// app leaves the foreground.
class InlinePlaybackCoordinator with WidgetsBindingObserver {
  InlinePlaybackCoordinator._();
  static final instance = InlinePlaybackCoordinator._();

  InlineAudioController? _active;
  bool _observing = false;

  void activate(InlineAudioController controller) {
    if (identical(_active, controller)) return;
    final previous = _active;
    _active = controller;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    if (previous != null && !previous.closed) unawaited(previous.pause());
  }

  void release(InlineAudioController controller) {
    if (identical(_active, controller)) _active = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      final active = _active;
      if (active != null && !active.closed) unawaited(active.pause());
    }
  }
}

/// Maps an audio attachment's declared MIME type to one the native player
/// accepts; voice clips are occasionally sent as octet streams.
DownloadedAttachment coerceAudioAttachment(DownloadedAttachment file) {
  final mime = file.mimeType.split(';').first.trim().toLowerCase();
  if (mime.startsWith('audio/') || mime.startsWith('video/')) return file;
  final name = file.name.toLowerCase();
  final guessed = name.endsWith('.ogg') || name.endsWith('.opus')
      ? 'audio/ogg'
      : name.endsWith('.m4a') || name.endsWith('.mp4') || name.endsWith('.aac')
      ? 'audio/mp4'
      : name.endsWith('.wav')
      ? 'audio/wav'
      : 'audio/mpeg';
  return DownloadedAttachment(
    name: file.name,
    mimeType: guessed,
    bytes: file.bytes,
  );
}
