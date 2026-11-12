import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;

/// What a Matrix permalink points at.
enum PermalinkKind { user, room, event }

/// A parsed `https://matrix.to/#/…` or `matrix:` link.
@immutable
class MatrixPermalink {
  const MatrixPermalink({
    required this.kind,
    required this.identifier,
    required this.uri,
    this.eventId,
    this.via = const [],
  });

  final PermalinkKind kind;

  /// User ID, room ID or room alias.
  final String identifier;

  /// Event ID for [PermalinkKind.event].
  final String? eventId;
  final List<String> via;

  /// The original link.
  final Uri uri;

  bool get isUser => kind == PermalinkKind.user;

  /// Parses matrix.to and `matrix:` URIs. Returns null for anything else or
  /// for malformed identifiers.
  static MatrixPermalink? parse(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if ((scheme == 'https' || scheme == 'http') &&
        uri.host.toLowerCase() == 'matrix.to') {
      return _parseMatrixTo(uri);
    }
    if (scheme == 'matrix') return _parseMatrixUri(uri);
    return null;
  }

  static MatrixPermalink? _parseMatrixTo(Uri uri) {
    var fragment = uri.fragment;
    if (!fragment.startsWith('/')) return null;
    var query = '';
    final queryStart = fragment.indexOf('?');
    if (queryStart >= 0) {
      query = fragment.substring(queryStart + 1);
      fragment = fragment.substring(0, queryStart);
    }
    final segments = fragment
        .substring(1)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(_decode)
        .toList();
    if (segments.isEmpty || segments.contains(null)) return null;
    final ids = segments.cast<String>();
    final via = _via(query);
    return _fromIdentifiers(
      ids.first,
      ids.length > 1 ? ids[1] : null,
      uri,
      via,
    );
  }

  static MatrixPermalink? _parseMatrixUri(Uri uri) {
    final segments = uri.path.split('/').map(_decode).toList();
    if (segments.length < 2 || segments.contains(null)) return null;
    final parts = segments.cast<String>();
    final sigil = switch (parts[0]) {
      'u' => '@',
      'r' => '#',
      'roomid' => '!',
      _ => null,
    };
    if (sigil == null) return null;
    String? event;
    if (parts.length >= 4 && parts[2] == 'e') event = '\$${parts[3]}';
    return _fromIdentifiers(
      '$sigil${parts[1]}',
      event,
      uri,
      uri.queryParametersAll['via'] ?? const [],
    );
  }

  static MatrixPermalink? _fromIdentifiers(
    String identifier,
    String? second,
    Uri uri,
    List<String> via,
  ) {
    if (!identifier.isValidMatrixIdStrict()) return null;
    switch (identifier[0]) {
      case '@':
        return MatrixPermalink(
          kind: PermalinkKind.user,
          identifier: identifier,
          uri: uri,
        );
      case '!':
      case '#':
        if (second != null && second.startsWith('\$')) {
          return MatrixPermalink(
            kind: PermalinkKind.event,
            identifier: identifier,
            eventId: second,
            uri: uri,
            via: via,
          );
        }
        return MatrixPermalink(
          kind: PermalinkKind.room,
          identifier: identifier,
          uri: uri,
          via: via,
        );
      default:
        return null;
    }
  }

  static String? _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return null;
    }
  }

  static List<String> _via(String query) {
    if (query.isEmpty) return const [];
    final servers = <String>[];
    for (final pair in query.split('&')) {
      final equals = pair.indexOf('=');
      if (equals < 0 || pair.substring(0, equals) != 'via') continue;
      try {
        final server = Uri.decodeQueryComponent(pair.substring(equals + 1));
        if (server.isNotEmpty) servers.add(server);
      } catch (_) {}
    }
    return servers;
  }
}

String _encodeId(String id) => Uri.encodeComponent(
  id,
).replaceAll('%3A', ':').replaceAll('%40', '@').replaceAll('%24', '\$');

/// `https://matrix.to/#/@user:server`.
String userPermalink(String userId) =>
    'https://matrix.to/#/${_encodeId(userId)}';

/// `https://matrix.to/#/<room>/<event>?via=…`, as Element X's "Copy link".
String eventPermalink(
  String roomId,
  String eventId, {
  List<String> via = const [],
}) {
  final base = 'https://matrix.to/#/${_encodeId(roomId)}/${_encodeId(eventId)}';
  if (via.isEmpty) return base;
  return '$base?${via.map((server) => 'via=${Uri.encodeQueryComponent(server)}').join('&')}';
}

/// Schemes the timeline may open. Everything else is rendered as plain text.
const safeLinkSchemes = {'http', 'https', 'mailto', 'geo', 'matrix'};

/// Returns the URI to open for [href], or null when the link is unsafe.
Uri? safeLinkUri(String href) {
  final trimmed = href.trim();
  if (trimmed.isEmpty || trimmed.length > 4096) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if (!safeLinkSchemes.contains(scheme)) return null;
  if ((scheme == 'http' || scheme == 'https') && uri.host.isEmpty) {
    return null;
  }
  if ((scheme == 'mailto' || scheme == 'geo' || scheme == 'matrix') &&
      uri.path.isEmpty) {
    return null;
  }
  return uri;
}

/// Whether the visible text of a link looks like a different destination
/// than its target, so the user should confirm (Element X "Double-check this
/// link").
bool linkTextMisleads(String text, Uri target) {
  final visible = text.trim();
  if (visible.isEmpty) return false;
  final looksLikeUrl = RegExp(
    r'^(?:[a-z][a-z0-9+.-]*://)?(?:www\.)?[^\s/]+\.[a-z]{2,}(?:[/?#]\S*)?$',
    caseSensitive: false,
  ).hasMatch(visible);
  if (!looksLikeUrl) return false;
  final parsed = Uri.tryParse(
    visible.contains('://') ? visible : 'https://$visible',
  );
  if (parsed == null || parsed.host.isEmpty) return true;
  String bare(String host) =>
      host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  return bare(parsed.host) != bare(target.host);
}
