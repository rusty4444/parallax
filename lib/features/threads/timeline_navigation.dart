import '../../chat_backend.dart';
import '../../matrix_backend.dart';

/// Jump to event: open a room's timeline focused on one event (search results,
/// permalinks, pinned messages) and return to the live end afterwards.
///
/// While focused, the event is the newest visible timeline entry, so the
/// existing bottom-anchored timeline shows it without scrolling. The thread
/// module marks it with a "Jumped to this message" footer and offers
/// "Jump to latest" in the room header.
abstract interface class TimelineNavigation {
  /// Opens [roomId] with its timeline loaded around [eventId]. Throws when
  /// the room is not joined or the event cannot be loaded; the room can then
  /// still be opened normally.
  Future<void> openRoomAt(String roomId, String eventId);

  /// Event the active timeline of [roomId] was jumped to, or null when the
  /// room was opened normally (or another room is active). The timeline stays
  /// live; this marks the message to scroll to and highlight.
  String? focusedEventIn(String roomId);

  /// Bumped on every jump so the view re-scrolls even to the same event.
  int jumpGenerationIn(String roomId);

  /// Whether newer messages than the jumped-to event are hidden. Always
  /// false now: the whole live timeline is loaded, nothing is hidden.
  bool hasNewerThanFocus(String roomId);

  /// Leaves the focused timeline for the live end of [roomId].
  Future<void> jumpToLatest(String roomId);
}

final _navigation = Expando<TimelineNavigation>('timeline navigation');

/// Timeline navigation for [backend], or null when it cannot focus events.
TimelineNavigation? timelineNavigationOf(ChatBackend backend) =>
    backend is TimelineNavigation
    ? backend as TimelineNavigation
    : backend is MatrixBackend
    ? _navigation[backend] ??= _MatrixTimelineNavigation(backend)
    : null;

class _MatrixTimelineNavigation implements TimelineNavigation {
  _MatrixTimelineNavigation(this._backend);
  final MatrixBackend _backend;

  @override
  Future<void> openRoomAt(String roomId, String eventId) =>
      _backend.openRoomAt(roomId, eventId);

  @override
  String? focusedEventIn(String roomId) =>
      _backend.activeRoomId == roomId ? _backend.focusedEventId : null;

  @override
  int jumpGenerationIn(String roomId) =>
      _backend.activeRoomId == roomId ? _backend.jumpGeneration : 0;

  @override
  bool hasNewerThanFocus(String roomId) =>
      _backend.activeRoomId == roomId && _backend.focusHasNewer;

  @override
  Future<void> jumpToLatest(String roomId) => _backend.jumpToLatest(roomId);
}
