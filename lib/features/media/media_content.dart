import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';

/// Bounded media metadata read from untrusted event content.
///
/// Every value is optional and range-checked: senders control `info`, so a
/// malformed or hostile event must never produce a negative size, a giant
/// layout or an unbounded waveform.
@immutable
class MediaInfo {
  const MediaInfo({
    required this.name,
    this.mimeType,
    this.size,
    this.width,
    this.height,
    this.duration,
    this.caption,
    this.hasThumbnail = false,
    this.waveform = const [],
  });

  factory MediaInfo.fromEntry(ChatEntry entry) =>
      MediaInfo.fromContent(entry.content, body: entry.body);

  factory MediaInfo.fromContent(Map<String, Object?> content, {String? body}) {
    final rawInfo = content['info'];
    final info = rawInfo is Map ? rawInfo : const {};
    final rawBody = body ?? content['body'];
    final text = rawBody is String ? rawBody.trim() : '';
    final rawFilename = content['filename'];
    final filename = rawFilename is String && rawFilename.trim().isNotEmpty
        ? rawFilename.trim()
        : null;
    // MSC2530: body is a caption only when a distinct filename is present.
    final caption = filename != null && text.isNotEmpty && filename != text
        ? text
        : null;
    final rawAudio = content['org.matrix.msc1767.audio'];
    final audio = rawAudio is Map ? rawAudio : const {};
    final mime = info['mimetype'];
    final file = content['file'];
    final fileMime = file is Map ? file['mimetype'] : null;
    final durationMs =
        _boundedInt(info['duration'], 24 * 60 * 60 * 1000) ??
        _boundedInt(audio['duration'], 24 * 60 * 60 * 1000);
    final rawThumbInfo = info['thumbnail_info'];
    final thumbInfo = rawThumbInfo is Map ? rawThumbInfo : const {};
    var width = _boundedInt(info['w'], 100000, min: 1);
    var height = _boundedInt(info['h'], 100000, min: 1);
    final thumbW = _boundedInt(thumbInfo['w'], 100000, min: 1);
    final thumbH = _boundedInt(thumbInfo['h'], 100000, min: 1);
    if (width == null || height == null) {
      if (thumbW != null && thumbH != null) {
        width = thumbW;
        height = thumbH;
      }
    } else if (thumbW != null &&
        thumbH != null &&
        width != height &&
        thumbW != thumbH &&
        (width > height) != (thumbW > thumbH) &&
        ((height / width) - (thumbW / thumbH)).abs() < 0.15) {
      // Senders that probe coded stream dimensions without rotation metadata
      // write landscape w/h alongside an auto-rotated portrait thumbnail.
      final swap = width;
      width = height;
      height = swap;
    }
    return MediaInfo(
      name: _safeName(filename ?? (text.isEmpty ? 'Attachment' : text)),
      mimeType: _mime(mime) ?? _mime(fileMime),
      size: _boundedInt(info['size'], 1 << 40),
      width: width,
      height: height,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      caption: caption,
      hasThumbnail:
          info['thumbnail_url'] is String || info['thumbnail_file'] is Map,
      waveform: parseWaveform(audio['waveform']),
    );
  }

  /// File name (or body when there is no separate file name).
  final String name;
  final String? mimeType;
  final int? size;
  final int? width;
  final int? height;
  final Duration? duration;

  /// Caption text, shown only when it differs from the file name.
  final String? caption;
  final bool hasThumbnail;

  /// Voice waveform normalised to 0..1 (empty when absent or malformed).
  final List<double> waveform;

  double? get aspectRatio {
    final w = width, h = height;
    if (w == null || h == null) return null;
    return (w / h).clamp(0.2, 5.0);
  }

  /// GIF and WebP may be animated; the timeline loads the bounded original.
  bool get mayBeAnimated => mimeType == 'image/gif' || mimeType == 'image/webp';

  static String? _mime(Object? raw) {
    if (raw is! String) return null;
    final mime = raw.split(';').first.trim().toLowerCase();
    return RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(mime) &&
            mime.length <= 100
        ? mime
        : null;
  }
}

int? _boundedInt(Object? raw, int max, {int min = 0}) {
  if (raw is! num || !raw.isFinite) return null;
  final value = raw.round();
  return value < min || value > max ? null : value;
}

String _safeName(String raw) {
  final name = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  if (name.isEmpty) return 'Attachment';
  return name.length > 200 ? '${name.substring(0, 200)}…' : name;
}

/// Reads an MSC1767 waveform (integers 0..1024). Returns values in 0..1, or an
/// empty list when the payload is missing, oversized or malformed.
List<double> parseWaveform(Object? raw) {
  if (raw is! List || raw.isEmpty || raw.length > 4096) return const [];
  final values = <double>[];
  for (final item in raw) {
    if (item is! num || !item.isFinite) return const [];
    values.add((item.toDouble() / 1024).clamp(0.0, 1.0));
  }
  return List.unmodifiable(values);
}

