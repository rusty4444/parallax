import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../message_text.dart';
import '../../room_events.dart';
import '../../timeline_kinds.dart';
import 'message_action_features.dart';

const pinnedEventsType = 'm.room.pinned_events';
const _ignoredUsersType = 'm.ignored_user_list';
const _maxPinnedEvents = 100;
const _maxReactionPages = 5;
const _eventCacheLimit = 64;
const _eventCacheTtl = Duration(minutes: 2);

/// [MessageActionFeatures] over the live Matrix backend.
///
/// Reads use the SDK client from [MatrixSdkAccess]; every write goes through
/// [RoomEventFeatures] so the session, trust and encryption guards apply.
class MatrixMessageActions implements MessageActionFeatures {
  MatrixMessageActions(Object backend)
    : _sdk = backend as MatrixSdkAccess,
      _events = backend as RoomEventFeatures;

  final MatrixSdkAccess _sdk;
  final RoomEventFeatures _events;

  /// Pin writes are read-modify-write; serialise them per room so a double
  /// tap cannot lose an update.
  final _pinWrites = <String, Future<void>>{};
  final _eventCache = <String, _CachedEntry>{};
  matrix.Client? _cacheOwner;

  matrix.Client _requireClient() {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) {
      throw StateError('Matrix is not available');
    }
    return client;
  }

  void _checkCurrent(matrix.Client client) {
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
  }

  @override
  MessageActionPermissions permissions(String roomId) {
    final client = _sdk.sdkClient;
    final room = client?.getRoomById(roomId);
    if (client == null ||
        room == null ||
        room.membership != matrix.Membership.join ||
        !_sdk.isSessionCurrent(client)) {
      return MessageActionPermissions.none;
    }
    return MessageActionPermissions(
      canReact: room.canSendEvent(matrix.EventTypes.Reaction),
      canPin: room.canChangeStateEvent(pinnedEventsType),
      canRedactOthers: room.canRedact,
      canSendMessages: room.canSendDefaultMessages,
    );
  }

  @override
  List<String> pinnedEventIds(String roomId) {
    final client = _sdk.sdkClient;
    final room = client?.getRoomById(roomId);
    if (room == null) return const [];
    return pinnedIdsFrom(room.getState(pinnedEventsType)?.content['pinned']);
  }

  @override
  Future<void> setPinned(
    String roomId,
    String eventId, {
    required bool pinned,
  }) {
    if (!eventId.startsWith(r'$')) {
      throw ArgumentError.value(eventId, 'eventId', 'Not a server event');
    }
    final previous = _pinWrites[roomId] ?? Future<void>.value();
    final next = previous
        .catchError((Object _) {})
        .then((_) => _writePin(roomId, eventId, pinned));
    _pinWrites[roomId] = next;
    return next.whenComplete(() {
      if (identical(_pinWrites[roomId], next)) _pinWrites.remove(roomId);
    });
  }

  Future<void> _writePin(String roomId, String eventId, bool pin) async {
    final client = _requireClient();
    if (!permissions(roomId).canPin) {
      throw StateError('You do not have permission to pin messages here');
    }
    // Re-read the server's current list: the local copy can be stale and a
    // blind write would drop pins added by someone else.
    final current = await _events.roomState(roomId, pinnedEventsType);
    _checkCurrent(client);
    final ids = pinnedIdsFrom(current?['pinned']).toList();
    if (pin) {
      if (ids.contains(eventId)) return;
      if (ids.length >= _maxPinnedEvents) {
        throw StateError('This room already has too many pinned messages');
      }
      ids.add(eventId);
    } else if (!ids.remove(eventId)) {
      return;
    }
    await _events.setRoomState(roomId, pinnedEventsType, {
      ...?current,
      'pinned': ids,
    });
    _checkCurrent(client);
  }

  @override
  Future<ChatEntry?> loadEvent(String roomId, String eventId) async {
    final client = _requireClient();
    if (!identical(_cacheOwner, client)) {
      _eventCache.clear();
      _cacheOwner = client;
    }
    final key = '$roomId\n$eventId';
    final cached = _eventCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < _eventCacheTtl) {
      return cached.entry;
    }
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Room unavailable');
    final event = await room.getEventById(eventId);
    _checkCurrent(client);
    if (event == null) return null;
    final entry = entryFromSdkEvent(event, client.userID);
    _eventCache.remove(key);
    _eventCache[key] = _CachedEntry(entry, DateTime.now());
    while (_eventCache.length > _eventCacheLimit) {
      _eventCache.remove(_eventCache.keys.first);
    }
    return entry;
  }

  @override
  Future<List<ReactionSender>> reactionSenders(
    String roomId,
    String eventId,
  ) async {
    final client = _requireClient();
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Room unavailable');
    final seen = <String>{};
    final senders = <ReactionSender>[];
    String? from;
    var pages = 0;
    do {
      final page = await client.getRelatingEventsWithRelType(
        roomId,
        eventId,
        matrix.RelationshipTypes.reaction,
        from: from,
        limit: 100,
        dir: matrix.Direction.b,
      );
      _checkCurrent(client);
      for (final event in page.chunk) {
        // The annotation key lives in the cleartext relation for encrypted
        // and plaintext reactions alike, so no decryption is needed here.
        final relation = event.content['m.relates_to'];
        if (relation is! Map) continue;
        final key = relation['key'];
        if (relation['rel_type'] != matrix.RelationshipTypes.reaction ||
            relation['event_id'] != eventId ||
            key is! String ||
            key.isEmpty ||
            key.runes.length > 16 ||
            !seen.add('$key\n${event.senderId}')) {
          continue;
        }
        senders.add(
          ReactionSender(
            emoji: key,
            userId: event.senderId,
            displayName: _cachedName(room, event.senderId),
            time: event.originServerTs,
          ),
        );
      }
      from = page.nextBatch;
      pages++;
    } while (from != null && from.isNotEmpty && pages < _maxReactionPages);
    senders.sort((a, b) {
      final at = a.time, bt = b.time;
      if (at == null || bt == null) return a.userId.compareTo(b.userId);
      return at.compareTo(bt);
    });
    return List.unmodifiable(senders);
  }

  /// Cached membership only: never trigger member fetches from UI reads.
  String? _cachedName(matrix.Room room, String userId) {
    final name = room
        .getState(matrix.EventTypes.RoomMember, userId)
        ?.content['displayname'];
    return name is String && name.trim().isNotEmpty ? name : null;
  }

  @override
  Future<String> forwardEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) => _events.sendRoomEvent(roomId, type, content);

  @override
  Future<void> reportContent(
    String roomId,
    String eventId, {
    required String reason,
  }) async {
    final client = _requireClient();
    await client.reportEvent(roomId, eventId, reason: reason);
    _checkCurrent(client);
  }

  @override
  Future<void> ignoreUser(String userId) async {
    final client = _requireClient();
    final ownId = client.userID;
    if (ownId == null) throw StateError('Matrix is not available');
    if (userId == ownId ||
        !userId.startsWith('@') ||
        !userId.isValidMatrixIdStrict()) {
      throw ArgumentError.value(userId, 'userId', 'Invalid user');
    }
    // Read-modify-write the server copy so a concurrent change elsewhere is
    // not lost. Avoid Client.ignoreUser: it clears the whole local cache.
    Map<String, Object?> current;
    try {
      current = await client.getAccountData(ownId, _ignoredUsersType);
    } on matrix.MatrixException catch (error) {
      if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
      current = const {};
    }
    _checkCurrent(client);
    final ignored = current['ignored_users'];
    await client.setAccountData(ownId, _ignoredUsersType, {
      ...current,
      'ignored_users': {
        if (ignored is Map)
          for (final entry in ignored.entries)
            if (entry.key is String) entry.key as String: entry.value,
        userId: <String, Object?>{},
      },
    });
    _checkCurrent(client);
  }

  @override
  Future<void> removeEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async {
    final trimmed = reason?.trim();
    await _events.redactEvent(
      roomId,
      eventId,
      reason: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }
}

