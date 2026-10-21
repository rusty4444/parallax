import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;

bool isValidRoomInviteId(String value) =>
    value.startsWith('@') &&
    value.indexOf(':') > 1 &&
    value.isValidMatrixIdStrict(strictDomainCheck: true);

/// A projection of a fresh server /rooms/{id}/state response, not the SDK's
/// lazy-loaded room cache. The server remains the final authority on writes.
enum RoomMemberStatus { joined, invited, banned }

enum RoomAction { name, topic, invite, kick, ban, unban }

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
  });
  final String id;
  final String name;
  final RoomMemberStatus status;
  final int powerLevel;
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
  });

  final String roomId;
  final String name;
  final String topic;
  final List<RoomMemberDetails> members;
  final Set<RoomAction> permissions;
  final int ownPowerLevel;
  final bool canManage;

  bool can(RoomAction action, [RoomMemberDetails? target]) {
    if (!canManage || !permissions.contains(action)) return false;
    if (action == RoomAction.kick ||
        action == RoomAction.ban ||
        action == RoomAction.unban) {
      if (target == null || ownPowerLevel <= target.powerLevel) return false;
      if (action == RoomAction.kick) {
        return target.status == RoomMemberStatus.joined ||
            target.status == RoomMemberStatus.invited;
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

    final create = event('m.room.create');
    final levels = event('m.room.power_levels')?.content;
    final users = levels?['users'];
    final userLevels = users is Map ? users : const <String, Object?>{};
    final version =
        int.tryParse(create?.content['room_version'] as String? ?? '1') ?? 1;
    final creators = <String>{
      if (create != null) create.senderId,
      if (create?.content['additional_creators'] case final List<dynamic> ids)
        ...ids.whereType<String>(),
    };
    final defaultUser = levels?['users_default'] is int
        ? levels!['users_default'] as int
        : 0;
    int power(String id) {
      if (version >= 12 && creators.contains(id)) return 100;
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
    return RoomDetails(
      roomId: roomId,
      name: serverName is String && serverName.trim().isNotEmpty
          ? serverName
          : roomId,
      topic: serverTopic is String ? serverTopic : '',
      members: List.unmodifiable(members),
      permissions: Set.unmodifiable(permissions),
      ownPowerLevel: ownPower,
      canManage: joined,
    );
  }
}
