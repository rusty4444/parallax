import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../room_events.dart';
import 'location_model.dart';
import 'poll_features.dart';
import 'poll_model.dart';

/// Matrix implementation of [PollFeatures] and [LocationFeatures].
///
/// Sends go through [RoomEventFeatures.sendRoomEvent] so session ownership,
/// recipient trust and fail-closed encryption apply. Relation metadata
/// (`m.relates_to`) is cleartext by Matrix spec, as in Element X.
///
/// Poll responses, ends and edits are not part of the core timeline
/// projection, so they are read here without core changes: the first time a
/// poll is shown its `m.reference` and `m.replace` relations are fetched from
/// the server `/relations` API (paged, bounded, decrypted read-only), and
/// later ones arrive through the client's live timeline/history streams.
/// The cache belongs to one SDK client; a session change drops it.
class MatrixPolls extends ChangeNotifier
    implements PollFeatures, LocationFeatures {
  MatrixPolls(this._access, this._events);

  final MatrixSdkAccess _access;
  final RoomEventFeatures _events;

  /// Upper bound on relation pages fetched per relation type and poll.
  static const maxRelationPages = 10;
  static const relationPageSize = 100;

  matrix.Client? _client;
  int _generation = 0;
  final _polls = <String, _PollRecord>{};
  final _subscriptions = <StreamSubscription<matrix.Event>>[];

  @override
  Listenable get pollUpdates => this;

  static String _key(String roomId, String pollId) => '$roomId\u0000$pollId';

  /// The current SDK client, resetting the cache when the session changed.
  /// Never notifies (may run during build).
  matrix.Client? _currentClient() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      if (_client != null) _reset();
      return null;
    }
    if (!identical(client, _client)) {
      _reset();
      _client = client;
      _subscriptions
        ..add(client.onTimelineEvent.stream.listen(_onEvent))
        ..add(client.onHistoryEvent.stream.listen(_onEvent));
    }
    return client;
  }

  void _reset() {
    _generation++;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();
    _polls.clear();
    _client = null;
  }

  bool _owns(matrix.Client client, int generation) =>
      identical(client, _client) &&
      generation == _generation &&
      _access.isSessionCurrent(client);

  @override
  PollSnapshot? pollSnapshot(String roomId, String pollId) {
    if (_currentClient() == null) return null;
    return _polls[_key(roomId, pollId)]?.snapshot;
  }

  @override
  void ensurePollLoaded(String roomId, String pollId, {bool retry = false}) {
    final client = _currentClient();
    if (client == null || !pollId.startsWith(r'$')) return;
    final key = _key(roomId, pollId);
    final existing = _polls[key];
    if (existing != null &&
        !(retry && existing.state == PollLoadState.failed)) {
      return;
    }
    final record = existing ?? (_polls[key] = _PollRecord());
    record.state = PollLoadState.loading;
    unawaited(_fetch(client, _generation, roomId, pollId, record));
  }

  Future<void> _fetch(
    matrix.Client client,
    int generation,
    String roomId,
    String pollId,
    _PollRecord record,
  ) async {
    var ok = false;
    try {
      // Yield first so callers in build/initState never see a notification.
      await Future<void>.value();
      final room = client.getRoomById(roomId);
      if (room == null) throw StateError('Unknown room');
      for (final relType in const [referenceRelation, replaceRelation]) {
        String? from;
        var pages = 0;
        do {
          final page = await client.getRelatingEventsWithRelType(
            roomId,
            pollId,
            relType,
            from: from,
            limit: relationPageSize,
          );
          if (!_owns(client, generation)) return;
          for (final raw in page.chunk) {
            var event = matrix.Event.fromMatrixEvent(raw, room);
            if (event.type == matrix.EventTypes.Encrypted) {
              final encryption = client.encryption;
              if (!client.encryptionEnabled || encryption == null) continue;
              event = await encryption.decryptRoomEvent(event);
              if (!_owns(client, generation)) return;
            }
            final relation = _relationFrom(event, pollId);
            if (relation != null) record.add(relation);
          }
          from = page.nextBatch;
          pages++;
        } while (from != null && pages < maxRelationPages);
      }
      ok = true;
    } catch (_) {
      ok = false;
    } finally {
      if (_owns(client, generation) &&
          identical(_polls[_key(roomId, pollId)], record)) {
        record.state = ok ? PollLoadState.ready : PollLoadState.failed;
        notifyListeners();
      }
    }
  }

  PollRelation? _relationFrom(matrix.Event event, String pollId) {
    if (event.redacted || event.relationshipEventId != pollId) return null;
    return PollRelation.fromEvent(
      eventId: event.eventId,
      type: event.type,
      sender: event.senderId,
      timestamp: event.originServerTs,
      content: event.content,
    );
  }

  void _onEvent(matrix.Event event) {
    final client = _client;
    if (client == null ||
        !identical(event.room.client, client) ||
        !_access.isSessionCurrent(client)) {
      return;
    }
    if (event.type == matrix.EventTypes.Redaction) {
      final redacts = event.redacts ?? event.content['redacts'];
      if (redacts is! String) return;
      var changed = false;
      for (final entry in _polls.entries) {
        if (entry.key.startsWith('${event.room.id}\u0000')) {
          changed = entry.value.remove(redacts) || changed;
        }
      }
      if (changed) notifyListeners();
      return;
    }
    // Local echoes carry transaction IDs; wait for the sent/synced copy.
    if (!event.status.isSent) return;
    final pollId = event.relationshipEventId;
    if (pollId == null) return;
    final record = _polls[_key(event.room.id, pollId)];
    if (record == null) return;
    final relation = _relationFrom(event, pollId);
    if (relation == null) return;
    record.add(relation);
    notifyListeners();
  }

  /// Records a relation we just sent so the UI updates before sync.
  void _recordSent(
    matrix.Client? client,
    int generation,
    String roomId,
    String pollId,
    PollRelation relation,
  ) {
    if (client == null || !_owns(client, generation)) return;
    final record = _polls[_key(roomId, pollId)];
    if (record == null) return;
    record.add(relation);
    notifyListeners();
  }

  @override
  bool mayEndPoll(String roomId, String userId, String pollSenderId) {
    if (userId == pollSenderId) return true;
    final client = _currentClient();
    final room = client?.getRoomById(roomId);
    if (room == null) return false;
    final redact =
        room
            .getState(matrix.EventTypes.RoomPowerLevels)
            ?.content
            .tryGet<int>('redact') ??
        matrix.PowerLevel.defaultModeratorLevel;
    return room.getPowerLevelByUserId(userId).level >= redact;
  }

  @override
  Future<String> createPoll(String roomId, PollStart poll) =>
      _events.sendRoomEvent(roomId, pollStartType, poll.toStartContent());

  @override
  Future<String> editPoll(String roomId, String pollId, PollStart poll) async {
    final client = _currentClient();
    final generation = _generation;
    final id = await _events.sendRoomEvent(
      roomId,
      pollStartType,
      poll.toEditContent(pollId),
    );
    final me = client?.userID;
    if (me != null) {
      _recordSent(
        client,
        generation,
        roomId,
        pollId,
        PollRelation(
          eventId: id,
          kind: PollRelationKind.edit,
          sender: me,
          timestamp: DateTime.now(),
          edit: poll,
        ),
      );
    }
    return id;
  }

  @override
  Future<String> respondToPoll(
    String roomId,
    String pollId,
    List<String> answerIds,
  ) async {
    final client = _currentClient();
    final generation = _generation;
    final id = await _events.sendRoomEvent(
      roomId,
      pollResponseType,
      pollResponseContent(pollId, answerIds),
    );
    final me = client?.userID;
    if (me != null) {
      _recordSent(
        client,
        generation,
        roomId,
        pollId,
        PollRelation(
          eventId: id,
          kind: PollRelationKind.response,
          sender: me,
          timestamp: DateTime.now(),
          answers: List.unmodifiable(answerIds),
        ),
      );
    }
    return id;
  }

  @override
  Future<String> endPoll(String roomId, String pollId) async {
    final client = _currentClient();
    final generation = _generation;
    final id = await _events.sendRoomEvent(
      roomId,
      pollEndType,
      pollEndContent(pollId),
    );
    final me = client?.userID;
    if (me != null) {
      _recordSent(
        client,
        generation,
        roomId,
        pollId,
        PollRelation(
          eventId: id,
          kind: PollRelationKind.end,
          sender: me,
          timestamp: DateTime.now(),
        ),
      );
    }
    return id;
  }

  @override
  Future<void> deletePoll(String roomId, String pollId) =>
      _events.redactEvent(roomId, pollId);

  @override
  Future<String> shareLocation(
    String roomId,
    GeoPoint point, {
    required LocationAsset asset,
    String? description,
  }) {
    if (!point.isValid) throw ArgumentError.value(point, 'point');
    return _events.sendRoomEvent(
      roomId,
      matrix.EventTypes.Message,
      locationContent(
        point: point,
        asset: asset,
        description: description,
        now: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }
}

class _PollRecord {
  PollLoadState _state = PollLoadState.loading;
  final _relations = <String, PollRelation>{};
  PollSnapshot? _snapshot;

  /// Bounds memory for pathological rooms.
  static const maxRelations = 5000;

  PollLoadState get state => _state;
  set state(PollLoadState value) {
    _state = value;
    _snapshot = null;
  }

  void add(PollRelation relation) {
    if (_relations.length >= maxRelations &&
        !_relations.containsKey(relation.eventId)) {
      return;
    }
    _relations[relation.eventId] = relation;
    _snapshot = null;
  }

  bool remove(String eventId) {
    final removed = _relations.remove(eventId) != null;
    if (removed) _snapshot = null;
    return removed;
  }

  PollSnapshot get snapshot => _snapshot ??= PollSnapshot(
    state: _state,
    relations: List.unmodifiable(_relations.values),
  );
}
