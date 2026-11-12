// Models and pure helpers for the Space administration module.
//
// Everything here is free of SDK and widget dependencies so the Space graph
// rules (child validity, spec ordering, order-string generation, last-admin
// checks) can be unit tested directly.
import 'package:flutter/foundation.dart';

import '../../room_details.dart';
import '../rooms_admin/rooms_admin_models.dart' show PickedImage;

/// `m.space.child` / `m.space.parent` state event types.
const spaceChildType = 'm.space.child';
const spaceParentType = 'm.space.parent';

/// Upper bounds for user-controlled Space graphs.
const maxSpaceChildrenPerWrite = 100;
const maxAuthorisedSpaces = 50;
const maxSpaceChildOrderLength = 50;

/// A Space as offered in pickers.
@immutable
class SpaceRef {
  const SpaceRef({required this.id, required this.name, this.avatarUrl});
  final String id;
  final String name;
  final Uri? avatarUrl;
}

/// A joined room that may be added to a Space.
@immutable
class SpaceRoomCandidate {
  const SpaceRoomCandidate({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.alias,
    this.members = 0,
  });
  final String id;
  final String name;
  final Uri? avatarUrl;
  final String? alias;
  final int members;
}

/// One `m.space.child` state event as read from the server.
@immutable
class SpaceStateEvent {
  const SpaceStateEvent({
    required this.stateKey,
    required this.content,
    this.timestamp = 0,
  });
  final String stateKey;
  final Map<String, Object?> content;

  /// `origin_server_ts` in milliseconds (spec tie-break for equal orders).
  final int timestamp;
}

/// Spec: an `order` is 1–50 printable ASCII characters (0x20–0x7E). Invalid
/// orders are ignored, so the child sorts with the unordered children.
bool isValidSpaceChildOrder(Object? order) =>
    order is String &&
    order.isNotEmpty &&
    order.length <= maxSpaceChildOrderLength &&
    order.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7E);

/// Server names from an untrusted `via` list (non-empty strings, bounded).
List<String> sanitisedVia(Object? via) => [
  if (via is List)
    for (final server in via)
      if (server is String &&
          server.isNotEmpty &&
          server.length <= 255 &&
          !server.contains(RegExp(r'[\s/@#!]')))
        server,
].take(10).toList(growable: false);

/// A child of a Space with the display data the management screens need.
@immutable
class SpaceChildEntry {
  const SpaceChildEntry({
    required this.roomId,
    required this.via,
    this.order,
    this.suggested = false,
    this.timestamp = 0,
    this.content = const {},
    this.name,
    this.topic,
    this.avatarUrl,
    this.members,
    this.joined = false,
    this.isSpace = false,
    this.isDirect = false,
  });

  final String roomId;
  final List<String> via;

  /// The valid `order`, or null when absent/invalid.
  final String? order;
  final bool suggested;
  final int timestamp;

  /// Raw event content, kept so writes only change the intended keys.
  final Map<String, Object?> content;

  final String? name;
  final String? topic;
  final Uri? avatarUrl;
  final int? members;
  final bool joined;
  final bool isSpace;
  final bool isDirect;

  String get label =>
      (name?.trim().isNotEmpty ?? false) ? name!.trim() : roomId;

  SpaceChildEntry withDisplay({
    String? name,
    String? topic,
    Uri? avatarUrl,
    int? members,
    bool? joined,
    bool? isSpace,
    bool? isDirect,
  }) => SpaceChildEntry(
    roomId: roomId,
    via: via,
    order: order,
    suggested: suggested,
    timestamp: timestamp,
    content: content,
    name: name ?? this.name,
    topic: topic ?? this.topic,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    members: members ?? this.members,
    joined: joined ?? this.joined,
    isSpace: isSpace ?? this.isSpace,
    isDirect: isDirect ?? this.isDirect,
  );
}

