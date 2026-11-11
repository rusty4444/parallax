import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;

bool isValidRoomInviteId(String value) =>
    value.startsWith('@') &&
    value.indexOf(':') > 1 &&
    value.isValidMatrixIdStrict(strictDomainCheck: true);

/// A projection of a fresh server /rooms/{id}/state response, not the SDK's
/// lazy-loaded room cache. The server remains the final authority on writes.
enum RoomMemberStatus { joined, invited, banned, knocking }

enum RoomAction { name, topic, invite, kick, ban, unban }

/// Element X role buckets. Owners are v12 creators (or "super admins" at
/// power level 150 and above).
enum RoomRole { owner, admin, moderator, member }

extension RoomRoleLabel on RoomRole {
  String get label => switch (this) {
    RoomRole.owner => 'Owner',
    RoomRole.admin => 'Admin',
    RoomRole.moderator => 'Moderator',
    RoomRole.member => 'Member',
  };

  /// The power level written for this role (owners cannot be granted).
  int get powerLevel => switch (this) {
    RoomRole.owner => 150,
    RoomRole.admin => 100,
    RoomRole.moderator => 50,
    RoomRole.member => 0,
  };
}

RoomRole roleForPowerLevel(int level, {bool creator = false}) {
  if (creator || level >= 150) return RoomRole.owner;
  if (level >= 100) return RoomRole.admin;
  if (level >= 50) return RoomRole.moderator;
  return RoomRole.member;
}

@immutable
class RoomStateEntry {
  const RoomStateEntry(this.type, this.stateKey, this.content, this.senderId);
  final String type;
  final String stateKey;
  final Map<String, Object?> content;
  final String senderId;
}

@immutable
class RoomMemberDetails {
  const RoomMemberDetails({
    required this.id,
    required this.name,
    required this.status,
    required this.powerLevel,
    this.avatarUrl,
    this.reason,
    this.creator = false,
  });
  final String id;
  final String name;
  final RoomMemberStatus status;
  final int powerLevel;
  final Uri? avatarUrl;

  /// Reason attached to the membership (knock message, ban reason …).
  final String? reason;

  /// A v12+ room creator, who outranks every power level.
  final bool creator;

  RoomRole get role => roleForPowerLevel(powerLevel, creator: creator);
}

@immutable
class RoomDetails {
  const RoomDetails({
    required this.roomId,
    required this.name,
    required this.topic,
    required this.members,
    required this.permissions,
    required this.ownPowerLevel,
    required this.canManage,
    this.ownUserId,
    this.hasName = true,
    this.avatarUrl,
    this.canonicalAlias,
    this.altAliases = const [],
    this.joinRule = 'invite',
    this.allowedRoomIds = const [],
    this.historyVisibility = 'shared',
    this.encrypted = false,
    this.roomVersion = '1',
    this.isSpace = false,
    this.powerLevels,
    this.creators = const {},
  });

  /// Effective power level of v12+ room creators: above every other level.
  static const creatorPowerLevel = 1 << 31;

  final String roomId;
  final String name;
  final String topic;
  final List<RoomMemberDetails> members;
  final Set<RoomAction> permissions;
  final int ownPowerLevel;
  final bool canManage;
  final String? ownUserId;

  /// False when [name] is a fallback (the room has no m.room.name).
  final bool hasName;
  final Uri? avatarUrl;
  final String? canonicalAlias;
  final List<String> altAliases;

  /// `m.room.join_rules` value: invite, public, knock, restricted,
  /// knock_restricted or private.
  final String joinRule;
  final List<String> allowedRoomIds;
  final String historyVisibility;
  final bool encrypted;
  final String roomVersion;
  final bool isSpace;

  /// Raw `m.room.power_levels` content, or null when the room has none.
  final Map<String, Object?>? powerLevels;
  final Set<String> creators;

  int get _version => int.tryParse(roomVersion) ?? 1;
  bool get creatorsOutrank => _version >= 12;

  bool get isPublic => joinRule == 'public';
  bool get isKnockable => joinRule == 'knock' || joinRule == 'knock_restricted';
  bool get supportsKnock => _version >= 7;
  bool get supportsRestricted => _version >= 8;

  List<RoomMemberDetails> membersWith(RoomMemberStatus status) => [
    for (final member in members)
      if (member.status == status) member,
  ];

  int get joinedCount => membersWith(RoomMemberStatus.joined).length;
  List<RoomMemberDetails> get knockRequests =>
      membersWith(RoomMemberStatus.knocking);

