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

/// What a page's Open Graph tags say about it.
@immutable
class LinkPreview {
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.image,
  });

  /// The link as sent in the message (what tapping opens).
  final Uri url;
  final String? title;
  final String? description;
  final String? siteName;

  /// `mxc://` URI of the page's image, hosted by the homeserver.
  final Uri? image;

  /// Nothing worth showing: no title, text or image.
  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (description == null || description!.isEmpty) &&
      image == null;

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

    final image = Uri.tryParse(text('image') ?? '');
    return LinkPreview(
      url: url,
      title: text('title'),
      description: text('description'),
      siteName: text('siteName'),
      image: image != null && image.scheme == 'mxc' ? image : null,
    );
  }
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
