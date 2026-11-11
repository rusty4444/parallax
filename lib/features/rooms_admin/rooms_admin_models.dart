// Pure data and rules for the room administration module. Nothing here talks
// to the network, so it is shared by the Matrix implementation, the UI and
// the tests.

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;

/// Per-room notification mode, as in Element X.
enum RoomNotificationMode { allMessages, mentionsAndKeywords, mute }

extension RoomNotificationModeLabel on RoomNotificationMode {
  String get label => switch (this) {
    RoomNotificationMode.allMessages => 'All messages',
    RoomNotificationMode.mentionsAndKeywords => 'Mentions and keywords only',
    RoomNotificationMode.mute => 'Mute',
  };
}

@immutable
class RoomNotificationSettings {
  const RoomNotificationSettings({required this.defaultMode, this.customMode});

  /// What the account-wide rules give this kind of room.
  final RoomNotificationMode defaultMode;

  /// A room-specific override, or null when the room follows the default.
  final RoomNotificationMode? customMode;

  bool get isDefault => customMode == null;
  RoomNotificationMode get effectiveMode => customMode ?? defaultMode;
}

bool _notifies(Object? actions) =>
    actions is List && actions.any((action) => action == 'notify');

Map<String, Object?>? _rule(Object? rules, String ruleId) {
  if (rules is! List) return null;
  for (final rule in rules) {
    if (rule is Map && rule['rule_id'] == ruleId) {
      return Map<String, Object?>.from(rule);
    }
  }
  return null;
}

/// The room-specific mode from a `/pushrules/` `global` ruleset, mirroring
/// the Rust SDK: an enabled non-notifying `override` rule (id = room ID,
/// matching `room_id`) mutes; an enabled `room` rule sets all messages when
/// it notifies and mentions/keywords otherwise.
RoomNotificationMode? userDefinedNotificationMode(
  Map<String, Object?> ruleset,
  String roomId,
) {
  final override = _rule(ruleset['override'], roomId);
  if (override != null && override['enabled'] != false) {
    final conditions = override['conditions'];
    final matchesRoom =
        conditions is List &&
        conditions.length == 1 &&
        conditions.first is Map &&
        (conditions.first as Map)['key'] == 'room_id' &&
        (conditions.first as Map)['pattern'] == roomId;
    if (matchesRoom && !_notifies(override['actions'])) {
      return RoomNotificationMode.mute;
    }
  }
  final room = _rule(ruleset['room'], roomId);
  if (room != null && room['enabled'] != false) {
    return _notifies(room['actions'])
        ? RoomNotificationMode.allMessages
        : RoomNotificationMode.mentionsAndKeywords;
  }
  return null;
}

/// The account default for a room of this kind (from the server-default
/// `underride` rules, as the Rust SDK does).
RoomNotificationMode defaultNotificationMode(
  Map<String, Object?> ruleset, {
  required bool encrypted,
  required bool oneToOne,
}) {
  final id = switch ((oneToOne, encrypted)) {
    (true, true) => '.m.rule.encrypted_room_one_to_one',
    (true, false) => '.m.rule.room_one_to_one',
    (false, true) => '.m.rule.encrypted',
    (false, false) => '.m.rule.message',
  };
  final rule = _rule(ruleset['underride'], id);
  if (rule == null) return RoomNotificationMode.allMessages;
  return rule['enabled'] != false && _notifies(rule['actions'])
      ? RoomNotificationMode.allMessages
      : RoomNotificationMode.mentionsAndKeywords;
}

/// What a room preview (summary or hierarchy) told us about a room that we
/// may not have joined.
@immutable
class RoomPreview {
  const RoomPreview({
    required this.roomId,
    this.name,
    this.topic,
    this.alias,
    this.avatarUrl,
    this.memberCount,
    this.joinRule,
    this.membership,
    this.isSpace = false,
    this.via = const [],
  });
  final String roomId;
  final String? name;
  final String? topic;
  final String? alias;
  final Uri? avatarUrl;
  final int? memberCount;

  /// public, invite, knock, restricted, knock_restricted or null (unknown).
  final String? joinRule;

  /// The current user's membership (join, invite, knock, ban, leave …).
  final String? membership;
  final bool isSpace;
  final List<String> via;

  String get displayName =>
      name?.trim().isNotEmpty == true ? name!.trim() : alias ?? roomId;

  bool get canKnock => joinRule == 'knock' || joinRule == 'knock_restricted';
  bool get joined => membership == 'join';
  bool get invited => membership == 'invite';
  bool get banned => membership == 'ban';
  bool get knocked => membership == 'knock';
}

