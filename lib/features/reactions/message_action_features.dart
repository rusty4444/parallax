import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'matrix_message_actions.dart';

/// One member's reaction, for the reaction summary sheet.
@immutable
class ReactionSender {
  const ReactionSender({
    required this.emoji,
    required this.userId,
    this.displayName,
    this.time,
  });

  final String emoji;
  final String userId;

  /// Display name from cached room membership, if known.
  final String? displayName;
  final DateTime? time;

  String get label =>
      (displayName?.trim().isNotEmpty ?? false) ? displayName!.trim() : userId;
}

/// What the signed-in user may do in a room, from cached power levels. The
/// homeserver still makes the final decision on every write.
@immutable
class MessageActionPermissions {
  const MessageActionPermissions({
    this.canReact = false,
    this.canPin = false,
    this.canRedactOthers = false,
    this.canSendMessages = false,
  }) : known = true;

  const MessageActionPermissions._unknown()
    : known = false,
      canReact = false,
      canPin = false,
      canRedactOthers = false,
      canSendMessages = false;

  /// Nothing is allowed because the room or session is unavailable (offline,
  /// not joined, signed out), rather than because power levels deny it.
  static const none = MessageActionPermissions._unknown();

  /// False when the room's power levels could not be read.
  final bool known;
  final bool canReact;
  final bool canPin;
  final bool canRedactOthers;
  final bool canSendMessages;
}

/// Backend operations behind reactions, forwarding, pins, reports and
/// moderator removal. Implemented for the live Matrix backend by
/// [MatrixMessageActions]; test fakes implement it directly.
abstract interface class MessageActionFeatures {
  MessageActionPermissions permissions(String roomId);

  /// Pinned event IDs from local room state, in pin order (oldest first).
  List<String> pinnedEventIds(String roomId);

  /// Pins or unpins after re-reading the current `m.room.pinned_events`.
  Future<void> setPinned(String roomId, String eventId, {required bool pinned});

  /// Loads one event (for example a pinned message outside the loaded
  /// timeline). Returns null when the server does not have it.
  Future<ChatEntry?> loadEvent(String roomId, String eventId);

  /// Who reacted to [eventId], with names from cached membership.
  Future<List<ReactionSender>> reactionSenders(String roomId, String eventId);

  /// Sends forwarded content through the guarded room send path.
  Future<String> forwardEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  );

  /// Reports an event to the homeserver administrators.
  Future<void> reportContent(
    String roomId,
    String eventId, {
    required String reason,
  });

  /// Adds [userId] to the account's ignored users.
  Future<void> ignoreUser(String userId);

  /// Redacts any event the server permits (moderator removal).
  Future<void> removeEvent(String roomId, String eventId, {String? reason});
}

final _features = Expando<MessageActionFeatures>('messageActionFeatures');

/// Resolves message-action support for [backend], or null when the backend
/// cannot provide it (for example a minimal test fake).
MessageActionFeatures? messageActionFeaturesOf(ChatBackend backend) {
  if (backend is MessageActionFeatures) {
    return backend as MessageActionFeatures;
  }
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _features[backend] ??= MatrixMessageActions(backend);
  }
  return null;
}
