// Media previews and avatars for notifications.
//
// Downloads are size-capped and same-origin authenticated
// (downloadMatrixMedia), encrypted media is decrypted on the device, and every
// image or video clip is decoded with pixel/frame bounds and re-encoded before
// it is written to a private cache file. Static images become JPEG; animated
// GIFs, animated WebPs and sampled video clips become looping GIFs so Android
// ConversationLayout / MessagingStyle animates them inline like camera alerts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as matrix;
import 'package:path/path.dart' as p;

import '../../media_download.dart';
import '../media/video_prep.dart';
import 'notification_content.dart';

/// Cache sub-directory shared with `res/xml/notification_provider_paths.xml`.
const notificationMediaDirectory = 'notification_media';

/// FileProvider authority declared in AndroidManifest.xml
/// (`${applicationId}.notifications.fileprovider`).
const notificationFileProviderAuthority =
    'net.samrussell.parallax.notifications.fileprovider';

/// Long edge of a static message preview image.
const notificationPreviewEdge = 640;

/// Long edge of an animated GIF/WebP or video preview (Android SystemUI caps
/// inline MessagingStyle drawables at 480 px).
const notificationAnimatedPreviewEdge = 360;

/// Maximum frames emitted in an encoded animated notification preview.
const maxNotificationAnimationFrames = 24;

/// Edge of an avatar icon.
const notificationAvatarEdge = 128;

/// Largest decoded single frame (pixels) accepted from the network.
const _maxDecodePixels = 24 * 1000 * 1000;

/// Hard cap on input frames inspected from an untrusted animation.
const _maxSourceAnimationFrames = 300;

/// Files kept in the preview cache.
const _maxCachedFiles = 60;

/// The `content://` URI the system uses to read a preview file, or null when
/// [path] is not inside [cacheRoot]'s notification media directory.
String? notificationContentUri(String path, String cacheRoot) {
  final directory = p.join(cacheRoot, notificationMediaDirectory);
  if (!p.isWithin(directory, path)) return null;
  final relative = p.relative(path, from: directory);
  if (relative.contains('..')) return null;
  return Uri(
    scheme: 'content',
    host: notificationFileProviderAuthority,
    pathSegments: [notificationMediaDirectory, ...p.split(relative)],
  ).toString();
}

typedef EncryptedFileDecryptor =
    Future<Uint8List?> Function(matrix.EncryptedFile file);

typedef VideoFrameSampler =
    Future<VideoFrameSample?> Function(Uint8List videoBytes);

/// Loads previews for one session. Every method returns null on any failure.
class NotificationMediaLoader {
  NotificationMediaLoader({
    required this.httpClient,
    required this.homeserver,
    required this.accessToken,
    required this.cacheRoot,
    this.timeout = const Duration(seconds: 8),
    EncryptedFileDecryptor? decrypt,
    Future<Uint8List?> Function(NotificationImageJob job)? process,
    VideoFrameSampler? sampleVideo,
  }) : _decrypt = decrypt ?? matrix.decryptFileImplementation,
       _process = process ?? ((job) => compute(processNotificationImage, job)),
       _sampleVideo =
           sampleVideo ??
           ((bytes) => sampleVideoBytes(
             bytes,
             cacheDir: cacheRoot,
             maxEdge: notificationAnimatedPreviewEdge,
           ));

  final http.Client httpClient;
  final Uri homeserver;
  final String accessToken;

  /// The app cache directory (Android `Context.getCacheDir()`).
  final Directory cacheRoot;
  final Duration timeout;
  final EncryptedFileDecryptor _decrypt;
  final Future<Uint8List?> Function(NotificationImageJob job) _process;
  final VideoFrameSampler _sampleVideo;

  Directory get _directory =>
      Directory(p.join(cacheRoot.path, notificationMediaDirectory));

