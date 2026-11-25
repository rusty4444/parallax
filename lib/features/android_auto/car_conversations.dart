// What Parallax shows on the Android Auto car screen: recent chats, each with
// its last few messages, which the car reads aloud and lets the driver answer
// by voice. Plain data and pure functions; the Matrix side is
// android_auto_features.dart and the car side parses the JSON in
// android/app/src/main/kotlin/net/samrussell/parallax/CarSnapshot.kt.
import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../notifications/matrix_push_projection.dart' show silentPushEventTypes;
import '../notifications/notification_content.dart';

/// Messages sent per conversation (the car shows the newest it has room for).
const maxCarMessagesPerConversation = 6;

/// Conversations sent per request, whatever the car allows.
const maxCarConversations = 20;

/// What the car screen should show.
enum CarScreenState { ready, signedOut, locked, loading }

/// One message as the car reads it.
@immutable
class CarMessageLine {
  const CarMessageLine({
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    required this.fromMe,
    required this.read,
    this.senderIconPath,
  });

  final String eventId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime timestamp;
  final bool fromMe;
  final bool read;
  final String? senderIconPath;

  CarMessageLine copyWith({bool? read, String? senderIconPath}) =>
      CarMessageLine(
        eventId: eventId,
        senderId: senderId,
        senderName: senderName,
        text: text,
        timestamp: timestamp,
        fromMe: fromMe,
        read: read ?? this.read,
        senderIconPath: senderIconPath ?? this.senderIconPath,
      );

  Map<String, Object?> toJson() => {
    if (!fromMe) 'sender': senderId,
    'senderName': senderName,
    'senderIcon': ?senderIconPath,
    'text': text,
    'ts': timestamp.millisecondsSinceEpoch,
    'me': fromMe,
    'read': read,
  };
}

/// One chat on the car screen.
@immutable
class CarConversation {
  const CarConversation({
    required this.roomId,
    required this.title,
    required this.isDirect,
    required this.unread,
    required this.messages,
    this.iconPath,
  });

  final String roomId;
  final String title;
  final bool isDirect;
  final int unread;

  /// Oldest first.
  final List<CarMessageLine> messages;
  final String? iconPath;

  bool get hasUnread => unread > 0 || messages.any((line) => !line.read);

  Map<String, Object?> toJson() => {
    'id': roomId,
    'title': title,
    'direct': isDirect,
    'icon': ?iconPath,
    'unread': unread,
    'messages': [for (final line in messages) line.toJson()],
  };
}

/// The answer to the car's "conversations" request.
Map<String, Object?> carSnapshotJson(
  CarScreenState state, {
  String? selfId,
  String selfName = 'Me',
  List<CarConversation> conversations = const [],
}) => {
  'state': state.name,
  if (state == CarScreenState.ready) ...{
    'self': {'id': selfId, 'name': selfName},
    'conversations': [
      for (final conversation in conversations)
        if (conversation.messages.isNotEmpty) conversation.toJson(),
    ],
  },
};

/// The chats offered in the car, in inbox order (newest activity first):
/// joined chats only, never Spaces, invitations or locked chats.
List<ChatRoom> carRoomsFor(
  List<ChatRoom> rooms, {
  required bool unreadOnly,
  required int limit,
  required bool Function(String roomId) isLocked,
}) {
  final candidates =
      rooms
          .where(
            (room) =>
                !room.invited &&
                !room.isSpace &&
                !isLocked(room.id) &&
                (!unreadOnly || room.unread > 0 || room.manuallyUnread),
          )
          .toList()
        ..sort(compareRooms);
  return candidates.take(limit.clamp(0, maxCarConversations)).toList();
}

/// An event from a room's stored timeline, reduced to what the car needs.
@immutable
class CarTimelineEvent {
  const CarTimelineEvent({
    required this.eventId,
    required this.senderId,
    required this.type,
    required this.content,
    required this.timestamp,
    this.redacted = false,
    this.stateKey,
  });

