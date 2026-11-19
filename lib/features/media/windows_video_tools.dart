// Windows video tools: ffprobe/ffmpeg helper processes, the counterpart of
// Android's MediaMetadataRetriever + Media3 Transformer (VideoTools.kt).
// The binaries ship next to the executable (or sit on PATH); without them
// probing returns null and sends fall back to "as is if it fits", exactly
// like a platform with no native tools.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'video_prep.dart';

/// Runs one helper process to completion; tests inject a fake so no
/// ffmpeg binaries are needed.
typedef VideoHelperRunner =
    Future<ProcessResult> Function(
      String tool,
      List<String> arguments,
      Duration timeout,
    );

class WindowsVideoTools implements VideoTools {
  WindowsVideoTools({
    this.toolDirectory,
    this.compressTimeout = const Duration(minutes: 5),
    this.probeTimeout = const Duration(seconds: 30),
    @visibleForTesting this.helperRunner,
    @visibleForTesting this.pathLookup = true,
  });

  /// Directory holding ffmpeg.exe and ffprobe.exe. Defaults to the app
  /// executable's own directory, then PATH, then the development install.
  final String? toolDirectory;
  final Duration compressTimeout;
  final Duration probeTimeout;

  /// Injected process runner (tests).
  final VideoHelperRunner? helperRunner;

  /// Whether a bare tool name may be resolved through PATH.
  final bool pathLookup;

  String? _ffmpeg;
  String? _ffprobe;

