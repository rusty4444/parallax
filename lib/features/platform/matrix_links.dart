// Parsing for Matrix permalinks: https://matrix.to/#/… (MSC1704), Element
// web style links (…/#/room/…, …/#/user/…) and `matrix:` URIs (MSC2312).
//
// Pure functions only: no network, no SDK state. Everything here treats the
// input as untrusted and fails closed (returns null) on anything unexpected.
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;

/// Maximum number of `via` servers kept from a link.
const maxLinkViaServers = 10;

/// Maximum accepted length of a link, before parsing.
const maxMatrixLinkLength = 4096;

/// A Matrix entity referenced by a link.
@immutable
sealed class MatrixLink {
  const MatrixLink({this.action});

  /// MSC2312 `action` hint (`join` or `chat`), if present and recognised.
  final String? action;
}

/// A link to a user (`@alice:example.org`).
@immutable
final class MatrixUserLink extends MatrixLink {
  const MatrixUserLink(this.userId, {super.action});
  final String userId;

  @override
  bool operator ==(Object other) =>
      other is MatrixUserLink &&
      other.userId == userId &&
      other.action == action;

  @override
  int get hashCode => Object.hash(userId, action);

  @override
  String toString() => 'MatrixUserLink($userId, action: $action)';
}

/// A link to a room by ID (`!id:server`) or alias (`#alias:server`), optionally
/// to one event in it.
@immutable
final class MatrixRoomLink extends MatrixLink {
  const MatrixRoomLink(
    this.roomIdOrAlias, {
    this.eventId,
    this.via = const [],
    super.action,
  });
  final String roomIdOrAlias;
  final String? eventId;

  /// Servers that can be used to reach the room when it is not yet known.
  final List<String> via;

  bool get isAlias => roomIdOrAlias.startsWith('#');

  @override
  bool operator ==(Object other) =>
      other is MatrixRoomLink &&
      other.roomIdOrAlias == roomIdOrAlias &&
      other.eventId == eventId &&
      listEquals(other.via, via) &&
      other.action == action;

  @override
  int get hashCode =>
      Object.hash(roomIdOrAlias, eventId, Object.hashAll(via), action);

  @override
  String toString() =>
      'MatrixRoomLink($roomIdOrAlias, event: $eventId, via: $via, '
      'action: $action)';
}

/// Whether [uri] looks like a link this module handles, without validating
/// the identifiers. Use it to decide whether to intercept a tap at all.
bool isMatrixLinkCandidate(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'matrix') return true;
  if (scheme != 'https' && scheme != 'http') return false;
  if (_isMatrixToHost(uri.host)) return true;
  final fragment = uri.fragment;
  return fragment.startsWith('/room/') || fragment.startsWith('/user/');
}

/// Parses a permalink string. Returns null for anything that is not a valid
/// Matrix user/room/event link.
MatrixLink? parseMatrixLinkString(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.length > maxMatrixLinkLength) return null;
  final uri = Uri.tryParse(value);
  return uri == null ? null : parseMatrixLink(uri);
}