class _CachedEntry {
  _CachedEntry(this.entry, this.loadedAt);
  final ChatEntry entry;
  final DateTime loadedAt;
}

/// Valid, unique event IDs from untrusted `m.room.pinned_events` content.
List<String> pinnedIdsFrom(Object? pinned) {
  if (pinned is! List) return const [];
  final ids = <String>[];
  for (final id in pinned) {
    if (id is String &&
        id.startsWith(r'$') &&
        id.length <= 255 &&
        !ids.contains(id)) {
      ids.add(id);
    }
    if (ids.length >= _maxPinnedEvents) break;
  }
  return List.unmodifiable(ids);
}

/// A minimal timeline projection of an SDK event fetched outside the live
/// timeline (pinned previews). Edits are not applied.
ChatEntry entryFromSdkEvent(matrix.Event event, String? ownUserId) {
  final redacted = event.redacted;
  final content = redacted
      ? const <String, Object?>{}
      : Map<String, Object?>.unmodifiable(event.content);
  final kind = entryKindFor(
    type: event.type,
    msgtype: event.messageType,
    content: content,
    redacted: redacted,
  );
  final replyTo = event.inReplyToEventId(includingFallback: false);
  final member = event.room.getState(
    matrix.EventTypes.RoomMember,
    event.senderId,
  );
  final memberName = member?.content['displayname'];
  final memberAvatar = member?.content['avatar_url'];
  final format = content['format'];
  final formatted = content['formatted_body'];
  String body;
  if (redacted) {
    body = 'Message removed';
  } else if (event.type == matrix.EventTypes.Encrypted) {
    body = '🔒 Unable to decrypt this message';
  } else if (event.type == matrix.EventTypes.Message ||
      event.type == matrix.EventTypes.Sticker) {
    body = visibleMessageBody(event.body, isReply: replyTo != null);
  } else {
    try {
      body = event.calcLocalizedBodyFallback(
        const matrix.MatrixDefaultLocalizations(),
        hideReply: true,
      );
    } catch (_) {
      body = event.type;
    }
  }
  return ChatEntry(
    id: event.eventId,
    sender: event.senderId,
    body: body,
    time: event.originServerTs,
    mine: event.senderId == ownUserId,
    isImage:
        !redacted &&
        (event.messageType == matrix.MessageTypes.Image ||
            event.type == matrix.EventTypes.Sticker),
    isAttachment:
        !redacted &&
        event.type == matrix.EventTypes.Message &&
        {
          matrix.MessageTypes.File,
          matrix.MessageTypes.Audio,
          matrix.MessageTypes.Video,
        }.contains(event.messageType),
    replyToId: replyTo,
    redacted: redacted,
    kind: kind,
    eventType: event.type,
    msgtype: event.type == matrix.EventTypes.Message ? event.messageType : null,
    formattedBody: format == 'org.matrix.custom.html' && formatted is String
        ? formatted
        : null,
    senderName: memberName is String ? memberName : null,
    senderAvatar: memberAvatar is String ? Uri.tryParse(memberAvatar) : null,
    content: content,
    pinned: event.room.pinnedEventIds.contains(event.eventId),
  );
}