  RoomMemberDetails? member(String userId) =>
      members.where((member) => member.id == userId).firstOrNull;

  /// Effective level of [userId] from the projected power levels.
  int powerOf(String userId) {
    if (creatorsOutrank && creators.contains(userId)) return creatorPowerLevel;
    final users = powerLevels?['users'];
    if (users is Map && users[userId] is int) return users[userId] as int;
    if (powerLevels == null && creators.contains(userId)) return 100;
    final fallback = powerLevels?['users_default'];
    return fallback is int ? fallback : 0;
  }

  /// Level required for a top-level action such as `invite` or `redact`.
  int required(String key, int fallback) {
    final value = powerLevels?[key];
    return value is int ? value : fallback;
  }

  /// Level required to send [type] as a state event.
  int requiredForState(String type) {
    final overrides = powerLevels?['events'];
    if (overrides is Map && overrides[type] is int) {
      return overrides[type] as int;
    }
    // A room without a power-levels event defaults state events to 0;
    // an existing event without state_default defaults to 50.
    return required('state_default', powerLevels == null ? 0 : 50);
  }

  /// Level required to send [type] as a timeline event.
  int requiredForEvent(String type) {
    final overrides = powerLevels?['events'];
    if (overrides is Map && overrides[type] is int) {
      return overrides[type] as int;
    }
    return required('events_default', 0);
  }

  bool canSendState(String type) =>
      canManage && ownPowerLevel >= requiredForState(type);

  bool get canEditAvatar => canSendState('m.room.avatar');
  bool get canEditDetails =>
      can(RoomAction.name) || can(RoomAction.topic) || canEditAvatar;
  bool get canChangePowerLevels => canSendState('m.room.power_levels');
  bool get canChangeJoinRule => canSendState('m.room.join_rules');
  bool get canChangeHistory => canSendState('m.room.history_visibility');
  bool get canEnableEncryption =>
      !encrypted && canSendState('m.room.encryption');
  bool get canChangeAddress => canSendState('m.room.canonical_alias');
  bool get canRedactOthers =>
      canManage && ownPowerLevel >= required('redact', 50);

  /// Whether the user can open Security & privacy at all.
  bool get canManageSecurity =>
      canChangeJoinRule ||
      canChangeHistory ||
      canEnableEncryption ||
      canChangeAddress;

  /// Whether the user can act on requests to join (accept or decline).
  bool get canManageKnocks =>
      permissions.contains(RoomAction.invite) ||
      permissions.contains(RoomAction.kick);

  /// Whether the user may move [target] to a role with [level].
  bool canSetPowerLevel(RoomMemberDetails target, int level) {
    if (!canChangePowerLevels || level > ownPowerLevel) return false;
    if (creatorsOutrank && target.creator) return false;
    if (target.id == ownUserId) return true; // Self-demotion is allowed.
    return target.powerLevel < ownPowerLevel;
  }

  bool can(RoomAction action, [RoomMemberDetails? target]) {
    if (!canManage || !permissions.contains(action)) return false;
    if (action == RoomAction.kick ||
        action == RoomAction.ban ||
        action == RoomAction.unban) {
      if (target == null || ownPowerLevel <= target.powerLevel) return false;
      if (action == RoomAction.kick) {
        return target.status == RoomMemberStatus.joined ||
            target.status == RoomMemberStatus.invited ||
            target.status == RoomMemberStatus.knocking;
      }
      if (action == RoomAction.ban) {
        return target.status != RoomMemberStatus.banned;
      }
      return target.status == RoomMemberStatus.banned;
    }
    return true;
  }

