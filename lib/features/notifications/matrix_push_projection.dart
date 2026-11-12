// Projects a fetched, decrypted Matrix event into a notification line. Shared
// by the live (main isolate) and background resolvers.
import 'package:matrix/matrix.dart' as matrix;

import 'notification_content.dart';
import 'notification_media.dart';
import 'notification_model.dart';
import '../../matrix_room_names.dart';

/// The event could not be described (still encrypted, unsupported type …):
/// the caller shows the generic notification.
/// Event types that never produce a notification (live-location beacons
/// and MatrixRTC call membership), even when the push rules notify.
const silentPushEventTypes = {
  'm.beacon',
  'org.matrix.msc3672.beacon',
  'm.call.member',
  'org.matrix.msc3401.call.member',
};

/// The decrypted event is one Parallax deliberately doesn't notify for.
class SilentPushEvent implements Exception {
  const SilentPushEvent();
  @override
  String toString() => 'Event does not notify';
}

class UndescribablePushEvent implements Exception {
  const UndescribablePushEvent();
  @override
  String toString() => 'Event cannot be shown in a notification';
}

/// Highlight (mention/keyword) according to the account's push rules.
bool pushEventHighlights(
  matrix.PushruleEvaluator evaluator,
  matrix.Event event,
) {
  try {
    return evaluator.match(event).highlight;
  } catch (_) {
    return false;
  }
}

/// Builds the notification for [event] in [room]. Media and avatars are only
/// fetched through [media] (null when content previews are off).
Future<ResolvedPushEvent> projectPushEvent({
  required matrix.Event event,
  required matrix.Room room,
  required String myUserId,
  required bool isDirect,
  required bool highlight,
  NotificationMediaLoader? media,
  bool loadMediaPreview = true,
  DateTime? now,
}) async {
  if (silentPushEventTypes.contains(event.type)) {
    throw const SilentPushEvent();
  }
  // Show people's names, not Matrix IDs: the sender (and a DM partner, who
  // names the conversation) may not be loaded for a room not opened yet.
  final people = [event.senderId, if (isDirect) ...room.peopleHeroes.take(1)];
  await room.loadMissingMembers(people);
  // The stored copy can predate a rename (bridges renaming contacts from
  // phone numbers to names): use the server's current names.
  try {
    await Future.wait([
      for (final id in people.toSet()) room.refreshMemberFromServer(id),
    ]).timeout(const Duration(seconds: 3));
  } catch (_) {}
  final sender = event.senderFromMemoryOrFallback;
  final senderName =
      sanitiseNotificationName(sender.calcDisplayname()) ??
      sanitiseNotificationName(event.senderId) ??
      'Someone';
  final roomName =
      sanitiseNotificationName(room.parallaxName) ?? 'Conversation';
  final description = describeNotificationEvent(
    type: event.type,
    content: Map<String, Object?>.from(event.content),
    senderName: senderName,
    stateKey: event.stateKey,
    myUserId: myUserId,
    roomName: roomName,
    isDirect: isDirect,
    redacted: event.redacted,
    originServerTs: event.originServerTs,
    now: now,
  );
  if (description == null) throw const UndescribablePushEvent();
  String? avatarPath;
  String? roomAvatarPath;
  String? imagePath;
  if (media != null) {
    final avatar = media.avatar(sender.avatarUrl);
    final roomAvatar = isDirect ? null : media.avatar(room.avatar);
    final ref = description.media;
    final preview = ref != null && loadMediaPreview
        ? media.preview(ref, event.eventId)
        : null;
    avatarPath = await avatar;
    roomAvatarPath = await roomAvatar;
    imagePath = await preview;
  }
  return ResolvedPushEvent(
    roomId: room.id,
    eventId: event.eventId,
    kind: description.kind,
    roomName: roomName,
    isDirect: isDirect,
    roomAvatarPath: roomAvatarPath,
    ringing: description.ringing && isDirect,
    line: NotificationLine(
      eventId: event.eventId,
      senderId: event.senderId,
      senderName: senderName,
      text: description.text,
      timestamp: event.originServerTs,
      highlight: highlight,
      senderAvatarPath: avatarPath,
      imagePath: imagePath,
    ),
  );
}

/// An invitation from the room's (stripped) invite state, which is all a
/// client can read before joining.
Future<ResolvedPushEvent> projectInvite({
  required matrix.Room room,
  required String myUserId,
  required String eventId,
  NotificationMediaLoader? media,
}) async {
  final member = room.getState(matrix.EventTypes.RoomMember, myUserId);
  if (member == null || member.content['membership'] != 'invite') {
    throw const UndescribablePushEvent();
  }
  await room.loadMissingMembers([member.senderId]);
  final inviter = room.unsafeGetUserFromMemoryOrFallback(member.senderId);
  final senderName =
      sanitiseNotificationName(inviter.calcDisplayname()) ??
      sanitiseNotificationName(member.senderId) ??
      'Someone';
  final roomName = sanitiseNotificationName(room.parallaxName);
  final isDirect = member.content['is_direct'] == true;
  final description = describeNotificationEvent(
    type: matrix.EventTypes.RoomMember,
    content: Map<String, Object?>.from(member.content),
    senderName: senderName,
    stateKey: myUserId,
    myUserId: myUserId,
    roomName: roomName,
    isDirect: isDirect,
  );
  if (description == null) throw const UndescribablePushEvent();
  final avatar = await media?.avatar(inviter.avatarUrl);
  return ResolvedPushEvent(
    roomId: room.id,
    eventId: eventId,
    kind: NotifiableEventKind.invite,
    roomName: roomName ?? 'Conversation',
    isDirect: isDirect,
    line: NotificationLine(
      eventId: eventId,
      senderId: member.senderId,
      senderName: senderName,
      text: description.text,
      timestamp: DateTime.now(),
      senderAvatarPath: avatar,
    ),
  );
}