/// A parsed "join by address" input.
@immutable
class RoomAddress {
  const RoomAddress(this.idOrAlias, {this.via = const []});
  final String idOrAlias;
  final List<String> via;
  bool get isAlias => idOrAlias.startsWith('#');
}

final _serverName = RegExp(
  r'^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?$',
);

/// True for `#localpart:server` (or `!opaque:server`) with a valid server name.
bool isValidRoomAddress(String value) {
  if (value.length > 255 || value.contains(RegExp(r'\s'))) return false;
  if (!value.startsWith('#') && !value.startsWith('!')) return false;
  final colon = value.indexOf(':');
  if (colon < 2 || colon == value.length - 1) return false;
  return _serverName.hasMatch(value.substring(colon + 1));
}

/// Accepts `#alias:server`, `!room:server`, `https://matrix.to/#/…` and
/// `matrix:r/…`/`matrix:roomid/…` links. Returns null for anything else.
RoomAddress? parseRoomAddress(String input) {
  try {
    return _parseRoomAddress(input);
  } on ArgumentError {
    return null; // Malformed percent-encoding.
  } on FormatException {
    return null;
  }
}

RoomAddress? _parseRoomAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  final via = <String>[];
  if (text.startsWith('https://matrix.to/#/')) {
    final fragment = text.substring('https://matrix.to/#/'.length);
    final query = fragment.indexOf('?');
    final id = Uri.decodeComponent(
      query < 0 ? fragment : fragment.substring(0, query),
    );
    if (query >= 0) {
      // Uri.splitQueryString keeps only the last of repeated keys.
      via.addAll(
        fragment
            .substring(query + 1)
            .split('&')
            .where((part) => part.startsWith('via='))
            .map((part) => Uri.decodeComponent(part.substring(4))),
      );
    }
    text = id.split('/').first;
  } else if (text.startsWith('matrix:')) {
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    final segments = uri.path.split('/');
    if (segments.length < 2) return null;
    final body = Uri.decodeComponent(segments[1]);
    text = switch (segments.first) {
      'r' => '#$body',
      'roomid' => '!$body',
      _ => '',
    };
    via.addAll(uri.queryParametersAll['via'] ?? const []);
  }
  if (!isValidRoomAddress(text)) return null;
  return RoomAddress(
    text,
    via: List.unmodifiable(via.where(_serverName.hasMatch).take(10)),
  );
}

/// Element X's alias localpart suggestion: lower case, spaces to dashes and
/// only characters that are safe in an alias.
String roomAliasLocalpartFor(String name) => name
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp(r'[^a-z0-9._=\-/]'), '')
    .replaceAll(RegExp(r'-{2,}'), '-');

bool isValidAliasLocalpart(String localpart) =>
    localpart.isNotEmpty &&
    localpart.length <= 200 &&
    !localpart.contains(RegExp(r'[\s:#]'));

String? serverNameOf(String? matrixId) {
  if (matrixId == null) return null;
  final colon = matrixId.indexOf(':');
  return colon < 0 ? null : matrixId.substring(colon + 1);
}

/// `https://matrix.to` link for a user, room ID or alias.
String matrixToLink(String id, {List<String> via = const []}) {
  final encoded = Uri.encodeComponent(id).replaceAll('%3A', ':');
  final query = via.isEmpty
      ? ''
      : '?${via.map((server) => 'via=${Uri.encodeComponent(server)}').join('&')}';
  return 'https://matrix.to/#/$encoded$query';
}

bool isValidUserId(String value) =>
    value.startsWith('@') &&
    value.indexOf(':') > 1 &&
    value.isValidMatrixIdStrict(strictDomainCheck: true);

enum RoomVisibilityOption { private, public }

/// Element X ConfigureRoom choices.
@immutable
class RoomCreationOptions {
  const RoomCreationOptions({
    required this.name,
    this.topic = '',
    this.visibility = RoomVisibilityOption.private,
    this.askToJoin = false,
    this.aliasLocalpart,
    this.avatar,
  });
  final String name;
  final String topic;
  final RoomVisibilityOption visibility;
  final bool askToJoin;

  /// Address localpart for public rooms (published in the directory).
  final String? aliasLocalpart;
  final PickedImage? avatar;

  bool get isPublic => visibility == RoomVisibilityOption.public;

  /// Private rooms are always encrypted, public ones never (Element X).
  bool get encrypted => !isPublic;
}

@immutable
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.name,
    required this.mimeType,
  });
  final Uint8List bytes;
  final String name;
  final String mimeType;
}

/// Room avatars are small: refuse uploads above this size.
const maxAvatarBytes = 10 * 1024 * 1024;

