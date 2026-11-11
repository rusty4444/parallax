import 'package:matrix/matrix.dart' as matrix;

/// Generic, guarded room writes for feature modules (polls, pins, reactions,
/// location, calls, room settings …).
///
/// [sendRoomEvent] uses the same session ownership, recipient-trust approval,
/// fail-closed encryption and final HTTP guard as text messages. Feature code
/// must use it instead of calling `Room.sendEvent` on the SDK directly.
abstract interface class RoomEventFeatures {
  /// Sends a timeline event and returns its server event ID. Throws if the
  /// room is not joined, the session changed, recipients were not approved or
  /// encryption is unavailable for an encrypted room.
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  );

  /// Writes room state (power levels, pins, join rules …). The homeserver
  /// makes the final authorisation decision.
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  });

  /// Reads current room state from the homeserver (not the local cache), or
  /// null when the state event does not exist.
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  });

  /// Redacts any event the server permits this user to redact (own events,
  /// or others' events for moderators). Use for moderation and poll/pin
  /// clean-up; ordinary own-message deletion keeps using redactMessage.
  Future<void> redactEvent(String roomId, String eventId, {String? reason});
}

/// Read access to the Matrix SDK for feature modules.
///
/// Never use [sdkClient] to send timeline events: use [RoomEventFeatures] so
/// the encryption and trust guards apply. Re-check [isSessionCurrent] after
/// every await before touching UI or caches.
abstract interface class MatrixSdkAccess {
  matrix.Client? get sdkClient;

  /// True while [client] is still this backend's signed-in session.
  bool isSessionCurrent(matrix.Client client);
}
