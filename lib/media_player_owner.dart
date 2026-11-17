import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart' as audio;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'chat_backend.dart';

/// All injected factories transfer exclusive ownership of their result.
typedef MediaLoader = Future<DownloadedAttachment> Function();
typedef MediaFileFactory = Future<MediaTempFile> Function(DownloadedAttachment);
typedef MediaPlayerFactory =
    MediaPlaybackController Function(MediaTempFile file, String mimeType);
typedef MediaImageDecoder = Future<ui.Image> Function(Uint8List bytes);

abstract interface class MediaTempFile {
  String get path;
  Future<void> delete();
}

@immutable
class MediaPlaybackValue {
  const MediaPlaybackValue({
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.playing = false,
    this.aspectRatio,
    this.error,
  });
  final Duration duration;
  final Duration position;
  final bool playing;
  final double? aspectRatio;
  final String? error;
}

/// [disposePlayer] must finish releasing the native reader before completing.
/// Initialization/commands are joined by the owner before this is called.
abstract class MediaPlaybackController extends ChangeNotifier {
  MediaPlaybackValue get value;
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Playback rate (1.0 = normal). Players without rate control ignore it.
  Future<void> setSpeed(double speed) async {}
  Widget buildVideo(BuildContext context);
  Future<void> disposePlayer();
}

class MediaViewerClosed implements Exception {
  const MediaViewerClosed();
}

/// One attempt, one owner. Closing invalidates synchronously and returns the
/// exact same join future to every caller. Never timeout cleanup: a native
/// reader that has not stopped must not race deletion of its plaintext source.
class MediaPlayerOwner {
  MediaPlayerOwner({
    required this.loader,
    this.fileFactory = createMediaTempFile,
    this.playerFactory = createNativeMediaPlayer,
    this.imageDecoder = decodeMediaImage,
    this.initializationTimeout = const Duration(seconds: 20),
  });

  final MediaLoader loader;
  final MediaFileFactory fileFactory;
  final MediaPlayerFactory playerFactory;
  final MediaImageDecoder imageDecoder;
  final Duration initializationTimeout;
  Future<void>? _work;
  Future<void>? _initializing;
  Future<void>? _closing;
  Future<void> _commands = Future.value();
  bool _closed = false;
  bool _ready = false;
  MediaTempFile? _file;
  MediaPlaybackController? _player;
  ui.Image? _image;
  Uint8List? _animatedSource;
  String? _name;
  String? _mimeType;

  bool get closed => _closed;
  MediaPlaybackController? get player => _ready && !_closed ? _player : null;
  ui.Image? get image => _ready && !_closed ? _image : null;

  /// Encoded bytes of a possibly animated GIF/WebP (bounded), for frame-by-
  /// frame playback by the viewer. [image] remains the first-frame poster.
  Uint8List? get animatedSource =>
      _ready && !_closed && _image != null ? _animatedSource : null;
  String? get name => _name;
  String? get mimeType => _mimeType;

  Future<void> load() => _work ??= _load();

  void _checkOpen() {
    if (_closed) throw const MediaViewerClosed();
  }

  Future<void> _load() async {
    _checkOpen();
    final attachment = await loader();
    _checkOpen();
    if (attachment.bytes.isEmpty ||
        attachment.bytes.length > 20 * 1024 * 1024) {
      throw const FormatException('Media exceeds the download limit.');
    }
    _name = attachment.name;
    _mimeType = attachment.mimeType.split(';').first.trim().toLowerCase();
    if (_mimeType!.startsWith('image/')) {
      // No global image cache and no plaintext image file.
      _image = await imageDecoder(attachment.bytes);
      _checkOpen();
      if ((_mimeType == 'image/gif' || _mimeType == 'image/webp') &&
          attachment.bytes.length <= maxAnimatedImageBytes) {
        _animatedSource = attachment.bytes;
      }
    } else if (_mimeType!.startsWith('audio/') ||
        _mimeType!.startsWith('video/')) {
      _file = await fileFactory(attachment);
      _checkOpen();
      _player = playerFactory(_file!, _mimeType!);
      _initializing = Future<void>.sync(_player!.initialize);
      // Keep the ORIGINAL future: timeout stops waiting in the UI, not native
      // work. close() still joins late initialization (including late errors).
      await _initializing!.timeout(initializationTimeout);
      _checkOpen();
    } else {
      throw const FormatException('Unsupported media type.');
    }
    _ready = true;
  }