String imageMimeType(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

enum UserVerification { verified, unverified, unknown }

@immutable
class UserProfileDetails {
  const UserProfileDetails({
    required this.userId,
    this.displayName,
    this.avatarUrl,
  });
  final String userId;
  final String? displayName;
  final Uri? avatarUrl;

  String get label =>
      displayName?.trim().isNotEmpty == true ? displayName!.trim() : userId;
}

/// The server does not implement room reporting (MSC4151 /
/// `POST /rooms/{roomId}/report`).
class ReportRoomUnsupported implements Exception {
  const ReportRoomUnsupported();
  @override
  String toString() => 'Reporting rooms is not supported by this server.';
}

/// One editable power-level setting on the Permissions screen.
@immutable
class PermissionItem {
  const PermissionItem(this.key, this.label, this.fallback, {this.state});

  /// Top-level power-levels key (invite, kick, ban, redact, events_default)
  /// or null for a state event override.
  final String? key;
  final String label;
  final int fallback;

  /// State event type for `events` overrides (m.room.name …).
  final String? state;
}

const permissionSections = <(String, List<PermissionItem>)>[
  (
    'Edit details',
    [
      PermissionItem(null, 'Change name', 50, state: 'm.room.name'),
      PermissionItem(null, 'Change avatar', 50, state: 'm.room.avatar'),
      PermissionItem(null, 'Change topic', 50, state: 'm.room.topic'),
    ],
  ),
  (
    'Messages and content',
    [
      PermissionItem('events_default', 'Send messages', 0),
      PermissionItem('redact', 'Remove messages', 50),
    ],
  ),
  (
    'Manage members',
    [
      PermissionItem('invite', 'Invite people', 0),
      PermissionItem('kick', 'Remove people', 50),
      PermissionItem('ban', 'Ban people', 50),
    ],
  ),
];

int permissionLevel(Map<String, Object?>? levels, PermissionItem item) {
  if (item.state case final type?) {
    final events = levels?['events'];
    if (events is Map && events[type] is int) return events[type] as int;
    final fallback = levels?['state_default'];
    return fallback is int ? fallback : (levels == null ? 0 : 50);
  }
  final value = levels?[item.key];
  return value is int ? value : item.fallback;
}

Map<String, Object?> _copy(Map<String, Object?>? levels) => {
  for (final entry in (levels ?? const <String, Object?>{}).entries)
    entry.key: entry.value is Map
        ? Map<String, Object?>.from(entry.value as Map)
        : entry.value,
};

/// Returns new power-levels content with [item] set to [level], leaving all
/// other keys as read from the server.
Map<String, Object?> withPermissionLevel(
  Map<String, Object?>? levels,
  PermissionItem item,
  int level,
) {
  final next = _copy(levels);
  if (item.state case final type?) {
    final events = (next['events'] as Map<String, Object?>?) ?? {};
    events[type] = level;
    next['events'] = events;
  } else {
    next[item.key!] = level;
  }
  return next;
}

/// Returns new content with each user's level changed. A level equal to
/// `users_default` removes the explicit entry. Room creators in v12+ rooms
/// must never be listed, so callers must exclude them.
Map<String, Object?> withMemberLevels(
  Map<String, Object?>? levels,
  Map<String, int> changes,
) {
  final next = _copy(levels);
  final users = (next['users'] as Map<String, Object?>?) ?? {};
  final defaultLevel = next['users_default'] is int
      ? next['users_default'] as int
      : 0;
  for (final MapEntry(key: userId, value: level) in changes.entries) {
    if (level == defaultLevel) {
      users.remove(userId);
    } else {
      users[userId] = level;
    }
  }
  next['users'] = users;
  return next;
}

/// Element X "Reset permissions": restore the default action levels while
/// keeping user roles and other event overrides.
Map<String, Object?> withDefaultPermissions(Map<String, Object?>? levels) {
  final next = _copy(levels);
  next
    ..['ban'] = 50
    ..['invite'] = 0
    ..['kick'] = 50
    ..['redact'] = 50
    ..['events_default'] = 0
    ..['state_default'] = 50
    ..['users_default'] = 0;
  final events = (next['events'] as Map<String, Object?>?) ?? {};
  for (final type in const ['m.room.name', 'm.room.avatar', 'm.room.topic']) {
    events[type] = 50;
  }
  next['events'] = events;
  return next;
}

String roleLevelLabel(int level) => switch (level) {
  100 => 'Admin',
  50 => 'Moderator',
  0 => 'Member',
  _ => 'Custom ($level)',
};
