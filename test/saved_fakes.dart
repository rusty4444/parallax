import 'dart:async';

import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/saved/saved_features.dart';
import 'package:parallax/features/saved/saved_models.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';

import 'home_fakes.dart';

ChatRoom savedRoom(
  String id, {
  String? name,
  bool direct = false,
  int unread = 0,
  bool favourite = false,
  bool invited = false,
  bool encrypted = false,
  String preview = '',
}) => ChatRoom(
  id: id,
  name: name ?? id,
  preview: preview,
  lastActivity: null,
  isDirect: direct,
  unread: unread,
  favourite: favourite,
  invited: invited,
  encrypted: encrypted,
);

/// Widget-test backend implementing the saved module interface directly.
class SavedFakeBackend extends HomeFakeBackend
    implements SavedFeatures, TimelineNavigation {
  SavedFakeBackend();

  String? noteRoom;
  bool promptDismissed = false;
  int noteOpens = 0;
  Completer<String>? noteGate;
  BookmarkList saved = BookmarkList.empty;
  ChatFolders folderData = ChatFolders.empty;
  final events = <String, SavedEventResult>{};
  final failingEvents = <String>{};
  final eventLoads = <String>[];
  final jumps = <String>[];
  bool failWrites = false;
  int folderWrites = 0;

  // --- Note to self ---

  @override
  String? get noteToSelfRoomId =>
      noteRoom != null && roomList.any((r) => r.id == noteRoom)
      ? noteRoom
      : null;

  @override
  bool get noteToSelfPromptDismissed => promptDismissed;

  @override
  Future<String> openNoteToSelf() async {
    noteOpens++;
    final gate = noteGate;
    if (gate != null) return gate.future;
    final id = noteRoom ??= '!note:x.org';
    if (!roomList.any((r) => r.id == id)) {
      roomList = [
        ...roomList,
        savedRoom(id, name: 'Note to self', direct: true, encrypted: true),
      ];
    }
    notifyListeners();
    return id;
  }

  @override
  Future<void> dismissNoteToSelfPrompt() async {
    if (failWrites) throw StateError('write failed');
    promptDismissed = true;
    notifyListeners();
  }

  // --- Bookmarks ---

  @override
  BookmarkList get bookmarks => saved;

  @override
  Future<void> setSaved(
    String roomId,
    String eventId, {
    required bool saved,
    DateTime? savedAt,
  }) async {
    if (failWrites) throw StateError('write failed');
    this.saved = saved
        ? this.saved.withAdded(
            roomId,
            eventId,
            savedTs: (savedAt ?? DateTime(2026, 11, 12)).millisecondsSinceEpoch,
          )
        : this.saved.withRemoved(roomId, eventId);
    notifyListeners();
  }

  @override
  Future<SavedEventResult> loadSavedEvent(String roomId, String eventId) async {
    eventLoads.add(eventId);
    if (failingEvents.contains(eventId)) throw StateError('offline');
    if (!roomList.any((r) => r.id == roomId && !r.invited)) {
      return const SavedEventResult.roomUnavailable();
    }
    return events[eventId] ?? const SavedEventResult.notFound();
  }

  // --- Folders ---

  @override
  ChatFolders get folders => folderData;

  @override
  Future<ChatFolders> updateFolders(
    ChatFolders Function(ChatFolders current) change,
  ) async {
    if (failWrites) throw StateError('write failed');
    folderWrites++;
    folderData = change(folderData);
    notifyListeners();
    return folderData;
  }

  // --- Timeline navigation ---

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    jumps.add('$roomId $eventId');
    activeId = roomId;
  }

  @override
  String? focusedEventIn(String roomId) => null;

  @override
  int jumpGenerationIn(String roomId) => 0;

  @override
  bool hasNewerThanFocus(String roomId) => false;

  @override
  Future<void> jumpToLatest(String roomId) async {}
}
