// Media previews and avatars for notifications.
//
// Downloads are size-capped and same-origin authenticated
// (downloadMatrixMedia), encrypted media is decrypted on the device, and every
// image is decoded with pixel bounds and re-encoded before it is written to a
// private cache file. Android reads MessagingStyle images through the
// FileProvider declared in AndroidManifest.xml (`notification_media/` under
// the cache directory); avatars are decoded in-process by the plugin.
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
import 'notification_content.dart';

/// Cache sub-directory shared with `res/xml/notification_provider_paths.xml`.
const notificationMediaDirectory = 'notification_media';

/// FileProvider authority declared in AndroidManifest.xml
/// (`${applicationId}.notifications.fileprovider`).
const notificationFileProviderAuthority =
    'net.samrussell.parallax.notifications.fileprovider';

/// Long edge of a message preview image.
const notificationPreviewEdge = 640;

/// Edge of an avatar icon.
const notificationAvatarEdge = 128;

/// Largest decoded image (pixels) accepted from the network.
const _maxDecodePixels = 24 * 1000 * 1000;

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
  }) : _decrypt = decrypt ?? matrix.decryptFileImplementation,
       _process = process ?? ((job) => compute(processNotificationImage, job));

  final http.Client httpClient;
  final Uri homeserver;
  final String accessToken;

  /// The app cache directory (Android `Context.getCacheDir()`).
  final Directory cacheRoot;
  final Duration timeout;
  final EncryptedFileDecryptor _decrypt;
  final Future<Uint8List?> Function(NotificationImageJob job) _process;

  Directory get _directory =>
      Directory(p.join(cacheRoot.path, notificationMediaDirectory));

  /// A JPEG preview of [ref] for the message [key] (its event ID).
  Future<String?> preview(NotificationMediaRef ref, String key) async {
    try {
      final bytes = await _fetch(
        ref,
        width: notificationPreviewEdge,
        height: notificationPreviewEdge,
        method: 'scale',
      ).timeout(timeout);
      if (bytes == null) return null;
      final processed = await _process(
        NotificationImageJob(bytes, edge: notificationPreviewEdge),
      );
      if (processed == null) return null;
      return await _write('m_${_hash(key)}.jpg', processed);
    } catch (_) {
      return null;
    }
  }

  /// A square PNG avatar for [mxc], cached by URI.
  Future<String?> avatar(Uri? mxc) async {
    if (mxc == null || validMxc(mxc.toString()) == null) return null;
    try {
      final name = 'a_${_hash(mxc.toString())}.png';
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
    final candidates = encrypted != null
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
                  'animated': 'false',
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
      if (entity is File) files.add((entity, await entity.lastModified()));
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
  });
  final Uint8List bytes;
  final int edge;
  final bool square;
}

/// Decodes untrusted image bytes with dimension/pixel bounds and re-encodes
/// them (JPEG preview or PNG square avatar). Drops all metadata. Returns null
/// for unreadable, unsupported or oversized images.
Uint8List? processNotificationImage(NotificationImageJob job) {
  try {
    final bytes = job.bytes;
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    final header = decoder.startDecode(bytes);
    if (header == null) return null;
    final width = header.width, height = header.height;
    if (width <= 0 || height <= 0 || width > 16000 || height > 16000) {
      return null;
    }
    img.Image? decoded;
    if (decoder is img.JpegDecoder) {
      var scale = 1;
      final longEdge = math.max(width, height);
      while (scale < 8 && longEdge / (scale * 2) >= job.edge) {
        scale *= 2;
      }
      if ((width ~/ scale) * (height ~/ scale) > _maxDecodePixels) return null;
      decoded = img.decodeJpg(bytes, maxPixels: _maxDecodePixels, scale: scale);
    } else {
      if (width * height > _maxDecodePixels) return null;
      decoded = decoder.decode(bytes, frame: 0);
    }
    if (decoded == null) return null;
    var image = img.bakeOrientation(decoded);
    if (job.square) {
      image = img.copyResizeCropSquare(
        image,
        size: math.min(job.edge, math.min(image.width, image.height)),
        interpolation: img.Interpolation.average,
      );
      image.exif = img.ExifData();
      return img.encodePng(image, singleFrame: true);
    }
    if (math.max(image.width, image.height) > job.edge) {
      image = image.width >= image.height
          ? img.copyResize(
              image,
              width: job.edge,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              image,
              height: job.edge,
              interpolation: img.Interpolation.average,
            );
    }
    image.exif = img.ExifData();
    return img.encodeJpg(image, quality: 80);
  } catch (_) {
    return null;
  }
}
