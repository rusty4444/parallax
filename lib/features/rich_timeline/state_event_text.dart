import '../../chat_backend.dart';
import 'rich_timeline_features.dart';

/// Whether [entry] needs its previous state to be described precisely
/// (membership joins/leaves, power levels and pins).
bool stateEventNeedsPrevious(ChatEntry entry) {
  switch (entry.eventType) {
    case 'm.room.member':
      final membership = entry.content['membership'];
      return membership == 'join' || membership == 'leave';
    case 'm.room.power_levels':
    case 'm.room.pinned_events':
      return true;
    default:
      return false;
  }
}

/// Describes a state event in Element X wording. Returns null when the
/// description depends on previous state that is not known yet ([previous]
/// is null) — callers then show the SDK's fallback body ([ChatEntry.body]).
String? describeStateEvent(
  ChatEntry entry, {
  required String? ownUserId,
  PreviousState? previous,
  String? Function(String userId)? nameOf,
}) {
  final content = entry.content;
  final senderIsYou = entry.sender == ownUserId;
  final sender = entry.senderLabel;
  String text(Object? value) => value is String ? value.trim() : '';

  switch (entry.eventType) {
    case 'm.room.member':
      return _membership(entry, ownUserId, previous, nameOf);
    case 'm.room.name':
      final name = text(content['name']);
      if (name.isEmpty) {
        return senderIsYou
            ? 'You removed the room name'
            : '$sender removed the room name';
      }
      return senderIsYou
          ? 'You changed the room name to: $name'
          : '$sender changed the room name to: $name';
    case 'm.room.topic':
      final topic = text(content['topic']);
      if (topic.isEmpty) {
        return senderIsYou
            ? 'You removed the room topic'
            : '$sender removed the room topic';
      }
      return senderIsYou
          ? 'You changed the topic to: $topic'
          : '$sender changed the topic to: $topic';
    case 'm.room.avatar':
      final hasAvatar = text(content['url']).isNotEmpty;
      return switch ((senderIsYou, hasAvatar)) {
        (true, true) => 'You changed the room avatar',
        (true, false) => 'You removed the room avatar',
        (false, true) => '$sender changed the room avatar',
        (false, false) => '$sender removed the room avatar',
      };
    case 'm.room.create':
      return senderIsYou ? 'You created the room' : '$sender created the room';
    case 'm.room.encryption':
      return 'Encryption enabled';
    case 'm.room.tombstone':
      return 'This room has been replaced and is no longer active';
    case 'm.room.pinned_events':
      return _pins(entry, senderIsYou, sender, previous);
    case 'm.room.power_levels':
      return _powerLevels(entry, senderIsYou, sender, previous, nameOf);
    case 'm.room.join_rules':
      final who = senderIsYou ? 'You' : sender;
      return switch (content['join_rule']) {
        'public' => '$who made the room public to anyone who knows the link',
        'invite' => '$who made the room invite only',
        'knock' => '$who changed the room to ask to join',
        'restricted' ||
        'knock_restricted' => '$who limited who can join this room',
        _ => '$who changed who can join this room',
      };
    case 'm.room.history_visibility':
      final who = senderIsYou ? 'You' : sender;
      final audience = switch (content['history_visibility']) {
        'world_readable' => 'anyone',
        'shared' => 'all room members',
        'invited' => 'all room members, from the point they are invited',
        'joined' => 'all room members, from the point they joined',
        _ => null,
      };
      return audience == null
          ? '$who changed who can read the room history'
          : '$who made future room history visible to $audience';
    case 'm.room.canonical_alias':
      final who = senderIsYou ? 'You' : sender;
      final alias = text(content['alias']);
      return alias.isEmpty
          ? '$who removed the main address for this room'
          : '$who set the main address for this room to $alias';
    case 'm.room.guest_access':
      final who = senderIsYou ? 'You' : sender;
      return content['guest_access'] == 'can_join'
          ? '$who allowed guests to join the room'
          : '$who prevented guests from joining the room';
    case 'm.room.server_acl':
      final who = senderIsYou ? 'You' : sender;
      return '$who changed the server access rules for this room';
    default:
      return null;
  }
}

