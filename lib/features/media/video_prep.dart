import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:path_provider/path_provider.dart';

import '../../messaging_features.dart';
import '../../voice_recorder.dart'
    show maxComposerMediaBytes, readComposerMedia;

/// Size, length and a poster frame of a video file.
@immutable
class VideoInfo {
  const VideoInfo({
    this.width,
    this.height,
    this.durationMs,
    this.thumbnail,
    this.thumbnailWidth,
    this.thumbnailHeight,
  });

  final int? width;
  final int? height;
  final int? durationMs;

  /// JPEG poster frame, at most 800 px on its long side.
  final Uint8List? thumbnail;
  final int? thumbnailWidth;
  final int? thumbnailHeight;

  int? get shortSide =>
      width == null || height == null ? null : math.min(width!, height!);
}

/// Evenly spaced JPEG frames sampled from the start of a video clip.
@immutable
class VideoFrameSample {
  const VideoFrameSample({required this.frames, required this.delayMs});

  final List<Uint8List> frames;
  final int delayMs;
}

/// Native video tools (Android: MediaMetadataRetriever and Media3
/// Transformer, see VideoTools.kt). Replace [instance] in tests.
abstract class VideoTools {
  static VideoTools instance = PlatformVideoTools();

  /// Dimensions (display orientation), duration and a poster frame, or null
  /// when the file can't be read.
  Future<VideoInfo?> probe(String path);

  /// Evenly spaced JPEG frames from the opening [maxDurationMs] of [path] for
  /// an animated notification preview, or null when unreadable.
  Future<VideoFrameSample?> sampleFrames(
    String path, {
    int maxEdge = 360,
    int maxFrames = 12,
    int maxDurationMs = 3000,
  });

  /// Re-encodes to H.264/AAC MP4 with the short side at most [shortSide]
  /// and the video at [videoBitrate] bits/s. Returns the output path, which
  /// the caller must [delete].
  Future<String> compress(
    String path, {
    required int shortSide,
    required int videoBitrate,
  });

  /// Deletes a file this class created.
  Future<void> delete(String path);
}

class PlatformVideoTools implements VideoTools {
  static const _channel = MethodChannel('parallax/video');

  @override
  Future<VideoInfo?> probe(String path) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('probe', {
      'path': path,
    });
    if (raw == null) return null;
    int? number(String key) => (raw[key] as num?)?.toInt();
    final thumbnail = raw['thumbnail'];
    return VideoInfo(
      width: number('width'),
      height: number('height'),
      durationMs: number('durationMs'),
      thumbnail: thumbnail is Uint8List && thumbnail.isNotEmpty
          ? thumbnail
          : null,
      thumbnailWidth: number('thumbnailWidth'),
      thumbnailHeight: number('thumbnailHeight'),
    );
  }

  @override
  Future<String> compress(
    String path, {
    required int shortSide,
    required int videoBitrate,
  }) async {
    final output = await _channel.invokeMethod<String>('compress', {
      'path': path,
      'shortSide': shortSide,
      'videoBitrate': videoBitrate,
    });
    if (output == null) throw const FormatException('Video compression failed');
    return output;
  }

  @override
  Future<VideoFrameSample?> sampleFrames(
    String path, {
    int maxEdge = 360,
    int maxFrames = 12,
    int maxDurationMs = 3000,
  }) async {
    final raw = await _channel
        .invokeMapMethod<String, Object?>('sampleFrames', {
          'path': path,
          'maxEdge': maxEdge,
          'maxFrames': maxFrames,
          'maxDurationMs': maxDurationMs,
        });
    if (raw == null) return null;
    final rawFrames = raw['frames'];
    if (rawFrames is! List) return null;
    final frames = <Uint8List>[
      for (final item in rawFrames)
        if (item is Uint8List && item.isNotEmpty) item,
    ];
    if (frames.isEmpty) return null;
    final delayMs = (raw['delayMs'] as num?)?.toInt() ?? 250;
    return VideoFrameSample(frames: frames, delayMs: delayMs.clamp(40, 1000));
  }

  @override
  Future<void> delete(String path) =>
      _channel.invokeMethod<void>('delete', {'path': path});
}

bool isVideoMime(String mimeType) => mimeType.startsWith('video/');

/// Videos over this short side are scaled down even when they already fit.
const _maxSendShortSide = 1080;
const _compressedShortSide = 720;
const _maxVideoBitrate = 2500000;
const _minVideoBitrate = 500000;
const _audioBitrate = 128000;