/// Spec ordering of Space children: valid `order` first (lexicographic),
/// then the rest; ties by `origin_server_ts`, then room ID.
int compareSpaceChildren(SpaceChildEntry a, SpaceChildEntry b) {
  final left = a.order;
  final right = b.order;
  if (left != null && right != null) {
    final order = left.compareTo(right);
    if (order != 0) return order;
  } else if (left != null) {
    return -1;
  } else if (right != null) {
    return 1;
  }
  final time = a.timestamp.compareTo(b.timestamp);
  return time != 0 ? time : a.roomId.compareTo(b.roomId);
}

/// Valid children from `m.space.child` events, in spec order. A child needs a
/// room ID state key and a non-empty `via`; empty content means removed.
List<SpaceChildEntry> spaceChildrenFromState(Iterable<SpaceStateEvent> events) {
  final children = <String, SpaceChildEntry>{};
  for (final event in events) {
    final id = event.stateKey;
    if (!id.startsWith('!') || id.length > 255) continue;
    final via = sanitisedVia(event.content['via']);
    if (via.isEmpty) continue;
    final order = event.content['order'];
    children[id] = SpaceChildEntry(
      roomId: id,
      via: via,
      order: isValidSpaceChildOrder(order) ? order as String : null,
      suggested: event.content['suggested'] == true,
      timestamp: event.timestamp,
      content: Map.unmodifiable(event.content),
    );
  }
  return children.values.toList()..sort(compareSpaceChildren);
}

/// A Space's fresh server state as needed by the management screens.
@immutable
class SpaceGraph {
  const SpaceGraph({required this.details, required this.children});

  /// Fresh `/state` projection: name, avatar, power levels, join rule.
  final RoomDetails details;

  /// Valid children in spec order.
  final List<SpaceChildEntry> children;

  String get spaceId => details.roomId;

  /// Element X `canEditSpaceGraph`.
  bool get canEditChildren => details.canSendState(spaceChildType);

  SpaceChildEntry? child(String roomId) =>
      children.where((child) => child.roomId == roomId).firstOrNull;
}

// --- Order strings ---------------------------------------------------------

final _base = BigInt.from(0x7E - 0x20 + 1); // 95 printable characters.

BigInt _orderValue(String order, int width) {
  var value = BigInt.zero;
  for (var i = 0; i < width; i++) {
    final digit = i < order.length ? order.codeUnitAt(i) - 0x20 : 0;
    value = value * _base + BigInt.from(digit);
  }
  return value;
}

String _orderString(BigInt value, int width) {
  final units = List<int>.filled(width, 0x20);
  var rest = value;
  for (var i = width - 1; i >= 0; i--) {
    units[i] = 0x20 + (rest % _base).toInt();
    rest = rest ~/ _base;
  }
  var end = width;
  // Trailing spaces are the lowest digit: dropping them keeps the ordering.
  while (end > 1 && units[end - 1] == 0x20) {
    end--;
  }
  return String.fromCharCodes(units.sublist(0, end));
}

/// An order string strictly between [lower] ('' for the start) and [upper]
/// (null for the end), or null when none fits in 50 characters.
String? orderBetween(String lower, String? upper) {
  if (upper != null && lower.compareTo(upper) >= 0) return null;
  final start = [
    lower.length,
    upper?.length ?? 0,
  ].reduce((a, b) => a > b ? a : b);
  for (var width = start + 1; width <= maxSpaceChildOrderLength; width++) {
    final low = _orderValue(lower, width);
    final high = upper == null ? _base.pow(width) : _orderValue(upper, width);
    if (high - low < BigInt.two) continue;
    final candidate = _orderString((low + high) ~/ BigInt.two, width);
    if (candidate.compareTo(lower) > 0 &&
        (upper == null || candidate.compareTo(upper) < 0) &&
        isValidSpaceChildOrder(candidate)) {
      return candidate;
    }
  }
  return null;
}