/// Parses a permalink. Returns null for anything that is not a valid Matrix
/// user/room/event link.
MatrixLink? parseMatrixLink(Uri uri) {
  try {
    if (uri.toString().length > maxMatrixLinkLength) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'matrix') return _parseMatrixUri(uri);
    if (scheme != 'https' && scheme != 'http') return null;
    if (uri.userInfo.isNotEmpty) return null;
    final fragment = uri.fragment;
    if (_isMatrixToHost(uri.host)) {
      // https://matrix.to/#/<identifier>[/<event>][?via=…]
      if (!fragment.startsWith('/')) return null;
      return _parseFragment(fragment.substring(1));
    }
    // Element web/desktop style: https://app.element.io/#/room/#a:b,
    // https://example.org/#/user/@a:b. Same rules as Element X's converter.
    for (final prefix in const ['/room/', '/user/']) {
      if (fragment.startsWith(prefix)) {
        return _parseFragment(fragment.substring(prefix.length));
      }
    }
    return null;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

bool _isMatrixToHost(String host) {
  final value = host.toLowerCase();
  return value == 'matrix.to' || value == 'www.matrix.to';
}

MatrixLink? _parseFragment(String fragment) {
  final queryStart = fragment.indexOf('?');
  final path = queryStart == -1 ? fragment : fragment.substring(0, queryStart);
  final query = queryStart == -1 ? '' : fragment.substring(queryStart + 1);
  final params = _queryParameters(query);
  final rawSegments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (rawSegments.isEmpty) return null;
  final segments = [for (final s in rawSegments) Uri.decodeComponent(s)];
  final primary = segments.first;
  final action = _action(params);
  if (primary.startsWith('@')) {
    // Historic user IDs may contain '/', which Element X also accepts.
    final userId = segments.join('/');
    return _validUser(userId) ? MatrixUserLink(userId, action: action) : null;
  }
  if (!primary.startsWith('#') && !primary.startsWith('!')) return null;
  if (segments.length > 2) return null;
  final eventId = segments.length == 2 ? segments[1] : null;
  return _roomLink(primary, eventId, params, action);
}

MatrixLink? _parseMatrixUri(Uri uri) {
  // MSC2312: matrix:u/alice:example.org, matrix:r/room:example.org,
  // matrix:roomid/opaque:example.org/e/event?via=…&action=join.
  if (uri.hasAuthority || uri.hasFragment) return null;
  final segments = uri.pathSegments;
  if (segments.length != 2 && segments.length != 4) return null;
  final params = _queryParameters(uri.query);
  final action = _action(params);
  final kind = segments[0].toLowerCase();
  final id = segments[1];
  if (id.isEmpty) return null;
  String? eventId;
  if (segments.length == 4) {
    final eventKind = segments[2].toLowerCase();
    if (eventKind != 'e' && eventKind != 'event') return null;
    if (segments[3].isEmpty) return null;
    eventId = '\$${segments[3]}';
  }
  switch (kind) {
    case 'u' || 'user':
      if (eventId != null) return null;
      final userId = '@$id';
      return _validUser(userId) ? MatrixUserLink(userId, action: action) : null;
    case 'r' || 'room':
      return _roomLink('#$id', eventId, params, action);
    case 'roomid':
      return _roomLink('!$id', eventId, params, action);
    default:
      return null;
  }
}

MatrixRoomLink? _roomLink(
  String roomIdOrAlias,
  String? eventId,
  Map<String, List<String>> params,
  String? action,
) {
  if (!_validRoom(roomIdOrAlias)) return null;
  if (eventId != null && !_validEvent(eventId)) return null;
  final via = <String>[];
  for (final server in params['via'] ?? const <String>[]) {
    final value = server.trim();
    if (_validServerName(value) && !via.contains(value)) via.add(value);
    if (via.length >= maxLinkViaServers) break;
  }
  return MatrixRoomLink(
    roomIdOrAlias,
    eventId: eventId,
    via: List.unmodifiable(via),
    action: action,
  );
}

String? _action(Map<String, List<String>> params) {
  final value = params['action']?.firstOrNull?.toLowerCase();
  return value == 'join' || value == 'chat' ? value : null;
}

Map<String, List<String>> _queryParameters(String query) {
  if (query.isEmpty) return const {};
  try {
    return Uri(query: query).queryParametersAll;
  } on FormatException {
    return const {};
  }
}

bool _noWhitespace(String value) =>
    !value.contains(RegExp(r'[\s\u0000-\u001f\u007f]'));

bool _validUser(String value) =>
    value.length > 3 &&
    value.startsWith('@') &&
    _noWhitespace(value) &&
    value.indexOf(':') > 1 &&
    value.isValidMatrixIdStrict(strictDomainCheck: true);

bool _validRoom(String value) {
  if (value.length < 2 || !_noWhitespace(value)) return false;
  if (value.startsWith('#')) {
    return value.indexOf(':') > 1 &&
        value.isValidMatrixIdStrict(strictDomainCheck: true);
  }
  if (value.startsWith('!')) {
    // Room version 12 room IDs have no server name; older ones do.
    return value.isValidMatrixIdStrict(strictDomainCheck: true);
  }
  return false;
}

bool _validEvent(String value) =>
    value.length > 1 &&
    value.startsWith('\$') &&
    _noWhitespace(value) &&
    value.isValidMatrixIdStrict(strictDomainCheck: true);

bool _validServerName(String value) {
  if (value.isEmpty || value.length > 255 || !_noWhitespace(value)) {
    return false;
  }
  // Reuse the SDK's server-name grammar through a synthetic alias.
  return '#x:$value'.isValidMatrixIdStrict(strictDomainCheck: true);
}

/// Builds a matrix.to permalink, for sharing a room or user.
Uri matrixToLink(String identifier, {String? eventId, List<String>? via}) {
  final buffer = StringBuffer('https://matrix.to/#/')
    ..write(Uri.encodeComponent(identifier));
  if (eventId != null) buffer.write('/${Uri.encodeComponent(eventId)}');
  final servers = via ?? const <String>[];
  if (servers.isNotEmpty) {
    buffer.write('?');
    buffer.write(
      servers.map((s) => 'via=${Uri.encodeQueryComponent(s)}').join('&'),
    );
  }
  return Uri.parse(buffer.toString());
}