  String? _tool(String name) {
    final candidates = <String>[
      if (toolDirectory != null) p.join(toolDirectory!, '$name.exe'),
      p.join(p.dirname(Platform.resolvedExecutable), '$name.exe'),
      p.join(p.dirname(Platform.resolvedExecutable), 'ffmpeg', '$name.exe'),
      'C:\\dev\\ffmpeg\\bin\\$name.exe',
      name, // PATH lookup
    ];
    for (final candidate in candidates) {
      if (candidate == name) return pathLookup ? candidate : null;
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Runs a helper to completion, collecting stdout bytes and stderr text.
  /// A hung helper is killed at [timeout] rather than blocking the send.
  Future<_ProcessResult> _run(
    String tool,
    List<String> arguments,
    Duration timeout,
  ) async {
    final runner = helperRunner;
    if (runner != null) {
      final result = await runner(tool, arguments, timeout);
      return _ProcessResult(
        result.exitCode,
        Uint8List.fromList((result.stdout as List).cast<int>()),
        '${result.stderr}',
      );
    }
    final process = await Process.start(tool, arguments);
    final stdoutBytes = <int>[];
    final stderrText = StringBuffer();
    final stdoutDone = process.stdout
        .listen(stdoutBytes.addAll)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrText.write)
        .asFuture<void>();
    try {
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([stdoutDone, stderrDone]);
      return _ProcessResult(
        code,
        Uint8List.fromList(stdoutBytes),
        stderrText.toString(),
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
      throw TimeoutException('Video helper timed out', timeout);
    }
  }

  @override
  Future<VideoInfo?> probe(String path) async {
    final ffprobe = _ffprobe ??= _tool('ffprobe');
    final ffmpeg = _ffmpeg ??= _tool('ffmpeg');
    if (ffprobe == null || ffmpeg == null) return null;
    try {
      final result = await _run(ffprobe, [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height,duration:stream_tags=rotate:stream_side_data_list',
        '-show_entries',
        'format=duration',
        '-of',
        'json',
        path,
      ], probeTimeout);
      if (result.exitCode != 0) return null;
      final json = jsonDecode(utf8.decode(result.stdout));
      if (json is! Map) return null;
      final streams = json['streams'];
      if (streams is! List || streams.isEmpty) return null;
      final stream = streams.first;
      if (stream is! Map) return null;
      var width = (stream['width'] as num?)?.toInt();
      var height = (stream['height'] as num?)?.toInt();
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      // Display orientation, as MediaMetadataRetriever reports it: a 90/270
      // rotation flag swaps the stored dimensions.
      final rotation = _rotation(stream);
      if (rotation != null && (rotation % 180).abs() == 90) {
        final swap = width;
        width = height;
        height = swap;
      }
      final format = json['format'];
      final durationValue =
          stream['duration'] ?? (format is Map ? format['duration'] : null);
      final seconds = durationValue == null
          ? null
          : double.tryParse('$durationValue');
      final durationMs = seconds == null ? null : (seconds * 1000).round();
      final poster = await _poster(ffmpeg, path);
      return VideoInfo(
        width: width,
        height: height,
        durationMs: durationMs,
        thumbnail: poster?.$1,
        thumbnailWidth: poster?.$2,
        thumbnailHeight: poster?.$3,
      );
    } catch (_) {
      return null;
    }
  }

  /// Rotation in degrees from the side data (modern ffmpeg) or the legacy
  /// rotate tag. Null when the clip carries no rotation.
  int? _rotation(Map stream) {
    final sideData = stream['side_data_list'];
    if (sideData is List) {
      for (final entry in sideData) {
        if (entry is Map && entry['rotation'] is num) {
          return (entry['rotation'] as num).round();
        }
      }
    }
    final tags = stream['tags'];
    if (tags is Map && tags['rotate'] != null) {
      return int.tryParse('${tags['rotate']}');
    }
    return null;
  }

  /// JPEG poster frame, at most 800 px on its long side (same cap as
  /// Android). Returns the bytes and their dimensions.
  Future<(Uint8List, int, int)?> _poster(String ffmpeg, String path) async {
    try {
      final result = await _run(ffmpeg, [
        '-v',
        'error',
        '-i',
        path,
        '-frames:v',
        '1',
        '-vf',
        "scale='min(iw,800)':'min(ih,800)':force_original_aspect_ratio=decrease",
        '-f',
        'image2pipe',
        '-c:v',
        'mjpeg',
        'pipe:1',
      ], probeTimeout);
      if (result.exitCode != 0 || result.stdout.isEmpty) return null;
      final size = _jpegSize(result.stdout);
      if (size == null) return null;
      return (result.stdout, size.$1, size.$2);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> compress(
    String path, {
    required int shortSide,
    required int videoBitrate,
  }) async {
    final ffmpeg = _ffmpeg ??= _tool('ffmpeg');
    if (ffmpeg == null) {
      throw const FormatException('Video compression is not available here');
    }
    final dir = await Directory.systemTemp.createTemp('parallax-video-');
    final output = p.join(dir.path, 'out.mp4');
    // ffmpeg applies the display rotation while re-encoding, so iw/ih here
    // are already the display dimensions. -2 keeps the other side even.
    final scale =
        "scale=w='if(gt(iw,ih),-2,$shortSide)':h='if(gt(iw,ih),$shortSide,-2)'";
    try {
      final result = await _run(ffmpeg, [
        '-v',
        'error',
        '-y',
        '-i',
        path,
        '-vf',
        scale,
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-b:v',
        '$videoBitrate',
        '-maxrate',
        '$videoBitrate',
        '-bufsize',
        '${videoBitrate * 2}',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-b:a',
        '128000',
        '-movflags',
        '+faststart',
        output,
      ], compressTimeout);
      if (result.exitCode != 0 || !File(output).existsSync()) {
        throw const FormatException('Video compression failed');
      }
      return output;
    } catch (_) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      throw const FormatException('Video compression failed');
    }
  }

  @override
  Future<VideoFrameSample?> sampleFrames(
    String path, {
    int maxEdge = 360,
    int maxFrames = 12,
    int maxDurationMs = 3000,
  }) async {
    final ffprobe = _ffprobe ??= _tool('ffprobe');
    final ffmpeg = _ffmpeg ??= _tool('ffmpeg');
    if (ffprobe == null || ffmpeg == null) return null;
    try {
      final info = await probe(path);
      final durationMs = info?.durationMs;
      final sampledMs = durationMs == null
          ? maxDurationMs
          : durationMs.clamp(1, maxDurationMs);
      final fps = maxFrames * 1000 / sampledMs;
      final result = await _run(ffmpeg, [
        '-v',
        'error',
        '-t',
        '${sampledMs / 1000}',
        '-i',
        path,
        '-vf',
        "fps=$fps,scale='min($maxEdge,iw)':'min($maxEdge,ih)':force_original_aspect_ratio=decrease",
        '-frames:v',
        '$maxFrames',
        '-f',
        'image2pipe',
        '-c:v',
        'mjpeg',
        'pipe:1',
      ], probeTimeout);
      if (result.exitCode != 0) return null;
      final frames = _splitJpegs(result.stdout);
      if (frames.isEmpty) return null;
      return VideoFrameSample(
        frames: frames,
        delayMs: (sampledMs / frames.length).round(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete(String path) async {
    try {
      final file = File(path);
      // Only the per-compression work directory is ours to remove wholesale.
      if (p.basename(p.dirname(path)).startsWith('parallax-video-')) {
        await Directory(p.dirname(path)).delete(recursive: true);
      } else if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Already gone.
    }
  }
}

class _ProcessResult {
  const _ProcessResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final Uint8List stdout;
  final String stderr;
}

/// Dimensions from a JPEG's SOF marker (the poster is always MJPEG).
(int, int)? _jpegSize(Uint8List bytes) {
  for (var i = 0; i + 9 < bytes.length; i++) {
    if (bytes[i] != 0xFF) continue;
    final marker = bytes[i + 1];
    // SOF0..SOF15 except DHT (C4), JPG (C8) and DAC (CC).
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width > 0 && height > 0) return (width, height);
      return null;
    }
  }
  return null;
}

/// Splits a concatenated MJPEG stream into its JPEG frames.
List<Uint8List> _splitJpegs(Uint8List bytes) {
  final frames = <Uint8List>[];
  var start = -1;
  for (var i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] != 0xFF) continue;
    if (bytes[i + 1] == 0xD8) {
      start = i;
    } else if (bytes[i + 1] == 0xD9 && start >= 0) {
      frames.add(Uint8List.sublistView(bytes, start, i + 2));
      start = -1;
    }
  }
  return frames;
}