/// Resamples [samples] (0..1) to exactly [bars] values by bucket averaging.
List<double> resampleWaveform(List<double> samples, int bars) {
  if (bars <= 0) return const [];
  if (samples.isEmpty) return List.filled(bars, 0);
  final result = <double>[];
  for (var i = 0; i < bars; i++) {
    final start = (i * samples.length / bars).floor();
    final end = math.max(start + 1, ((i + 1) * samples.length / bars).floor());
    var sum = 0.0;
    for (var j = start; j < end && j < samples.length; j++) {
      sum += samples[j];
    }
    result.add(sum / (end - start));
  }
  return result;
}

String formatMediaDuration(Duration duration) {
  final total = duration.isNegative ? 0 : duration.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '$text ${units[unit]}';
}

/// Short upper-case type label: the file extension, or the MIME subtype.
String fileTypeLabel(String name, String? mimeType) {
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot < name.length - 1) {
    final extension = name.substring(dot + 1);
    if (RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(extension)) {
      return extension.toUpperCase();
    }
  }
  final subtype = mimeType?.split('/').last;
  if (subtype != null && RegExp(r'^[a-z0-9]{1,8}$').hasMatch(subtype)) {
    return subtype.toUpperCase();
  }
  return 'FILE';
}

IconData fileTypeIcon(String name, String? mimeType) {
  final mime = mimeType ?? '';
  final label = fileTypeLabel(name, mimeType).toLowerCase();
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_rounded;
  if (mime == 'application/pdf' || label == 'pdf') {
    return Icons.picture_as_pdf_outlined;
  }
  if ({'zip', 'rar', '7z', 'gz', 'tar', 'tgz', 'bz2', 'xz'}.contains(label) ||
      mime.contains('zip') ||
      mime.contains('compressed')) {
    return Icons.folder_zip_outlined;
  }
  if ({'xls', 'xlsx', 'csv', 'ods', 'numbers'}.contains(label) ||
      mime.contains('spreadsheet')) {
    return Icons.table_chart_outlined;
  }
  if ({'ppt', 'pptx', 'odp', 'key'}.contains(label) ||
      mime.contains('presentation')) {
    return Icons.slideshow_outlined;
  }
  if ({'doc', 'docx', 'odt', 'rtf', 'txt', 'md'}.contains(label) ||
      mime.startsWith('text/') ||
      mime.contains('document')) {
    return Icons.description_outlined;
  }
  if ({'apk', 'aab'}.contains(label)) return Icons.android_rounded;
  return Icons.insert_drive_file_outlined;
}

/// Kinds shown in the "Media" tab and swiped in the viewer.
bool isVisualMediaKind(EntryKind kind) =>
    kind == EntryKind.image || kind == EntryKind.video;

/// Kinds shown in the "Files" tab.
bool isFileMediaKind(EntryKind kind) =>
    kind == EntryKind.file ||
    kind == EntryKind.audio ||
    kind == EntryKind.voice;

bool isMediaKind(EntryKind kind) =>
    isVisualMediaKind(kind) ||
    isFileMediaKind(kind) ||
    kind == EntryKind.sticker;

/// Display size for a media preview inside a bubble, from declared
/// dimensions. Hostile ratios are clamped so one event cannot dominate.
Size mediaPreviewSize(MediaInfo info, {double maxWidth = 240}) =>
    mediaPreviewSizeForAspect(info.aspectRatio, maxWidth: maxWidth);

/// Display size for a media preview from an aspect ratio (`width / height`).
Size mediaPreviewSizeForAspect(double? aspectRatio, {double maxWidth = 240}) {
  final limit = maxWidth.isFinite ? math.max(80.0, maxWidth) : 240.0;
  final ratio = aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio.clamp(0.2, 5.0)
      : null;
  if (ratio == null) return Size(limit, limit * 0.72);
  var width = limit;
  var height = width / ratio;
  if (height > 320) {
    height = 320;
    width = math.min(limit, math.max(120, height * ratio));
  } else if (height < 110) {
    height = 110;
  }
  return Size(width, height);
}

/// Animated GIF/WebP previews keep their own shape instead of being cropped
/// into a fixed box: full width at the media's aspect, capped in height.
/// Unlike [mediaPreviewSizeForAspect] there is no minimum height, so a wide
/// GIF renders as a short strip rather than having its sides cut off.
Size gifPreviewSize(
  double? aspectRatio, {
  double maxWidth = 240,
  double fallbackHeight = 170,
}) {
  final limit = maxWidth.isFinite ? math.max(80.0, maxWidth) : 240.0;
  final ratio = aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio.clamp(0.2, 5.0)
      : null;
  if (ratio == null) return Size(limit, fallbackHeight);
  var width = limit;
  var height = width / ratio;
  if (height > 320) {
    height = 320;
    width = height * ratio;
  }
  return Size(width, height);
}

/// In-memory image decoded within [maxEdge]×[maxEdge] (aspect preserved, never
/// upscaled), so a hostile 1×100000 image cannot expand into a huge bitmap.
/// Multi-frame GIF/WebP animate frame by frame at the same bound.
ImageProvider boundedMemoryImage(Uint8List bytes, {int maxEdge = 1024}) =>
    ResizeImage(
      MemoryImage(bytes),
      width: maxEdge,
      height: maxEdge,
      policy: ResizeImagePolicy.fit,
    );