  Future<void> _command(
    Future<void> Function(MediaPlaybackController) command,
  ) {
    final next = _commands.then((_) async {
      if (_closed || !_ready || _player == null) return;
      await command(_player!);
    });
    // The caller receives failures; the queue remains usable after a failure.
    _commands = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> play() => _command((p) => p.play());
  Future<void> pause() => _command((p) => p.pause());
  Future<void> seek(Duration position) => _command((p) => p.seek(position));
  Future<void> setSpeed(double speed) => _command((p) => p.setSpeed(speed));

  Future<void> close() {
    _closed = true;
    return _closing ??= _cleanup();
  }

  Future<void> _join(Future<void>? work) async {
    try {
      await work;
    } catch (_) {
      // The load/command caller owns the error; release still has to run.
    }
  }

  Future<void> _cleanup() async {
    await _join(_work);
    await _join(_initializing);
    await _commands;
    final image = _image;
    _image = null;
    _animatedSource = null;
    image?.dispose();
    // If disposal fails, deliberately do NOT unlink a possibly live source.
    await _player?.disposePlayer();
    _player = null;
    await _file?.delete();
    _file = null;
  }
}

/// Animated GIF/WebP originals above this size show their first frame only.
const maxAnimatedImageBytes = 8 * 1024 * 1024;

/// Validate header dimensions BEFORE requesting any decoded frame. Reject
/// decompression bombs, then bound the decoded first frame to 4 Mi pixels.
({int width, int height}) mediaImageDecodeSize(int width, int height) {
  if (width <= 0 ||
      height <= 0 ||
      width > 16384 ||
      height > 16384 ||
      width * height > 16 * 1024 * 1024) {
    throw const FormatException('Image dimensions exceed the safe limit.');
  }
  final scale = math.min(
    1.0,
    math.min(
      4096 / math.max(width, height),
      math.sqrt((4 * 1024 * 1024) / (width * height)),
    ),
  );
  return (
    width: math.max(1, (width * scale).floor()),
    height: math.max(1, (height * scale).floor()),
  );
}

Future<ui.Image> decodeMediaImage(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = mediaImageDecodeSize(descriptor.width, descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: size.width,
      targetHeight: size.height,
    );
    // The poster is the first frame. Animation (bounded, frame by frame) is
    // owned by the viewer's AnimatedMediaImage, never by a global cache.
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _LocalMediaFile implements MediaTempFile {
  _LocalMediaFile(this.directory, this.file);
  final Directory directory;
  final File file;
  Future<void>? _deleting;
  @override
  String get path => file.path;
  @override
  Future<void> delete() =>
      _deleting ??= directory.delete(recursive: true).then((_) {});
}

/// A unique app-private directory per attempt. Never trust the sender's file
/// name as a path; retain only a MIME-derived suffix for native sniffing.
Future<MediaTempFile> createMediaTempFile(
  DownloadedAttachment attachment, {
  Directory? temporaryDirectory,
}) async {
  final root = temporaryDirectory ?? await getTemporaryDirectory();
  final directory = await root.createTemp('parallax-media-');
  try {
    final mime = attachment.mimeType.split(';').first.trim().toLowerCase();
    final extension = switch (mime) {
      'audio/ogg' || 'video/ogg' => 'ogg',
      'audio/mpeg' => 'mp3',
      'audio/mp4' || 'audio/x-m4a' => 'm4a',
      'audio/aac' => 'aac',
      'audio/wav' || 'audio/x-wav' => 'wav',
      'audio/flac' => 'flac',
      'video/mp4' => 'mp4',
      'video/quicktime' => 'mov',
      'video/webm' || 'audio/webm' => 'webm',
      _ => 'bin',
    };
    final file = File('${directory.path}/media.$extension');
    await file.writeAsBytes(attachment.bytes, flush: true);
    return _LocalMediaFile(directory, file);
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}

MediaPlaybackController createNativeMediaPlayer(
  MediaTempFile file,
  String mime,
) => mime.startsWith('video/')
    ? _NativeVideoPlayer(file.path)
    : _NativeAudioPlayer(file.path, mime);

/// Display aspect ratio (`width / height`) of a video from the size that
/// `video_player` reports.
///
/// That size is already the size the video is shown at: for a phone-camera
/// portrait recording (stored 1920x1080 with a 90 degree rotation flag) the
/// Android plugin reports 1080x1920 *and* `rotationCorrection: 90`. The
/// correction only tells the `VideoPlayer` widget to turn the texture; it
/// must not be applied to the size as well, or the video plays squashed in a
/// landscape box. `integration_test/video_rotation_test.dart` checks this on
/// a device.
double? videoDisplayAspectRatio(Size size) {
  if (size.width <= 0 || size.height <= 0) return null;
  final ratio = size.width / size.height;
  return ratio.isFinite && ratio > 0 ? ratio : null;
}

class _NativeVideoPlayer extends MediaPlaybackController {
  _NativeVideoPlayer(String path)
    : _controller = VideoPlayerController.file(
        File(path),
        // Own lifecycle here; plugin's observer otherwise auto-resumes media.
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
      ) {
    _controller.addListener(notifyListeners);
  }
  final VideoPlayerController _controller;
  double? get _displayAspectRatio {
    final v = _controller.value;
    if (!v.isInitialized) return null;
    return videoDisplayAspectRatio(v.size);
  }

  @override
  MediaPlaybackValue get value => MediaPlaybackValue(
    duration: _controller.value.duration,
    position: _controller.value.position,
    playing: _controller.value.isPlaying,
    aspectRatio: _displayAspectRatio,
    error: _controller.value.errorDescription,
  );
  @override
  Future<void> initialize() => _controller.initialize();
  @override
  Future<void> play() => _controller.play();
  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> seek(Duration position) => _controller.seekTo(position);
  @override
  Future<void> setSpeed(double speed) => _controller.setPlaybackSpeed(speed);
  @override
  Widget buildVideo(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: _displayAspectRatio ?? _controller.value.aspectRatio,
      child: VideoPlayer(_controller),
    ),
  );
  @override
  Future<void> disposePlayer() async {
    _controller.removeListener(notifyListeners);
    await _controller.dispose();
    super.dispose();
  }
}

class _NativeAudioPlayer extends MediaPlaybackController {
  _NativeAudioPlayer(this.path, this.mime);
  final String path;
  final String mime;
  final audio.AudioPlayer _controller = audio.AudioPlayer();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  String? _error;
  @override
  MediaPlaybackValue get value => MediaPlaybackValue(
    duration: _duration,
    position: _position,
    playing: _playing,
    error: _error,
  );
  void _failed(Object error, StackTrace stack) {
    _error = 'Audio playback failed.';
    notifyListeners();
  }

  @override
  Future<void> initialize() async {
    _subscriptions.addAll([
      _controller.onDurationChanged.listen((duration) {
        _duration = duration;
        notifyListeners();
      }, onError: _failed),
      _controller.onPositionChanged.listen((position) {
        _position = position;
        notifyListeners();
      }, onError: _failed),
      _controller.onPlayerStateChanged.listen((state) {
        _playing = state == audio.PlayerState.playing;
        notifyListeners();
      }, onError: _failed),
      _controller.onPlayerComplete.listen((_) {
        _playing = false;
        _position = _duration;
        notifyListeners();
      }, onError: _failed),
    ]);
    await _controller.setReleaseMode(audio.ReleaseMode.stop);
    await _controller.setSourceDeviceFile(path, mimeType: mime);
    _duration = await _controller.getDuration() ?? Duration.zero;
  }

  @override
  Future<void> play() async {
    if (_duration > Duration.zero && _position >= _duration) {
      await _controller.seek(Duration.zero);
    }
    await _controller.resume();
  }

  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> seek(Duration position) => _controller.seek(position);
  @override
  Future<void> setSpeed(double speed) => _controller.setPlaybackRate(speed);
  @override
  Widget buildVideo(BuildContext context) => const SizedBox.shrink();
  @override
  Future<void> disposePlayer() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _controller.dispose();
    super.dispose();
  }
}
