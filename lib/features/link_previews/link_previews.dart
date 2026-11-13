/// Link previews: the page title and image for the first web link in a
/// message, fetched by the homeserver (`GET /_matrix/client/v1/media/
/// preview_url`) rather than by the phone.
///
/// Previews are on by default in ordinary rooms, where the homeserver can
/// already read the link. In encrypted rooms they are off unless the user
/// opts in (Settings → Media → Link previews), because fetching the preview
/// tells the homeserver which link was sent.
library;

import 'package:flutter/foundation.dart';

import '../rich_timeline/linkify.dart';

/// Longest URL offered for a preview.
const maxPreviewUrlLength = 2048;

/// A native-playable video or stream linked by a page's Open Graph metadata.
@immutable
class LinkVideo {
  const LinkVideo({required this.url, this.mimeType, this.width, this.height});
  final Uri url;
  final String? mimeType;
  final int? width;
  final int? height;

  double? get aspectRatio {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }
}

/// What a page's Open Graph tags say about it.
@immutable
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.image,
    this.imageWidth,
    this.imageHeight,
    this.video,
  });

  /// The link as sent in the message (what tapping opens).
  final Uri url;
  final String? title;
  final String? description;
  final String? siteName;

  /// `mxc://` URI of the page's image, hosted by the homeserver.
  final Uri? image;
  final int? imageWidth;
  final int? imageHeight;

  /// Optional direct video/stream for native in-app playback.
  final LinkVideo? video;

  double? get imageAspectRatio {
    final w = imageWidth, h = imageHeight;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  /// Nothing worth showing: no title, text, image or playable video.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (description == null || description!.isEmpty) &&
      image == null &&
      video == null;

  /// Where the link goes, without `www.` (the small line above the title).
  String get host {
    final site = siteName?.trim();
    if (site != null && site.isNotEmpty) return site;
    final host = url.host;
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  Map<String, Object?> toJson() => {
    'url': url.toString(),
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (siteName != null) 'siteName': siteName,
    if (image != null) 'image': image.toString(),
    if (imageWidth != null) 'imageWidth': imageWidth,
    if (imageHeight != null) 'imageHeight': imageHeight,
    if (video != null) 'videoUrl': video!.url.toString(),
    if (video?.mimeType != null) 'videoMimeType': video!.mimeType,
    if (video?.width != null) 'videoWidth': video!.width,
    if (video?.height != null) 'videoHeight': video!.height,
  };

  /// Tolerates missing and wrongly typed fields; throws only on a missing
  /// or unusable URL.
  static LinkPreview? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = Uri.tryParse('${json['url'] ?? ''}');
    if (url == null || !url.hasScheme) return null;
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    int? dimension(String key) {
      final value = json[key];
      final parsed = switch (value) {
        final int n => n,
        final num n => n.round(),
        final String s => int.tryParse(s.trim()),
        _ => null,
      };
      return parsed != null && parsed > 0 && parsed <= 32768 ? parsed : null;
    }

    final image = Uri.tryParse(text('image') ?? '');
    final video = playableLinkVideo(
      Uri.tryParse(text('videoUrl') ?? ''),
      mimeType: text('videoMimeType'),
      width: dimension('videoWidth'),
      height: dimension('videoHeight'),
    );
    return LinkPreview(
      url: url,
      title: text('title'),
      description: text('description'),
      siteName: text('siteName'),
      image: image != null && image.scheme == 'mxc' && image.host.isNotEmpty
          ? image
          : null,
      imageWidth: dimension('imageWidth'),
      imageHeight: dimension('imageHeight'),
      video: video,
    );
  }
}

const _playableVideoMimes = {
  'video/mp4',
  'video/x-m4v',
  'video/quicktime',
  'video/webm',
  'application/x-mpegurl',
  'application/vnd.apple.mpegurl',
};
const _videoExtensions = {
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'm3u8': 'application/x-mpegurl',
};

/// Returns a native-playable public HTTPS video, or null for HTML embeds,
/// unsupported formats and local/private-network targets.
LinkVideo? playableLinkVideo(
  Uri? url, {
  String? mimeType,
  int? width,
  int? height,
}) {
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      !_publicVideoHost(url.host.toLowerCase())) {
    return null;
  }
  final validWidth = width != null && width > 0 ? width : null;
  final validHeight = height != null && height > 0 ? height : null;
  final mime = mimeType?.split(';').first.trim().toLowerCase();
  if (mime == 'text/html') return null;
  final extension = url.pathSegments.isEmpty
      ? ''
      : url.pathSegments.last.split('.').last.toLowerCase();
  final inferred = _videoExtensions[extension];
  if (mime != null && _playableVideoMimes.contains(mime)) {
    return LinkVideo(
      url: url,
      mimeType: mime,
      width: validWidth,
      height: validHeight,
    );
  }
  if (inferred != null) {
    return LinkVideo(
      url: url,
      mimeType: inferred,
      width: validWidth,
      height: validHeight,
    );
  }
  return null;
}

