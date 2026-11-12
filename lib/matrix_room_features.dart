import 'package:matrix/matrix.dart';

import 'chat_backend.dart';
import 'features/threads/thread_models.dart';
import 'messaging_features.dart';

/// Account-bound SDK operations shared by the optional messaging screens.
/// Construct a new instance for every account/session generation.
class MatrixRoomFeatures {
  MatrixRoomFeatures(
    this.client, {
    required this.ownerCurrent,
    required this.mapEvent,
  }) : _userId = client.userID,
       _homeserver = client.homeserver,
       _token = client.accessToken;

  final Client client;
  final bool Function() ownerCurrent;
  final ChatEntry Function(Event) mapEvent;
  final String? _userId;
  final Uri? _homeserver;
  final String? _token;
  // Backends may create a helper per call. Share ordering by SDK client rather
  // than by helper lifetime, without retaining a logged-out client globally.
  static final _writeQueues = Expando<Map<String, Future<void>>>();
  Map<String, Future<void>> get _favouriteWrites =>
      _writeQueues[client] ??= <String, Future<void>>{};

  void _checkOwner() {
    if (!ownerCurrent() ||
        _userId == null ||
        client.userID != _userId ||
        client.homeserver != _homeserver ||
        client.accessToken != _token) {
      throw StateError('This account session is no longer current.');
    }
  }

  Future<T> _owned<T>(Future<T> Function() operation) async {
    _checkOwner();
    try {
      final value = await operation();
      _checkOwner();
      return value;
    } catch (_) {
      _checkOwner();
      rethrow;
    }
  }

  Room _room(String id) {
    _checkOwner();
    final room = client.getRoomById(id);
    if (room == null) throw StateError('Room is no longer available.');
    return room;
  }

  Future<List<DirectoryUser>> searchUsers(String query) => _owned(() async {
    final term = query.trim();
    if (term.isEmpty) return const <DirectoryUser>[];
    final response = await client.searchUserDirectory(term, limit: 50);
    _checkOwner();
    final known = <String>{};
    return [
      for (final profile in response.results)
        if (known.add(profile.userId))
          DirectoryUser(
            id: profile.userId,
            name: profile.displayName,
            avatar: profile.avatarUrl,
          ),
    ];
  });