  static RoomDetails fromState({
    required String roomId,
    required String userId,
    required List<RoomStateEntry> state,
  }) {
    RoomStateEntry? event(String type, [String key = '']) {
      for (final item in state) {
        if (item.type == type && item.stateKey == key) return item;
      }
      return null;
    }

    String? text(Map<String, Object?>? content, String key) {
      final value = content?[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    Uri? mxc(Map<String, Object?>? content, String key) {
      final value = text(content, key);
      final uri = value == null ? null : Uri.tryParse(value);
      return uri != null && uri.scheme == 'mxc' && uri.host.isNotEmpty
          ? uri
          : null;
    }

    final create = event('m.room.create');
    final levelsEvent = event('m.room.power_levels');
    final levels = levelsEvent == null
        ? null
        : Map<String, Object?>.unmodifiable(levelsEvent.content);
    final users = levels?['users'];
    final userLevels = users is Map ? users : const <String, Object?>{};
    final roomVersion = create?.content['room_version'] is String
        ? create!.content['room_version'] as String
        : '1';
    final version = int.tryParse(roomVersion) ?? 1;
    final creators = <String>{
      if (create != null) create.senderId,
      if (create?.content['additional_creators'] case final List<dynamic> ids)
        ...ids.whereType<String>(),
    };
    final defaultUser = levels?['users_default'] is int
        ? levels!['users_default'] as int
        : 0;
    int power(String id) {
      if (version >= 12 && creators.contains(id)) return creatorPowerLevel;
      if (userLevels[id] is int) return userLevels[id] as int;
      if (levels == null && creators.contains(id)) return 100;
      return defaultUser;
    }

    final ownMembership = event('m.room.member', userId)?.content['membership'];
    final joined = ownMembership == 'join';
    final ownPower = power(userId);
    int requirement(String key, int fallback) =>
        levels?[key] is int ? levels![key] as int : fallback;
    int stateRequirement(String type) {
      final overrides = levels?['events'];
      if (overrides is Map && overrides[type] is int) {
        return overrides[type] as int;
      }
      // A room without a power-levels event defaults state events to 0;
      // an existing event without state_default defaults to 50.
      return requirement('state_default', levels == null ? 0 : 50);
    }

    final permissions = <RoomAction>{
      if (joined && ownPower >= stateRequirement('m.room.name'))
        RoomAction.name,
      if (joined && ownPower >= stateRequirement('m.room.topic'))
        RoomAction.topic,
      if (joined && ownPower >= requirement('invite', 0)) RoomAction.invite,
      if (joined && ownPower >= requirement('kick', 50)) RoomAction.kick,
      if (joined && ownPower >= requirement('ban', 50)) ...[
        RoomAction.ban,
        RoomAction.unban,
      ],
    };
    final members = <RoomMemberDetails>[];
    for (final item in state) {
      if (item.type != 'm.room.member' || item.stateKey.isEmpty) continue;
      final status = switch (item.content['membership']) {
        'join' => RoomMemberStatus.joined,
        'invite' => RoomMemberStatus.invited,
        'ban' => RoomMemberStatus.banned,
        'knock' => RoomMemberStatus.knocking,
        _ => null,
      };
      if (status == null) continue;
      final display = item.content['displayname'];
      members.add(
        RoomMemberDetails(
          id: item.stateKey,
          name: display is String && display.trim().isNotEmpty
              ? display
              : item.stateKey,
          status: status,
          powerLevel: power(item.stateKey),
          avatarUrl: mxc(item.content, 'avatar_url'),
          reason: text(item.content, 'reason'),
          creator: version >= 12 && creators.contains(item.stateKey),
        ),
      );
    }
    members.sort((a, b) {
      final status = a.status.index.compareTo(b.status.index);
      return status != 0
          ? status
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final serverName = event('m.room.name')?.content['name'];
    final serverTopic = event('m.room.topic')?.content['topic'];
    final aliasContent = event('m.room.canonical_alias')?.content;
    final joinRules = event('m.room.join_rules')?.content;
    final allow = joinRules?['allow'];
    final history = text(
      event('m.room.history_visibility')?.content,
      'history_visibility',
    );
    return RoomDetails(
      roomId: roomId,
      name: serverName is String && serverName.trim().isNotEmpty
          ? serverName
          : roomId,
      hasName: serverName is String && serverName.trim().isNotEmpty,
      topic: serverTopic is String ? serverTopic : '',
      members: List.unmodifiable(members),
      permissions: Set.unmodifiable(permissions),
      ownPowerLevel: ownPower,
      canManage: joined,
      ownUserId: userId,
      avatarUrl: mxc(event('m.room.avatar')?.content, 'url'),
      canonicalAlias: text(aliasContent, 'alias'),
      altAliases: List.unmodifiable([
        if (aliasContent?['alt_aliases'] case final List<dynamic> aliases)
          ...aliases.whereType<String>(),
      ]),
      joinRule: text(joinRules, 'join_rule') ?? 'invite',
      allowedRoomIds: List.unmodifiable([
        if (allow is List)
          for (final rule in allow)
            if (rule is Map &&
                rule['type'] == 'm.room_membership' &&
                rule['room_id'] is String)
              rule['room_id'] as String,
      ]),
      historyVisibility: history ?? 'shared',
      encrypted: event('m.room.encryption') != null,
      roomVersion: roomVersion,
      isSpace: create?.content['type'] == 'm.space',
      powerLevels: levels,
      creators: Set.unmodifiable(creators),
    );
  }
}
