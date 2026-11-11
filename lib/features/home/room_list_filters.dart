import '../../chat_backend.dart';

/// Element X room list filters (`features/home/impl/filters`), plus the
/// Low priority filter Element X exposes for `m.lowpriority` rooms.
enum RoomListFilter {
  unread('Unread'),
  people('People'),
  rooms('Rooms'),
  favourites('Favourites'),
  lowPriority('Low priority'),
  invites('Invites');

  const RoomListFilter(this.label);
  final String label;

  /// Selecting this filter deselects these (Element X incompatibleFilters).
  Set<RoomListFilter> get incompatible => switch (this) {
    rooms => const {people, invites},
    people => const {rooms, invites},
    unread => const {invites},
    favourites => const {invites, lowPriority},
    lowPriority => const {invites, favourites},
    invites => const {rooms, people, unread, favourites, lowPriority},
  };
}

/// Toggles [filter], removing filters that cannot be combined with it.
Set<RoomListFilter> toggleRoomListFilter(
  Set<RoomListFilter> selected,
  RoomListFilter filter,
) {
  if (selected.contains(filter)) return {...selected}..remove(filter);
  return {...selected.where((f) => !filter.incompatible.contains(f)), filter};
}

/// Inputs that do not live on [ChatRoom] itself.
class RoomListContext {
  const RoomListContext({
    this.favourites = const {},
    this.failedRooms = const {},
    this.spaceRooms,
    this.query = '',
  });

  /// Favourites known from another source (for example MessagingFeatures).
  final Set<String> favourites;

  /// Rooms with a failed send stay reachable from Unread.
  final Set<String> failedRooms;

  /// When a Space is selected, only these room IDs are shown.
  final Set<String>? spaceRooms;
  final String query;
}

bool isRoomFavourite(ChatRoom room, RoomListContext context) =>
    room.favourite || context.favourites.contains(room.id);

bool isRoomUnread(ChatRoom room, RoomListContext context) =>
    room.unread > 0 ||
    room.highlightCount > 0 ||
    room.manuallyUnread ||
    context.failedRooms.contains(room.id);

bool _matches(ChatRoom room, RoomListFilter filter, RoomListContext context) =>
    switch (filter) {
      RoomListFilter.unread => !room.invited && isRoomUnread(room, context),
      RoomListFilter.people => !room.invited && room.isDirect,
      RoomListFilter.rooms => !room.invited && !room.isDirect,
      RoomListFilter.favourites =>
        !room.invited && isRoomFavourite(room, context),
      RoomListFilter.lowPriority => !room.invited && room.lowPriority,
      RoomListFilter.invites => room.invited,
    };

/// Filters and orders the home room list like Element X: Spaces are not
/// chats; all selected filters must match; invites first, then favourites,
/// then the backend's recency order, with low-priority rooms last.
List<ChatRoom> filterRoomList(
  List<ChatRoom> rooms,
  Set<RoomListFilter> filters,
  RoomListContext context,
) {
  final query = context.query.trim().toLowerCase();
  final order = {for (final (index, room) in rooms.indexed) room.id: index};
  final result = [
    for (final room in rooms)
      if (!room.isSpace &&
          (context.spaceRooms?.contains(room.id) ?? true) &&
          filters.every((filter) => _matches(room, filter, context)) &&
          (query.isEmpty ||
              room.name.toLowerCase().contains(query) ||
              room.id.toLowerCase().contains(query) ||
              (room.canonicalAlias?.toLowerCase().contains(query) ?? false)))
        room,
  ];
  int rank(ChatRoom room) => room.invited
      ? 0
      : isRoomFavourite(room, context)
      ? 1
      : room.lowPriority
      ? 3
      : 2;
  result.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : order[a.id]!.compareTo(order[b.id]!);
  });
  return result;
}

/// Element X empty-state copy for the current selection, or null when no
/// filter or Space is selected.
({String title, String subtitle})? roomListEmptyState(
  Set<RoomListFilter> filters, {
  bool spaceSelected = false,
}) {
  const mixedSubtitle =
      'You can deselect filters in order to see your other chats';
  if (spaceSelected && filters.isEmpty) {
    return (
      title: 'No chats in this Space yet',
      subtitle: 'Chats you join in this Space will appear here.',
    );
  }
  if (filters.isEmpty) return null;
  if (filters.length > 1 || spaceSelected) {
    return (
      title: 'You don’t have chats for this selection',
      subtitle: mixedSubtitle,
    );
  }
  return switch (filters.single) {
    RoomListFilter.unread => (
      title: 'Congrats! You don’t have any unread messages!',
      subtitle: mixedSubtitle,
    ),
    RoomListFilter.people => (
      title: 'You don’t have any DMs yet',
      subtitle: mixedSubtitle,
    ),
    RoomListFilter.rooms => (
      title: 'You’re not in any room yet',
      subtitle: mixedSubtitle,
    ),
    RoomListFilter.favourites => (
      title: 'You don’t have favourite chats yet',
      subtitle:
          'You can add a chat to your favourites from its long-press menu.',
    ),
    RoomListFilter.lowPriority => (
      title: 'You don’t have any low priority chats yet',
      subtitle: mixedSubtitle,
    ),
    RoomListFilter.invites => (
      title: 'You don’t have any pending invites',
      subtitle: mixedSubtitle,
    ),
  };
}