String? _membership(
  ChatEntry entry,
  String? ownUserId,
  PreviousState? previous,
  String? Function(String userId)? nameOf,
) {
  final content = entry.content;
  final target = entry.stateKey ?? entry.sender;
  final senderIsYou = entry.sender == ownUserId;
  final memberIsYou = target == ownUserId;
  final sender = entry.senderLabel;
  final prev = previous?.content;
  String? nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  final targetName =
      nonEmpty(content['displayname']) ??
      nonEmpty(prev?['displayname']) ??
      nameOf?.call(target) ??
      target;
  final reason = nonEmpty(content['reason']);
  final membership = content['membership'];
  final oldMembership = previous == null
      ? null
      : (nonEmpty(prev?['membership']) ?? 'leave');

  String withReason(String text) => reason == null ? text : '$text: $reason';

  switch (membership) {
    case 'invite':
      if (oldMembership == 'knock') {
        return senderIsYou
            ? 'You allowed $targetName to join'
            : '$sender granted access to $targetName';
      }
      if (senderIsYou) return 'You invited $targetName';
      if (memberIsYou) return '$sender invited you';
      return '$sender invited $targetName';
    case 'ban':
      return senderIsYou
          ? withReason('You banned $targetName')
          : withReason('$sender banned $targetName');
    case 'knock':
      return memberIsYou
          ? 'You requested to join'
          : '$sender is requesting to join';
  }
  if (oldMembership == null) return null; // Ambiguous until loaded.
  if (membership == 'join') {
    if (oldMembership == 'invite') {
      return memberIsYou
          ? 'You accepted the invite'
          : '$targetName accepted the invite';
    }
    if (oldMembership == 'join') {
      return _profileChange(entry, prev ?? const {}, senderIsYou);
    }
    return memberIsYou ? 'You joined the room' : '$sender joined the room';
  }
  if (membership == 'leave') {
    final self = entry.sender == target;
    switch (oldMembership) {
      case 'invite':
        if (self) {
          return memberIsYou
              ? 'You rejected the invitation'
              : '$targetName rejected the invitation';
        }
        return senderIsYou
            ? 'You revoked the invitation for $targetName to join the room'
            : '$sender revoked the invitation for $targetName to join the room';
      case 'ban':
        return senderIsYou
            ? 'You unbanned $targetName'
            : '$sender unbanned $targetName';
      case 'knock':
        if (self) {
          return memberIsYou
              ? 'You cancelled your request to join'
              : '$sender is no longer interested in joining';
        }
        if (senderIsYou) return 'You rejected $targetName’s request to join';
        if (memberIsYou) return '$sender rejected your request to join';
        return '$sender rejected $targetName’s request to join';
      case 'leave':
        return senderIsYou ? 'You made no changes' : '$sender made no changes';
      default:
        if (self) {
          return memberIsYou ? 'You left the room' : '$sender left the room';
        }
        return senderIsYou
            ? withReason('You removed $targetName')
            : withReason('$sender removed $targetName');
    }
  }
  return null;
}

String _profileChange(
  ChatEntry entry,
  Map<String, Object?> prev,
  bool senderIsYou,
) {
  String? value(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
  final oldName = value(prev['displayname']);
  final newName = value(entry.content['displayname']);
  final avatarChanged =
      value(prev['avatar_url']) != value(entry.content['avatar_url']);
  final who = senderIsYou ? 'You' : (oldName ?? entry.senderLabel);
  String? name;
  if (oldName != newName) {
    if (newName != null && oldName != null) {
      name = senderIsYou
          ? 'You changed your display name from $oldName to $newName'
          : '$who changed their display name from $oldName to $newName';
    } else if (newName != null) {
      name = senderIsYou
          ? 'You set your display name to $newName'
          : '${entry.sender} set their display name to $newName';
    } else {
      name = senderIsYou
          ? 'You removed your display name (it was $oldName)'
          : '${entry.sender} removed their display name (it was $oldName)';
    }
  }
  if (name != null) {
    return avatarChanged ? '$name (avatar was changed too)' : name;
  }
  if (avatarChanged) {
    return senderIsYou
        ? 'You changed your avatar'
        : '$who changed their avatar';
  }
  return senderIsYou ? 'You made no changes' : '$who made no changes';
}

String? _pins(
  ChatEntry entry,
  bool senderIsYou,
  String sender,
  PreviousState? previous,
) {
  Set<String> ids(Object? value) =>
      value is List ? value.whereType<String>().toSet() : <String>{};
  final changed = senderIsYou
      ? 'You changed the pinned messages'
      : '$sender changed the pinned messages';
  if (previous == null) return null;
  final now = ids(entry.content['pinned']);
  final before = ids(previous.content?['pinned']);
  final added = now.difference(before);
  final removed = before.difference(now);
  if (added.length == 1 && removed.isEmpty) {
    return senderIsYou ? 'You pinned a message' : '$sender pinned a message';
  }
  if (removed.length == 1 && added.isEmpty) {
    return senderIsYou
        ? 'You unpinned a message'
        : '$sender unpinned a message';
  }
  return changed;
}

String? _powerLevels(
  ChatEntry entry,
  bool senderIsYou,
  String sender,
  PreviousState? previous,
  String? Function(String userId)? nameOf,
) {
  final generic = senderIsYou
      ? 'You changed the room permissions'
      : '$sender changed the room permissions';
  if (previous == null) return null;
  Map<String, int> users(Map<String, Object?>? content) {
    final value = content?['users'];
    if (value is! Map) return const {};
    return {
      for (final e in value.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  }

  int defaultLevel(Map<String, Object?>? content) {
    final value = content?['users_default'];
    return value is int ? value : 0;
  }

  final before = users(previous.content);
  final after = users(entry.content);
  final beforeDefault = defaultLevel(previous.content);
  final afterDefault = defaultLevel(entry.content);
  final changes = <String>[];
  for (final userId in {...before.keys, ...after.keys}.toList()..sort()) {
    final old = before[userId] ?? beforeDefault;
    final now = after[userId] ?? afterDefault;
    if (old == now) continue;
    final name = nameOf?.call(userId) ?? userId;
    final role = now >= 100
        ? 'admin'
        : now >= 50
        ? 'moderator'
        : 'member';
    if (now > old) {
      changes.add(
        role == 'member'
            ? '$name’s power level was changed to $now'
            : '$name was promoted to $role',
      );
    } else {
      changes.add('$name was demoted to $role');
    }
  }
  if (changes.isEmpty || changes.length > 3) return generic;
  return changes.join(', ');
}