/// [count] strictly increasing, evenly spaced order strings.
List<String> evenlySpacedOrders(int count) {
  if (count <= 0) return const [];
  var width = 1;
  while (_base.pow(width) <= BigInt.from(count + 1)) {
    width++;
  }
  final total = _base.pow(width);
  return [
    for (var i = 1; i <= count; i++)
      _orderString(total * BigInt.from(i) ~/ BigInt.from(count + 1), width),
  ];
}

/// Most `order` rewrites one move may cause.
const maxReorderWrites = 200;

/// New `order` values that move [roomId] to [toIndex] among [sorted]
/// (children in spec order). Usually one write: a midpoint between the new
/// neighbours. When there is no room, or unordered children precede the new
/// position, the prefix up to the move is renumbered.
Map<String, String> planSpaceChildMove(
  List<SpaceChildEntry> sorted,
  String roomId,
  int toIndex,
) {
  final from = sorted.indexWhere((child) => child.roomId == roomId);
  if (from < 0) throw ArgumentError.value(roomId, 'roomId', 'Not a child');
  final target = toIndex.clamp(0, sorted.length - 1);
  if (target == from) return const {};
  final desired = [...sorted]..removeAt(from);
  desired.insert(target, sorted[from]);
  final prefixOrdered = desired
      .take(target)
      .every((child) => child.order != null);
  if (prefixOrdered) {
    final lower = target == 0 ? '' : desired[target - 1].order!;
    final upper = target + 1 < desired.length
        ? desired[target + 1].order
        : null;
    final order = orderBetween(lower, upper);
    if (order != null) return {roomId: order};
  }
  final lastOrdered = desired.lastIndexWhere((child) => child.order != null);
  final end = target > lastOrdered ? target : lastOrdered;
  if (end + 1 > maxReorderWrites) {
    throw StateError('Too many rooms to reorder');
  }
  final orders = evenlySpacedOrders(end + 1);
  return {
    for (var i = 0; i <= end; i++)
      if (desired[i].order != orders[i]) desired[i].roomId: orders[i],
  };
}

// --- Creation --------------------------------------------------------------

/// Who may join a new Space or a new room inside a Space.
enum SpaceCreationAccess {
  /// Invite only.
  private,

  /// Knock (anyone can ask to join).
  askToJoin,

  /// Public, with an address.
  public,

  /// Rooms in a Space: members of the parent Space can join (`restricted`).
  spaceMembers,

  /// Rooms in a Space: Space members join directly, everyone else knocks
  /// (`knock_restricted`).
  askToJoinSpaceMembers,
}

extension SpaceCreationAccessRules on SpaceCreationAccess {
  /// Published in the directory with an address.
  bool get needsAddress =>
      this == SpaceCreationAccess.public ||
      this == SpaceCreationAccess.askToJoin;

  /// Element X encrypts every room that is not publicly visible.
  bool get encryptedRoom => !needsAddress;

  String? get joinRule => switch (this) {
    SpaceCreationAccess.private => null,
    SpaceCreationAccess.public => null,
    SpaceCreationAccess.askToJoin => 'knock',
    SpaceCreationAccess.spaceMembers => 'restricted',
    SpaceCreationAccess.askToJoinSpaceMembers => 'knock_restricted',
  };

  /// Minimum room version for the join rule.
  int get minimumRoomVersion => switch (this) {
    SpaceCreationAccess.askToJoin => 7,
    SpaceCreationAccess.spaceMembers => 8,
    SpaceCreationAccess.askToJoinSpaceMembers => 10,
    _ => 1,
  };
}

@immutable
class SpaceCreationOptions {
  const SpaceCreationOptions({
    required this.name,
    this.topic = '',
    this.access = SpaceCreationAccess.private,
    this.aliasLocalpart,
    this.avatar,
  });
  final String name;
  final String topic;
  final SpaceCreationAccess access;
  final String? aliasLocalpart;
  final PickedImage? avatar;
}