  final String eventId;
  final String senderId;
  final String type;
  final Map<String, Object?> content;
  final DateTime timestamp;
  final bool redacted;
  final String? stateKey;
}

const _carPollStartTypes = {'m.poll.start', 'org.matrix.msc3381.poll.start'};

Map<String, Object?>? _relation(Map<String, Object?> content) {
  final relation = content['m.relates_to'];
  return relation is Map ? Map<String, Object?>.from(relation) : null;
}

/// Turns stored events into the car's message lines, oldest first and at
/// most [max]: chat messages, stickers and polls, with edits applied (only
/// edits by the original sender count). Reactions, redactions, calls, state
/// changes and messages that are still encrypted are left out.
///
/// A line is unread when it is someone else's and newer than [readUpTo] (the
/// time of your read receipt). Without a receipt, the newest
/// [unreadCount] lines from others are unread. A chat with nothing unread
/// ([unreadCount] 0 and not marked unread) has every line read.
List<CarMessageLine> carMessageLines(
  List<CarTimelineEvent> events, {
  required String myUserId,
  required String Function(String userId) nameOf,
  required int unreadCount,
  bool markedUnread = false,
  DateTime? readUpTo,
  String roomName = '',
  bool isDirect = false,
  String Function(String text)? decorate,
  int max = maxCarMessagesPerConversation,
}) {
  final ordered = [...events]
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final byId = {for (final event in ordered) event.eventId: event};
  // The newest edit of each message, by its own sender.
  final edits = <String, Map<String, Object?>>{};
  final editIds = <String>{};
  for (final event in ordered) {
    final relation = _relation(event.content);
    if (relation?['rel_type'] != 'm.replace') continue;
    editIds.add(event.eventId);
    final target = relation?['event_id'];
    final replacement = event.content['m.new_content'];
    if (target is! String || replacement is! Map || event.redacted) continue;
    final original = byId[target];
    if (original != null && original.senderId != event.senderId) continue;
    edits[target] = Map<String, Object?>.from(replacement);
  }
  final lines = <CarMessageLine>[];
  for (final event in ordered) {
    if (editIds.contains(event.eventId) ||
        event.redacted ||
        event.stateKey != null ||
        silentPushEventTypes.contains(event.type) ||
        callNotificationEventTypes.contains(event.type)) {
      continue;
    }
    if (event.type != 'm.room.message' &&
        event.type != 'm.sticker' &&
        !_carPollStartTypes.contains(event.type)) {
      continue;
    }
    final edit = edits[event.eventId];
    final content = edit == null
        ? event.content
        : {
            ...edit,
            // The reply a message answers stays with the original.
            'm.relates_to': ?event.content['m.relates_to'],
          };
    final fromMe = event.senderId == myUserId;
    final senderName = nameOf(event.senderId);
    final description = describeNotificationEvent(
      type: event.type,
      content: content,
      senderName: senderName,
      myUserId: myUserId,
      roomName: roomName,
      isDirect: isDirect,
      originServerTs: event.timestamp,
    );
    if (description == null) continue;
    final text = (decorate ?? (text) => text)(description.text).trim();
    if (text.isEmpty) continue;
    lines.add(
      CarMessageLine(
        eventId: event.eventId,
        senderId: event.senderId,
        senderName: senderName,
        text: text,
        timestamp: event.timestamp,
        fromMe: fromMe,
        read: true,
      ),
    );
  }
  final shown = lines.length > max ? lines.sublist(lines.length - max) : lines;
  if (unreadCount <= 0 && !markedUnread) return shown;
  if (readUpTo != null) {
    return [
      for (final line in shown)
        line.fromMe || !line.timestamp.isAfter(readUpTo)
            ? line
            : line.copyWith(read: false),
    ];
  }
  // No receipt to compare with: the newest messages from others are unread.
  var left = unreadCount > 0 ? unreadCount : 1;
  final marked = [...shown];
  for (var i = marked.length - 1; i >= 0 && left > 0; i--) {
    if (marked[i].fromMe) break;
    marked[i] = marked[i].copyWith(read: false);
    left--;
  }
  return marked;
}