  /// A preview file (`.jpg` or animated `.gif`) of [ref] for the message [key]
  /// (its event ID), falling back to [NotificationMediaRef.fallback] when the
  /// primary animated or video source fails.
  Future<String?> preview(NotificationMediaRef ref, String key) async {
    final primary = await _previewSingle(ref, key, timeout);
    if (primary != null) return primary;
    final fallback = ref.fallback;
    if (fallback == null) return null;
    const maxFallback = Duration(seconds: 4);
    final fallbackBudget = timeout < maxFallback ? timeout : maxFallback;
    return _previewSingle(fallback, key, fallbackBudget);
  }

  Future<String?> _previewSingle(
    NotificationMediaRef ref,
    String key,
    Duration budget,
  ) async {
    try {
      return await (() async {
        final maxBytes = ref.isVideo
            ? maxNotificationVideoBytes
            : (ref.mayAnimate && !ref.thumbnail)
            ? maxNotificationAnimatedMediaBytes
            : maxNotificationMediaBytes;
        final bytes = await _fetch(
          ref,
          width: notificationPreviewEdge,
          height: notificationPreviewEdge,
          method: 'scale',
          maxBytes: maxBytes,
        );
        if (bytes == null) return null;
        final Uint8List? processed;
        if (ref.isVideo) {
          final sample = await _sampleVideo(bytes);
          if (sample == null || sample.frames.isEmpty) return null;
          processed = await _process(
            NotificationImageJob.frames(
              sample.frames,
              edge: notificationAnimatedPreviewEdge,
              frameDelayMs: sample.delayMs,
            ),
          );
        } else {
          processed = await _process(
            NotificationImageJob(
              bytes,
              edge: notificationPreviewEdge,
              animate: true,
            ),
          );
        }
        if (processed == null) return null;
        final ext = _isGifBytes(processed) ? 'gif' : 'jpg';
        return await _write('m_${_hash(key)}.$ext', processed);
      })().timeout(budget);
    } catch (_) {
      return null;
    }
  }

  /// A circular PNG avatar for [mxc], cached by URI. The `a_c_` cache version
  /// avoids reusing square avatars written by earlier app versions.
  Future<String?> avatar(Uri? mxc) async {
    if (mxc == null || validMxc(mxc.toString()) == null) return null;
    try {
      final name = 'a_c_${_hash(mxc.toString())}.png';
      final existing = File(p.join(_directory.path, name));
      if (await existing.exists()) return existing.path;
      final bytes = await _fetch(
        NotificationMediaRef(mxc: mxc, thumbnail: true),
        width: 96,
        height: 96,
        method: 'crop',
        maxBytes: 512 * 1024,
      ).timeout(timeout);
      if (bytes == null) return null;
      final processed = await _process(
        NotificationImageJob(bytes, edge: notificationAvatarEdge, square: true),
      );
      if (processed == null) return null;
      return await _write(name, processed);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _fetch(
    NotificationMediaRef ref, {
    required int width,
    required int height,
    required String method,
    int maxBytes = maxNotificationMediaBytes,
  }) async {
    final source = ref.source;
    if (source == null) return null;
    final server = source.hasPort
        ? '${source.host}:${source.port}'
        : source.host;
    final mediaId = source.pathSegments.single;
    final encrypted = ref.encryptedFile;
    final fullDownload =
        encrypted != null || ref.isVideo || (ref.mayAnimate && !ref.thumbnail);
    final candidates = fullDownload
        ? [
            _endpoint('/_matrix/client/v1/media/download/$server/$mediaId'),
            _endpoint('/_matrix/media/v3/download/$server/$mediaId'),
          ]
        : [
            for (final base in [
              '/_matrix/client/v1/media/thumbnail',
              '/_matrix/media/v3/thumbnail',
            ])
              _endpoint(
                '$base/$server/$mediaId',
                query: {
                  'width': '$width',
                  'height': '$height',
                  'method': method,
                  'animated': ref.mayAnimate ? 'true' : 'false',
                },
              ),
          ];
    Uint8List? bytes;
    for (final uri in candidates) {
      try {
        bytes = await downloadMatrixMedia(
          httpClient: httpClient,
          homeserver: homeserver,
          uri: uri,
          accessToken: accessToken,
          maxBytes: maxBytes,
        );
        break;
      } catch (_) {
        // Try the legacy media API next.
      }
    }
    if (bytes == null || bytes.isEmpty) return null;
    if (encrypted == null) return bytes;
    final key = encrypted['key'];
    final iv = encrypted['iv'];
    final hashes = encrypted['hashes'];
    final k = key is Map ? key['k'] : null;
    final sha256 = hashes is Map ? hashes['sha256'] : null;
    if (k is! String || iv is! String || sha256 is! String) return null;
    return _decrypt(
      matrix.EncryptedFile(data: bytes, k: k, iv: iv, sha256: sha256),
    );
  }

  Uri _endpoint(String path, {Map<String, String>? query}) {
    final prefix = homeserver.path.endsWith('/')
        ? homeserver.path.substring(0, homeserver.path.length - 1)
        : homeserver.path;
    return homeserver.replace(
      path: '$prefix$path',
      queryParameters: query,
      fragment: null,
    );
  }

  Future<String> _write(String name, Uint8List bytes) async {
    final directory = _directory;
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, name));
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    unawaited(pruneNotificationMedia(cacheRoot));
    return file.path;
  }
}