/// Roughly the longest video that still fits after compression.
String get maxVideoLengthLabel {
  final seconds =
      (maxComposerMediaBytes * 0.9 * 8) / (_minVideoBitrate + _audioBitrate);
  return '${(seconds / 60).floor()} minutes';
}

/// A picked or recorded video as a composer attachment of at most
/// [maxBytes]. Small videos are sent unchanged; larger or very high
/// resolution ones are re-encoded to 720p with a bitrate chosen from their
/// length so they fit, as messaging apps do.
Future<MediaSelection> prepareVideoForSending(
  XFile file, {
  required String mimeType,
  VideoTools? tools,
  int maxBytes = maxComposerMediaBytes,
}) async {
  final video = tools ?? VideoTools.instance;
  final length = await file.length();
  VideoInfo? info;
  try {
    info = await video.probe(file.path);
  } on MissingPluginException {
    info = null; // No native tools (tests, desktop): send as is if it fits.
  } on PlatformException {
    info = null;
  }
  final shortSide = info?.shortSide;
  final fits = length <= maxBytes;
  if (fits && (shortSide == null || shortSide <= _maxSendShortSide)) {
    return MediaSelection(
      bytes: await readComposerMedia(file.openRead(), length: length),
      name: file.name,
      mimeType: mimeType,
      durationMs: info?.durationMs,
    );
  }
  if (info == null) {
    throw const FormatException(
      'This video is larger than 20 MB and can’t be compressed here.',
    );
  }
  final seconds = math.max(1, (info.durationMs ?? 60000) / 1000);
  // 90 % of the budget for video + audio, the rest for container overhead.
  final budget = (maxBytes * 0.9 * 8 / seconds).floor() - _audioBitrate;
  final bitrate = math.min(budget, _maxVideoBitrate);
  if (bitrate < _minVideoBitrate) {
    throw FormatException(
      'This video is too long to send. Videos can be up to about '
      '$maxVideoLengthLabel.',
    );
  }
  final output = await video.compress(
    file.path,
    shortSide: math.min(
      shortSide ?? _compressedShortSide,
      _compressedShortSide,
    ),
    videoBitrate: bitrate,
  );
  try {
    final compressed = File(output);
    final size = await compressed.length();
    if (size > maxBytes) {
      throw FormatException(
        'This video is too long to send. Videos can be up to about '
        '$maxVideoLengthLabel.',
      );
    }
    return MediaSelection(
      bytes: await readComposerMedia(compressed.openRead(), length: size),
      name: _mp4Name(file.name),
      mimeType: 'video/mp4',
      durationMs: info.durationMs,
    );
  } finally {
    try {
      await video.delete(output);
    } catch (_) {
      // The native side also clears its work directory on start.
    }
  }
}

String _mp4Name(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return '${base.isEmpty ? 'video' : base}.mp4';
}

/// Poster frame and dimensions for a video about to be uploaded. The bytes
/// are written to a temporary file for the native reader. Null when the
/// platform has no reader or the video can't be decoded.
Future<VideoInfo?> probeVideoBytes(Uint8List bytes, {VideoTools? tools}) async {
  final video = tools ?? VideoTools.instance;
  Directory? dir;
  try {
    dir = await (await getTemporaryDirectory()).createTemp('parallax-probe');
    final file = File('${dir.path}/video');
    await file.writeAsBytes(bytes, flush: true);
    return await video.probe(file.path);
  } catch (_) {
    return null;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

/// Samples evenly spaced JPEG frames from [bytes] by writing a temporary file
/// for the native reader, then deleting it. Null when the platform has no
/// reader or the video cannot be decoded.
Future<VideoFrameSample?> sampleVideoBytes(
  Uint8List bytes, {
  VideoTools? tools,
  Directory? cacheDir,
  int maxEdge = 360,
  int maxFrames = 12,
  int maxDurationMs = 3000,
}) async {
  final video = tools ?? VideoTools.instance;
  Directory? dir;
  try {
    final base = cacheDir ?? await getTemporaryDirectory();
    await base.create(recursive: true);
    dir = await base.createTemp('parallax-video-preview-');
    final file = File('${dir.path}/video');
    await file.writeAsBytes(bytes, flush: true);
    return await video.sampleFrames(
      file.path,
      maxEdge: maxEdge,
      maxFrames: maxFrames,
      maxDurationMs: maxDurationMs,
    );
  } catch (_) {
    return null;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}