/// Picks a stable room version that supports [minimum], or null to keep the
/// server default. [available] maps version → "stable"/"unstable".
String? roomVersionFor(
  int minimum,
  String? serverDefault,
  Map<String, String> available,
) {
  final current = int.tryParse(serverDefault ?? '');
  if (minimum <= 1 || current == null || current >= minimum) return null;
  final stable = [
    for (final entry in available.entries)
      if (entry.value == 'stable' && (int.tryParse(entry.key) ?? 0) >= minimum)
        int.parse(entry.key),
  ]..sort();
  if (stable.isEmpty) {
    throw StateError('The server does not support this join rule');
  }
  return '${stable.last}';
}

// --- Leaving ---------------------------------------------------------------

/// A joined room inside a Space the user may leave along with it.
@immutable
class LeaveSpaceRoom {
  const LeaveSpaceRoom({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.members = 0,
    this.lastAdmin = false,
    this.isSpace = false,
  });
  final String id;
  final String name;
  final Uri? avatarUrl;
  final int members;

  /// The user is the only administrator and others are joined: Element X
  /// keeps such rooms out of the selection.
  final bool lastAdmin;
  final bool isSpace;
}

@immutable
class LeaveSpacePlan {
  const LeaveSpacePlan({
    required this.spaceId,
    required this.spaceName,
    required this.details,
    required this.lastAdmin,
    required this.rooms,
  });
  final String spaceId;
  final String spaceName;

  /// Fresh state of the Space itself (for "Choose admins").
  final RoomDetails details;

  /// The user is the Space's only administrator and others are joined.
  final bool lastAdmin;
  final List<LeaveSpaceRoom> rooms;

  List<LeaveSpaceRoom> get selectable => [
    for (final room in rooms)
      if (!room.lastAdmin) room,
  ];
  List<LeaveSpaceRoom> get adminRooms => [
    for (final room in rooms)
      if (room.lastAdmin) room,
  ];
}

/// Leaving stopped at [roomId]; [left] were already left.
class LeaveSpaceFailure implements Exception {
  const LeaveSpaceFailure(this.roomId, this.left);
  final String roomId;
  final List<String> left;
}

/// Whether [userId] can administer the room (power level 100+, or a v12+
/// creator, who outranks everyone).
bool isPrivileged(RoomDetails details, String userId) =>
    details.creatorsOutrank && details.creators.contains(userId) ||
    details.powerOf(userId) >= 100;

/// Users other than [userId] who could administer the room according to
/// its power levels (membership still has to be checked).
List<String> otherPrivilegedCandidates(RoomDetails details, String userId) {
  final users = details.powerLevels?['users'];
  final candidates = <String>{};
  if (users is Map) {
    for (final MapEntry(:key, :value) in users.entries) {
      if (key is String && value is int && value >= 100) candidates.add(key);
    }
  }
  if (details.creatorsOutrank) candidates.addAll(details.creators);
  return candidates.where((id) => id != userId).take(20).toList();
}

// --- Authorised spaces -----------------------------------------------------

/// Spaces offered for a room's "Space members" access (Element X: joined
/// parents plus Spaces already authorised).
@immutable
class AuthorisedSpaces {
  const AuthorisedSpaces({required this.selectable, required this.unknown});

  /// Joined Spaces that may be picked.
  final List<SpaceRef> selectable;

  /// Authorised Space IDs the user has not joined.
  final List<String> unknown;

  int get count => selectable.length + unknown.length;

  String? nameOf(String id) =>
      selectable.where((space) => space.id == id).firstOrNull?.name;
}

/// `knock_restricted` needs room version 10 or later.
bool supportsKnockRestricted(RoomDetails details) =>
    (int.tryParse(details.roomVersion) ?? 1) >= 10;

/// `m.room.join_rules` content for Space-member access.
Map<String, Object?> spaceMemberJoinRules(
  List<String> spaceIds, {
  required bool askToJoin,
}) => {
  'join_rule': askToJoin ? 'knock_restricted' : 'restricted',
  'allow': [
    for (final id in spaceIds) {'type': 'm.room_membership', 'room_id': id},
  ],
};