bool _isGifBytes(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x47 && // G
    bytes[1] == 0x49 && // I
    bytes[2] == 0x46 && // F
    bytes[3] == 0x38; // 8

String _hash(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString().substring(0, 32);

/// Deletes all but the newest cached previews/avatars.
Future<void> pruneNotificationMedia(
  Directory cacheRoot, {
  int keep = _maxCachedFiles,
}) async {
  try {
    final directory = Directory(
      p.join(cacheRoot.path, notificationMediaDirectory),
    );
    if (!await directory.exists()) return;
    final files = <(File, DateTime)>[];
    await for (final entity in directory.list()) {
      if (entity is File && !entity.path.endsWith('.tmp')) {
        files.add((entity, await entity.lastModified()));
      }
    }
    if (files.length <= keep) return;
    files.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (file, _) in files.skip(keep)) {
      try {
        await file.delete();
      } on FileSystemException {
        // Raced with another isolate.
      }
    }
  } catch (_) {
    // Best effort.
  }
}

/// Deletes every cached preview and avatar (sign-out).
Future<void> clearNotificationMedia(Directory cacheRoot) async {
  try {
    final directory = Directory(
      p.join(cacheRoot.path, notificationMediaDirectory),
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {
    // Best effort.
  }
}

/// Input for [processNotificationImage] (sent to a worker isolate).
@immutable
class NotificationImageJob {
  const NotificationImageJob(
    this.bytes, {
    required this.edge,
    this.square = false,
    this.animate = false,
  }) : frames = null,
       frameDelayMs = 100;

  NotificationImageJob.frames(
    List<Uint8List> frames, {
    required this.edge,
    this.frameDelayMs = 250,
  }) : bytes = Uint8List(0),
       square = false,
       animate = true,
       frames = List<Uint8List>.unmodifiable(frames);

  final Uint8List bytes;
  final int edge;
  final bool square;
  final bool animate;
  final List<Uint8List>? frames;
  final int frameDelayMs;
}

/// Decodes untrusted image bytes or sampled video frames with dimension/pixel
/// bounds and re-encodes them (JPEG static preview, looping GIF animation or
/// circular PNG avatar). Drops all metadata. Returns null for unreadable,
/// unsupported or oversized inputs.
Uint8List? processNotificationImage(NotificationImageJob job) {
  try {
    final frameList = job.frames;
    if (frameList != null) {
      return _encodeVideoFrameSequence(frameList, job.edge, job.frameDelayMs);
    }
    final bytes = job.bytes;
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final header = decoder.startDecode(bytes);
    if (header == null) return null;
    final width = header.width, height = header.height;
    if (width <= 0 || height <= 0 || width > 16000 || height > 16000) {
      return null;
    }
    if (job.animate && !job.square) {
      final animEdge = math.min(job.edge, notificationAnimatedPreviewEdge);
      if (decoder is img.GifDecoder && header is img.GifInfo) {
        if (header.numFrames > 1) {
          final gif = _decodeAndEncodeGif(decoder, header, animEdge);
          if (gif != null) return gif;
        }
      } else if (decoder is img.WebPDecoder && header is img.WebPInfo) {
        if (header.hasAnimation && header.numFrames > 1) {
          final gif = _decodeAndEncodeWebP(decoder, header, animEdge);
          if (gif != null) return gif;
        }
      }
    }
    final decoded = _decodeSingleFrame(decoder, bytes, width, height, job.edge);
    if (decoded == null) return null;
    var image = img.bakeOrientation(decoded);
    if (job.square) {
      image = img.copyResizeCropSquare(
        image,
        size: math.min(job.edge, math.min(image.width, image.height)),
        interpolation: img.Interpolation.average,
      );
      image = img.copyCropCircle(image.convert(numChannels: 4));
      image.exif = img.ExifData();
      return img.encodePng(image, singleFrame: true);
    }
    image = _resizeDown(image, job.edge);
    image.exif = img.ExifData();
    return img.encodeJpg(image, quality: 80);
  } catch (_) {
    return null;
  }
}

img.Image? _decodeSingleFrame(
  img.Decoder decoder,
  Uint8List bytes,
  int width,
  int height,
  int edge,
) {
  if (decoder is img.JpegDecoder) {
    var scale = 1;
    final longEdge = math.max(width, height);
    while (scale < 8 && longEdge / (scale * 2) >= edge) {
      scale *= 2;
    }
    if ((width ~/ scale) * (height ~/ scale) > _maxDecodePixels) return null;
    return img.decodeJpg(bytes, maxPixels: _maxDecodePixels, scale: scale);
  }
  if (width * height > _maxDecodePixels) return null;
  return decoder.decode(bytes, frame: 0);
}

img.Image _resizeDown(img.Image image, int edge) {
  if (math.max(image.width, image.height) <= edge) return image;
  return image.width >= image.height
      ? img.copyResize(
          image,
          width: edge,
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          image,
          height: edge,
          interpolation: img.Interpolation.average,
        );
}

Uint8List? _encodeVideoFrameSequence(
  List<Uint8List> rawFrames,
  int edge,
  int frameDelayMs,
) {
  if (rawFrames.isEmpty) return null;
  final total = math.min(rawFrames.length, _maxSourceAnimationFrames);
  final keep = math.min(total, maxNotificationAnimationFrames);
  final emitIndices = List<int>.generate(keep, (k) => (k * total) ~/ keep);
  final images = <img.Image>[];
  final delaysCs = <int>[];
  final perFrameMs = frameDelayMs.clamp(40, 1000);

  for (var k = 0; k < keep; k++) {
    final start = emitIndices[k];
    final end = k + 1 < keep ? emitIndices[k + 1] : total;
    final raw = rawFrames[start];
    final decoder = img.findDecoderForData(raw);
    if (decoder == null) continue;
    final header = decoder.startDecode(raw);
    if (header == null) continue;
    final w = header.width, h = header.height;
    if (w <= 0 || h <= 0 || w > 16000 || h > 16000) continue;
    final decoded = _decodeSingleFrame(decoder, raw, w, h, edge);
    if (decoded == null) continue;
    var frame = _resizeDown(img.bakeOrientation(decoded), edge);
    if (images.isNotEmpty &&
        (frame.width != images.first.width ||
            frame.height != images.first.height)) {
      frame = img.copyResize(
        frame,
        width: images.first.width,
        height: images.first.height,
        interpolation: img.Interpolation.average,
      );
    }
    frame.exif = img.ExifData();
    images.add(frame);
    final spanMs = (end - start) * perFrameMs;
    delaysCs.add(math.max(4, (spanMs / 10).round()));
  }
  if (images.isEmpty) return null;
  return _encodeLoopingGif(images, delaysCs);
}

Uint8List? _decodeAndEncodeGif(
  img.GifDecoder decoder,
  img.GifInfo info,
  int edge,
) {
  final width = info.width, height = info.height;
  if (width * height > _maxDecodePixels) return null;
  final total = math.min(info.numFrames, _maxSourceAnimationFrames);
  if (total <= 1) return null;
  final keep = math.min(total, maxNotificationAnimationFrames);
  final emitIndices = List<int>.generate(keep, (k) => (k * total) ~/ keep);

  var canvas = img.Image(width: width, height: height, numChannels: 4);
  final images = <img.Image>[];
  final delaysCs = <int>[];
  var nextSlot = 0;
  var pendingCs = 0;

  for (var i = 0; i < total; i++) {
    final desc = info.frames[i];
    final sub = decoder.decodeFrame(i);
    if (sub == null) break;
    final prevBackup = desc.disposal == 3 ? canvas.clone() : null;
    _drawGifSubframe(canvas, sub, desc.x, desc.y, desc.transparent);

    final rawCs = desc.duration <= 1 ? 10 : desc.duration;
    if (nextSlot < keep && i == emitIndices[nextSlot]) {
      if (images.isNotEmpty) {
        delaysCs.add(pendingCs);
      }
      pendingCs = rawCs;
      final snapshot = math.max(width, height) > edge
          ? _resizeDown(canvas, edge)
          : canvas.clone();
      snapshot.exif = img.ExifData();
      images.add(snapshot);
      nextSlot++;
    } else {
      pendingCs += rawCs;
    }

    if (desc.disposal == 2) {
      _clearRectRgba(canvas, desc.x, desc.y, desc.width, desc.height);
    } else if (desc.disposal == 3 && prevBackup != null) {
      canvas = prevBackup;
    }
  }
  if (images.isNotEmpty) {
    delaysCs.add(pendingCs);
  }
  if (images.length <= 1) return null;
  return _encodeLoopingGif(images, delaysCs);
}

void _drawGifSubframe(
  img.Image canvas,
  img.Image sub,
  int fx,
  int fy,
  int transparentIndex,
) {
  final palette = sub.palette;
  if (palette == null) return;
  final hasAlphaChannel = palette.numChannels >= 4;
  final indices = sub.toUint8List();
  final dst = canvas.toUint8List();
  final cw = canvas.width, ch = canvas.height;
  final sw = sub.width, sh = sub.height;
  final numColors = palette.numColors;
  for (var y = 0; y < sh; y++) {
    final cy = fy + y;
    if (cy < 0 || cy >= ch) continue;
    final srcRow = y * sw;
    final dstRow = cy * cw;
    for (var x = 0; x < sw; x++) {
      final cx = fx + x;
      if (cx < 0 || cx >= cw) continue;
      final idx = indices[srcRow + x];
      if (idx == transparentIndex || idx >= numColors) continue;
      if (hasAlphaChannel && palette.getAlpha(idx) == 0) continue;
      final out = (dstRow + cx) * 4;
      dst[out] = palette.getRed(idx).toInt();
      dst[out + 1] = palette.getGreen(idx).toInt();
      dst[out + 2] = palette.getBlue(idx).toInt();
      dst[out + 3] = 255;
    }
  }
}

void _clearRectRgba(img.Image canvas, int rx, int ry, int rw, int rh) {
  final dst = canvas.toUint8List();
  final cw = canvas.width, ch = canvas.height;
  final x0 = rx.clamp(0, cw);
  final x1 = (rx + rw).clamp(0, cw);
  final y0 = ry.clamp(0, ch);
  final y1 = (ry + rh).clamp(0, ch);
  if (x0 >= x1 || y0 >= y1) return;
  for (var y = y0; y < y1; y++) {
    final start = (y * cw + x0) * 4;
    final end = (y * cw + x1) * 4;
    dst.fillRange(start, end, 0);
  }
}

Uint8List? _decodeAndEncodeWebP(
  img.WebPDecoder decoder,
  img.WebPInfo info,
  int edge,
) {
  final width = info.width, height = info.height;
  if (width * height > _maxDecodePixels) return null;
  final total = math.min(info.numFrames, _maxSourceAnimationFrames);
  if (total <= 1) return null;
  final keep = math.min(total, maxNotificationAnimationFrames);
  final emitIndices = List<int>.generate(keep, (k) => (k * total) ~/ keep);

  final canvas = img.Image(width: width, height: height, numChannels: 4);
  final images = <img.Image>[];
  final delaysCs = <int>[];
  var nextSlot = 0;
  var pendingMs = 0;

  for (var i = 0; i < total; i++) {
    final frame = info.frames[i];
    final sub = decoder.decodeFrame(i);
    if (sub == null) continue;
    img.compositeImage(
      canvas,
      sub,
      dstX: frame.x,
      dstY: frame.y,
      blend: frame.blendFrame ? img.BlendMode.alpha : img.BlendMode.direct,
    );

    final rawMs = frame.duration <= 10 ? 100 : frame.duration;
    if (nextSlot < keep && i >= emitIndices[nextSlot]) {
      if (images.isNotEmpty) {
        delaysCs.add(math.max(2, (pendingMs / 10).round()));
      }
      pendingMs = rawMs;
      final snapshot = math.max(width, height) > edge
          ? _resizeDown(canvas, edge)
          : canvas.clone();
      snapshot.exif = img.ExifData();
      images.add(snapshot);
      nextSlot++;
    } else {
      pendingMs += rawMs;
    }

    if (frame.clearFrame) {
      _clearRectRgba(canvas, frame.x, frame.y, frame.width, frame.height);
    }
  }
  if (images.isNotEmpty) {
    delaysCs.add(math.max(2, (pendingMs / 10).round()));
  }
  if (images.length <= 1) return null;
  return _encodeLoopingGif(images, delaysCs);
}

Uint8List? _encodeLoopingGif(List<img.Image> frames, List<int> delaysCs) {
  if (frames.isEmpty) return null;
  if (frames.length == 1) {
    frames.single.exif = img.ExifData();
    return img.encodeJpg(frames.single, quality: 80);
  }
  final encoder = img.GifEncoder(
    repeat: 0,
    quantizerType: img.QuantizerType.octree,
    dither: img.DitherKernel.floydSteinberg,
    dispose: 2,
  );
  for (var i = 0; i < frames.length; i++) {
    final frame = frames[i];
    final cs = (i < delaysCs.length ? delaysCs[i] : 10).clamp(2, 600);
    encoder.addFrame(_prepareGifFrame(frame), duration: cs);
  }
  return encoder.finish();
}

/// Preserves alpha transparency for sticker/reaction frames by reserving a
/// transparent palette slot; opaque frames go straight through GifEncoder's
/// Octree + Floyd-Steinberg path.
img.Image _prepareGifFrame(img.Image frame) {
  if (frame.numChannels < 4) return frame;
  final rgba = frame.convert(numChannels: 4);
  final bytes = rgba.toUint8List();
  var hasTransparent = false;
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] < 128) {
      hasTransparent = true;
      break;
    }
  }
  if (!hasTransparent) return rgba;

  final quantizer = img.OctreeQuantizer(rgba, numberOfColors: 255);
  final srcPalette = quantizer.palette;
  final colorCount = math.min(srcPalette.numColors, 255);
  final transparentIdx = colorCount;
  final palette = img.PaletteUint8(colorCount + 1, 4);
  for (var c = 0; c < colorCount; c++) {
    palette.setRgba(
      c,
      srcPalette.getRed(c),
      srcPalette.getGreen(c),
      srcPalette.getBlue(c),
      255,
    );
  }
  palette.setRgba(transparentIdx, 0, 0, 0, 0);

  final indexed = img.Image(
    width: rgba.width,
    height: rgba.height,
    numChannels: 1,
    palette: palette,
  );
  final out = indexed.toUint8List();
  for (var pIdx = 0, b = 0; pIdx < out.length; pIdx++, b += 4) {
    if (bytes[b + 3] < 128) {
      out[pIdx] = transparentIdx;
    } else {
      final mapped = quantizer.getColorIndexRgb(
        bytes[b],
        bytes[b + 1],
        bytes[b + 2],
      );
      out[pIdx] = mapped < colorCount ? mapped : 0;
    }
  }
  return indexed;
}
