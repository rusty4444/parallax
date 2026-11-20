import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'matrix_saved_features.dart';
import 'saved_models.dart';

/// Why a saved message could not be shown.
enum SavedEventStatus {
  available,

  /// The room was left, is unknown or is only an invitation.
  roomUnavailable,

  /// The server no longer has the event (or never returned it).
  notFound,
}

@immutable
class SavedEventResult {
  const SavedEventResult.available(ChatEntry this.entry)
    : status = SavedEventStatus.available;
  const SavedEventResult.roomUnavailable()
    : status = SavedEventStatus.roomUnavailable,
      entry = null;
  const SavedEventResult.notFound()
    : status = SavedEventStatus.notFound,
      entry = null;

  final SavedEventStatus status;
  final ChatEntry? entry;
}

/// Note to self could not be created without weakening privacy.
class NoteToSelfUnavailable implements Exception {
  const NoteToSelfUnavailable(this.message);
  final String message;
  @override
  String toString() => 'NoteToSelfUnavailable: $message';
}

/// The Note to self room was created (or found) but has not arrived through
/// sync yet. Retrying reuses it; no second room is created.
class NoteToSelfNotSynced implements Exception {
  const NoteToSelfNotSynced(this.roomId);
  final String roomId;
}

/// Note to self, saved messages and chat folders, synced through account
/// data. Implemented for the live Matrix backend by [MatrixSavedFeatures];
/// widget-test fakes implement it directly.
///
/// Listeners are notified after this device's own writes; changes from other
/// devices arrive through the backend's sync notifications, so UIs listen to
/// both.
abstract interface class SavedFeatures implements Listenable {
  // --- Note to self --------------------------------------------------------

  /// The recorded Note to self room when it is joined, otherwise null.
  String? get noteToSelfRoomId;

  /// The user dismissed the inbox's "Start your note to self" row.
  bool get noteToSelfPromptDismissed;

  /// Returns the Note to self room, creating a private encrypted room with no
  /// other members on first use. Concurrent calls share one request.
  Future<String> openNoteToSelf();

  Future<void> dismissNoteToSelfPrompt();

  /// Note to self stays first in the chat list unless the user unpinned it.
  bool get noteToSelfPinned;

  /// Pins Note to self to the top of the chat list, or lets it sort with the
  /// other chats. Synced to every device.
  Future<void> setNoteToSelfPinned(bool pinned);

  // --- Saved messages ------------------------------------------------------

  /// Saved message identifiers, newest first.
  BookmarkList get bookmarks;

  /// Saves or removes a message. [savedAt] restores an original position
  /// (undo); it defaults to now.
  Future<void> setSaved(
    String roomId,
    String eventId, {
    required bool saved,
    DateTime? savedAt,
  });

  /// Loads one saved message for display, decrypting it when possible. Throws
  /// on network or session errors so the caller can offer a retry.
  Future<SavedEventResult> loadSavedEvent(String roomId, String eventId);

  // --- Chat folders --------------------------------------------------------

  ChatFolders get folders;

  /// Re-reads the folders from the server, applies [change] and writes the
  /// result. Returns what was written.
  Future<ChatFolders> updateFolders(
    ChatFolders Function(ChatFolders current) change,
  );
}

final _cache = Expando<SavedFeatures>('saved features');

/// Resolves saved/folder support for [backend], or null when it has none
/// (for example a minimal test fake).
SavedFeatures? savedFeaturesOf(ChatBackend backend) {
  if (backend is SavedFeatures) return backend as SavedFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _cache[backend] ??= MatrixSavedFeatures(
      backend,
      backend as MatrixSdkAccess,
    );
  }
  return null;
}