  List<SpaceSummary> get spaces {
    _checkOwner();
    final result = [
      for (final room in client.rooms)
        if (room.isSpace && room.membership == Membership.join)
          SpaceSummary(
            id: room.id,
            name: room.getLocalizedDisplayname(),
            topic: room.topic,
            members: room.summary.mJoinedMemberCount ?? 0,
            isSpace: true,
            joined: true,
          ),
    ];
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) =>
      _owned(() async {
        final response = await client.getSpaceHierarchy(
          spaceId,
          from: nextBatch,
          limit: 50,
          maxDepth: 1,
          suggestedOnly: false,
        );
        _checkOwner();
        final known = <String>{spaceId};
        return SpacePage([
          for (final room in response.rooms)
            if (known.add(room.roomId))
              SpaceSummary(
                id: room.roomId,
                name: room.name ?? room.canonicalAlias ?? room.roomId,
                topic: room.topic,
                members: room.numJoinedMembers,
                isSpace: room.roomType == 'm.space',
                joined:
                    client.getRoomById(room.roomId)?.membership ==
                    Membership.join,
              ),
        ], nextBatch: response.nextBatch);
      });

  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) => _owned(() async {
    final room = _room(roomId);
    final response = await client.getRelatingEventsWithRelType(
      roomId,
      rootEventId,
      RelationshipTypes.thread,
      from: nextBatch,
      limit: 50,
      dir: Direction.b,
      recurse: false,
    );
    _checkOwner();
    final entries = <String, ChatEntry>{};
    for (final raw in response.chunk) {
      var event = Event.fromMatrixEvent(raw, room);
      if (event.type == EventTypes.Encrypted && client.encryption != null) {
        event = await client.encryption!.decryptRoomEvent(event);
        _checkOwner();
      }
      if (event.eventId == rootEventId ||
          (event.type != EventTypes.Message &&
              event.type != EventTypes.Encrypted)) {
        continue;
      }
      entries[event.eventId] = mapEvent(event);
    }
    final messages = entries.values.toList()
      ..sort((a, b) {
        final time = a.time.compareTo(b.time);
        return time == 0 ? a.id.compareTo(b.id) : time;
      });
    return ThreadPage(messages, nextBatch: response.nextBatch);
  });

  Future<Event> _decrypted(Event event) async {
    if (event.type != EventTypes.Encrypted || client.encryption == null) {
      return event;
    }
    final decrypted = await client.encryption!.decryptRoomEvent(event);
    _checkOwner();
    return decrypted;
  }

  /// Thread roots in [roomId], most recent activity first, via
  /// `GET /_matrix/client/v1/rooms/{roomId}/threads`. Each root carries the
  /// server's bundled `m.thread` summary (reply count, latest reply and
  /// participation). Encrypted roots and latest replies are decrypted
  /// locally when keys are available.
  Future<ThreadListPage> loadThreadRoots(
    String roomId, {
    ThreadListFilter filter = ThreadListFilter.all,
    String? nextBatch,
    int limit = 25,
  }) => _owned(() async {
    final room = _room(roomId);
    final response = await client.getThreadRoots(
      roomId,
      include: filter == ThreadListFilter.participated
          ? Include.participated
          : Include.all,
      limit: limit,
      from: nextBatch,
    );
    _checkOwner();
    final seen = <String>{};
    final threads = <ThreadSummary>[];
    for (final raw in response.chunk) {
      if (!seen.add(raw.eventId)) continue;
      final root = await _decrypted(Event.fromMatrixEvent(raw, room));
      final relations = raw.unsigned?['m.relations'];
      final summary = relations is Map ? relations['m.thread'] : null;
      final latestRaw = summary is Map ? summary['latest_event'] : null;
      Event? latest;
      if (latestRaw is Map) {
        try {
          latest = await _decrypted(
            Event.fromJson(Map<String, dynamic>.from(latestRaw), room),
          );
        } on StateError {
          rethrow;
        } catch (_) {
          // A malformed bundled event must not hide the thread itself.
        }
      }
      final count = summary is Map ? summary['count'] : null;
      threads.add(
        ThreadSummary(
          root: mapEvent(root),
          latest: latest == null ? null : mapEvent(latest),
          replyCount: count is num ? count.toInt().clamp(0, 1 << 30) : 0,
          participated:
              summary is Map && summary['current_user_participated'] == true,
          unread: latest == null
              ? null
              : threadUnread(room, raw.eventId, latest),
        ),
      );
    }
    final next = response.nextBatch;
    return ThreadListPage(
      threads,
      nextBatch: next == null || next.isEmpty || next == nextBatch
          ? null
          : next,
    );
  });

  /// Whether [latest] is newer than this account's threaded read receipt in
  /// [rootId]. Null when there is no threaded receipt to compare with: unread
  /// state is then unknown rather than inferred.
  bool? threadUnread(Room room, String rootId, Event latest) {
    if (latest.senderId == _userId) return false;
    final own = room.receiptState.byThread[rootId]?.latestOwnReceipt;
    if (own == null) return null;
    if (own.eventId == latest.eventId) return false;
    return latest.originServerTs.isAfter(own.timestamp);
  }

  /// Sends a threaded read receipt (`thread_id` = [rootId]) for [eventId], a
  /// reply in that thread. Private (`m.read.private`) when [public] is false.
  /// Skips the request when this receipt is already the latest own one.
  Future<void> sendThreadReceipt(
    String roomId,
    String rootId,
    String eventId, {
    required bool public,
  }) => _owned(() async {
    final room = _room(roomId);
    if (room.membership != Membership.join) {
      throw StateError('Room is not joined.');
    }
    if (!eventId.startsWith(r'$') || eventId == rootId) return;
    final own = room.receiptState.byThread[rootId]?.latestOwnReceipt;
    if (own?.eventId == eventId) return;
    await client.postReceipt(
      roomId,
      public ? ReceiptType.mRead : ReceiptType.mReadPrivate,
      eventId,
      threadId: rootId,
    );
  });

  /// Matrix exposes receipts through sync, not a per-event HTTP endpoint.
  /// These are exact latest receipt pointers, not an inference that everyone
  /// with a later timestamp must have read this event.
  Future<List<MessageReader>> messageReaders(String roomId, String eventId) =>
      _owned(() async {
        final room = _room(roomId);
        final state = room.receiptState;
        final readers = <String, MessageReader>{};
        for (final timeline in [
          state.global,
          ?state.mainThread,
          ...state.byThread.values,
        ]) {
          void add(String userId, LatestReceiptStateData receipt) {
            if (receipt.eventId != eventId) return;
            final previous = readers[userId];
            if (previous?.time != null &&
                !receipt.timestamp.isAfter(previous!.time!)) {
              return;
            }
            final displayName = room
                .getState(EventTypes.RoomMember, userId)
                ?.content['displayname'];
            readers[userId] = MessageReader(
              userId: userId,
              name: displayName is String && displayName.trim().isNotEmpty
                  ? displayName
                  : userId,
              time: receipt.timestamp,
            );
          }

          for (final entry in timeline.otherUsers.entries) {
            add(entry.key, entry.value);
          }
          if (timeline.latestOwnReceipt case final own?) add(_userId!, own);
        }
        return readers.values.toList()
          ..sort((a, b) => b.time!.compareTo(a.time!));
      });

  bool isFavourite(String roomId) => _room(roomId).isFavourite;

  Future<void> setFavourite(String roomId, bool favourite) {
    final previous = _favouriteWrites[roomId] ?? Future<void>.value();
    final operation = previous.then(
      (_) => _owned(() async {
        final room = _room(roomId);
        await room.setFavourite(favourite);
        _checkOwner();
        final tags = await client.getRoomTags(_userId!, roomId);
        _checkOwner();
        if ((tags?.containsKey(TagType.favourite) ?? false) != favourite) {
          throw StateError('The server did not confirm the favourite change.');
        }
        room.roomAccountData['m.tag'] = BasicEvent(
          type: 'm.tag',
          content: {
            'tags': {
              for (final entry in (tags ?? <String, Tag>{}).entries)
                entry.key: entry.value.toJson(),
            },
          },
        );
      }),
    );
    // A failed write must not poison later retries, while each caller still
    // receives its own failure. Serialise readback with the following write.
    _favouriteWrites[roomId] = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