bool _publicVideoHost(String host) {
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal') ||
      host.endsWith('.lan')) {
    return false;
  }
  final ipv4 = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
  ).firstMatch(host);
  if (ipv4 != null) {
    final parts = [for (var i = 1; i <= 4; i++) int.parse(ipv4[i]!)];
    if (parts.any((part) => part > 255)) return false;
    final a = parts[0], b = parts[1];
    if (a == 0 ||
        a == 10 ||
        a == 127 ||
        (a == 169 && b == 254) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127) ||
        a >= 224) {
      return false;
    }
  }
  if (host.contains(':') &&
      (host == '::1' ||
          host.startsWith('fe80:') ||
          host.startsWith('fc') ||
          host.startsWith('fd'))) {
    return false;
  }
  return true;
}

/// Unwraps known redirect wrappers (such as Facebook's `l.php?u=...`) so the
/// homeserver previews the destination page or photo instead of an interstitial.
Uri unwrapLinkRedirect(Uri url) {
  final host = url.host.toLowerCase();
  if (host == 'l.facebook.com' ||
      host == 'lm.facebook.com' ||
      ((host == 'm.facebook.com' ||
              host == 'www.facebook.com' ||
              host == 'facebook.com') &&
          (url.path == '/l.php' || url.path.startsWith('/flx/warn')))) {
    final rawTarget = url.queryParameters['u'];
    if (rawTarget != null && rawTarget.isNotEmpty) {
      final target = Uri.tryParse(rawTarget);
      if (target != null &&
          (target.scheme == 'https' || target.scheme == 'http') &&
          target.host.isNotEmpty &&
          target.toString().length <= maxPreviewUrlLength) {
        return target;
      }
    }
  }
  return url;
}

/// Maps a Matrix `preview_url` response's Open Graph fields to a preview,
/// retaining native video only when it is directly playable.
LinkPreview linkPreviewFromOpenGraph(
  Uri url,
  Map<String, Object?> fields, {
  Uri? image,
}) {
  String? text(String key, int limit) {
    final value = fields[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length <= limit ? trimmed : trimmed.substring(0, limit);
  }

  int? dimension(String key) {
    final value = fields[key];
    final parsed = switch (value) {
      final int n => n,
      final num n => n.round(),
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
    return parsed != null && parsed > 0 && parsed <= 32768 ? parsed : null;
  }

  final resolvedImage = image ?? Uri.tryParse(text('og:image', 2048) ?? '');
  final videoUrl =
      text('og:video:secure_url', 2048) ??
      text('og:video:url', 2048) ??
      text('og:video', 2048);
  final videoType =
      text('og:video:type', 120) ?? text('og:video:content_type', 120);
  return LinkPreview(
    url: url,
    title: text('og:title', 300),
    description: text('og:description', 500),
    siteName: text('og:site_name', 120),
    image:
        resolvedImage != null &&
            resolvedImage.scheme == 'mxc' &&
            resolvedImage.host.isNotEmpty
        ? resolvedImage
        : null,
    imageWidth: dimension('og:image:width'),
    imageHeight: dimension('og:image:height'),
    video: playableLinkVideo(
      Uri.tryParse(videoUrl ?? ''),
      mimeType: videoType,
      width: dimension('og:video:width'),
      height: dimension('og:video:height'),
    ),
  );
}

/// A backend that can ask its server for link previews. Backends without it
/// show no previews.
abstract interface class LinkPreviewSource {
  /// Account-scoped name for the on-disk cache, or empty for memory only.
  String get linkPreviewNamespace;

  /// The page's title and image, or null when there is nothing to show.
  /// May throw; failures are remembered briefly so a failing site isn't
  /// refetched on every rebuild.
  Future<LinkPreview?> fetchLinkPreview(Uri url, {int? timestamp});
}

/// Optional higher-resolution `mxc://` preview image loader for link cards
/// (photos and video posters). Backends without it fall back to avatars.
abstract interface class LinkPreviewImageSource {
  Uint8List? cachedPreviewImage(Uri mxc);
  Future<Uint8List?> loadPreviewImage(Uri mxc);
}

/// The first web link in [body] worth a preview, if any. Matrix permalinks
/// (rooms, people) and email addresses are not previews.
Uri? firstPreviewableLink(String body) {
  if (body.isEmpty) return null;
  for (final token in tokenizeText(body)) {
    if (token.kind != TextTokenKind.link) continue;
    final uri = token.href;
    if (uri == null) continue;
    if (uri.scheme != 'https' && uri.scheme != 'http') continue;
    if (uri.host.isEmpty || uri.toString().length > maxPreviewUrlLength) {
      continue;
    }
    return uri;
  }
  return null;
}
