import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/features/polls/matrix_polls.dart';
import 'package:parallax/features/polls/poll_features.dart';
import 'package:parallax/features/polls/poll_model.dart';
import 'package:parallax/room_events.dart';

const _roomId = '!room:example.org';
const _pollId = r'$poll';
const _me = '@sam:example.org';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client({required this.relations})
    : super(
        'polls-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
    room = matrix.Room(id: _roomId, client: this);
  }

  late final matrix.Room room;
  final Map<String, List<Map<String, Object?>>> relations;
  final relationRequests = <String>[];
  Completer<void>? relationGate;

  @override
  String? get userID => _me;

  @override
  matrix.Room? getRoomById(String id) => id == _roomId ? room : null;

  @override
  Future<matrix.GetRelatingEventsWithRelTypeResponse>
  getRelatingEventsWithRelType(
    String roomId,
    String eventId,
    String relType, {
    String? from,
    String? to,
    int? limit,
    matrix.Direction? dir,
    bool? recurse,
  }) async {
    relationRequests.add('$eventId/$relType/${from ?? ''}');
    await relationGate?.future;
    final events = relations[relType] ?? const [];
    // Two pages to exercise pagination.
    final page = from == null
        ? events.take(1).toList()
        : events.skip(1).toList();
    return matrix.GetRelatingEventsWithRelTypeResponse(
      chunk: [
        for (final json in page)
          matrix.MatrixEvent.fromJson(jsonDecode(jsonEncode(json))),
      ],
      nextBatch: from == null && events.length > 1 ? 'next' : null,
    );
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Backend implements MatrixSdkAccess, RoomEventFeatures {
  _Backend(this.client);
  final _Client client;
  bool current = true;
  final sent = <({String room, String type, Map<String, Object?> content})>[];
  final redacted = <String>[];
  int _next = 0;

  @override
  matrix.Client? get sdkClient => current ? client : null;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    sent.add((room: roomId, type: type, content: content));
    return '\$sent${_next++}';
  }

  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async => redacted.add(eventId);

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async => null;

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {}
}

Map<String, Object?> _rawVote(
  String id,
  String sender,
  int ts,
  String answer,
) => {
  'event_id': id,
  'type': pollResponseType,
  'sender': sender,
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': pollResponseContent(_pollId, [answer]),
};

matrix.Event _event(
  _Client client, {
  required String id,
  required String type,
  required String sender,
  required int ts,
  required Map<String, Object?> content,
  matrix.EventStatus status = matrix.EventStatus.synced,
  String? redacts,
}) => matrix.Event(
  content: content,
  type: type,
  eventId: id,
  senderId: sender,
  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
  room: client.room,
  status: status,
  redacts: redacts,
);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _poll = PollStart(
  question: 'Lunch?',
  answers: [
    PollAnswer(id: 'a', text: 'Pizza'),
    PollAnswer(id: 'b', text: 'Sushi'),
  ],
);

void main() {
  test('resolves via MatrixSdkAccess + RoomEventFeatures with one cache', () {
    final backend = _Backend(_Client(relations: const {}));
    final polls = pollFeaturesOf(_ChatBackendAdapter(backend));
    expect(polls, isNull, reason: 'plain ChatBackend has no poll support');
    final adapter = _MatrixChatBackend(backend);
    final first = pollFeaturesOf(adapter);
    expect(first, isA<MatrixPolls>());
    expect(identical(first, pollFeaturesOf(adapter)), isTrue);
    expect(identical(first, locationFeaturesOf(adapter)), isTrue);
  });

  test('all sends go through RoomEventFeatures.sendRoomEvent', () async {
    final backend = _Backend(_Client(relations: const {}));
    final polls = MatrixPolls(backend, backend);
    await polls.createPoll(_roomId, _poll);
    await polls.respondToPoll(_roomId, _pollId, ['a']);
    await polls.endPoll(_roomId, _pollId);
    await polls.editPoll(_roomId, _pollId, _poll);
    await polls.shareLocation(
      _roomId,
      const GeoPoint(-33.86, 151.21),
      asset: LocationAsset.self,
    );
    await polls.deletePoll(_roomId, _pollId);
    expect(backend.sent.map((s) => s.type), [
      pollStartType,
      pollResponseType,
      pollEndType,
      pollStartType,
      'm.room.message',
    ]);
    expect(backend.sent[1].content['m.relates_to'], {
      'rel_type': 'm.reference',
      'event_id': _pollId,
    });
    expect(
      (backend.sent[3].content['m.relates_to'] as Map)['rel_type'],
      'm.replace',
    );
    expect(backend.sent[4].content['msgtype'], 'm.location');
    expect(
      (backend.sent[4].content['org.matrix.msc3488.asset'] as Map)['type'],
      'm.self',
    );
    expect(backend.redacted, [_pollId]);
    polls.dispose();
  });

  test('loads relations from /relations, paginates and tallies', () async {
    final client = _Client(
      relations: {
        'm.reference': [
          _rawVote(r'$v1', '@a:x', 1, 'a'),
          _rawVote(r'$v2', '@b:x', 2, 'b'),
          {
            'event_id': r'$end',
            'type': pollEndType,
            'sender': '@stranger:x',
            'origin_server_ts': 3,
            'room_id': _roomId,
            'content': pollEndContent(_pollId),
          },
        ],
        'm.replace': const [],
      },
    );
    final backend = _Backend(client);
    final polls = MatrixPolls(backend, backend);
    var notifications = 0;
    polls.addListener(() => notifications++);

    polls.ensurePollLoaded(_roomId, _pollId);
    expect(notifications, 0, reason: 'never notifies synchronously');
    expect(polls.pollSnapshot(_roomId, _pollId)!.state, PollLoadState.loading);
    polls.ensurePollLoaded(_roomId, _pollId);
    await _settle();

    expect(client.relationRequests, [
      '$_pollId/m.reference/',
      '$_pollId/m.reference/next',
      '$_pollId/m.replace/',
    ]);
    final snapshot = polls.pollSnapshot(_roomId, _pollId)!;
    expect(snapshot.state, PollLoadState.ready);
    expect(snapshot.relations, hasLength(3));
    expect(notifications, 1);

    final results = computePollResults(
      original: _poll,
      pollSender: '@creator:x',
      relations: snapshot.relations,
      myUserId: _me,
      mayEnd: (user) => polls.mayEndPoll(_roomId, user, '@creator:x'),
    );
    expect(results.ended, isFalse, reason: 'stranger lacks redact power');
    expect(results.counts, {'a': 1, 'b': 1});
    polls.dispose();
  });

  test('live sync events, own sends and redactions update the poll', () async {
    final client = _Client(relations: const {});
    final backend = _Backend(client);
    final polls = MatrixPolls(backend, backend);
    polls.ensurePollLoaded(_roomId, _pollId);
    await _settle();

    // A local echo (still sending) is ignored until the server copy arrives.
    client.onTimelineEvent.add(
      _event(
        client,
        id: 'txn1',
        type: pollResponseType,
        sender: '@a:x',
        ts: 1,
        content: pollResponseContent(_pollId, ['a']),
        status: matrix.EventStatus.sending,
      ),
    );
    client.onTimelineEvent.add(
      _event(
        client,
        id: r'$live',
        type: pollResponseType,
        sender: '@a:x',
        ts: 2,
        content: pollResponseContent(_pollId, ['a']),
      ),
    );
    // Responses to other polls are not tracked.
    client.onTimelineEvent.add(
      _event(
        client,
        id: r'$other',
        type: pollResponseType,
        sender: '@b:x',
        ts: 2,
        content: pollResponseContent(r'$elsewhere', ['a']),
      ),
    );
    await _settle();
    expect(
      polls.pollSnapshot(_roomId, _pollId)!.relations.map((r) => r.eventId),
      [r'$live'],
    );

    final sentId = await polls.respondToPoll(_roomId, _pollId, ['b']);
    expect(
      polls.pollSnapshot(_roomId, _pollId)!.relations.map((r) => r.eventId),
      [r'$live', sentId],
    );

    client.onTimelineEvent.add(
      _event(
        client,
        id: r'$redaction',
        type: 'm.room.redaction',
        sender: '@a:x',
        ts: 3,
        content: const {},
        redacts: r'$live',
      ),
    );
    await _settle();
    expect(
      polls.pollSnapshot(_roomId, _pollId)!.relations.map((r) => r.eventId),
      [sentId],
    );
    polls.dispose();
  });

  test('moderators with redaction power may end others’ polls', () {
    final client = _Client(relations: const {});
    client.room.setState(
      matrix.Event(
        type: 'm.room.power_levels',
        content: {
          'redact': 50,
          'users': {'@mod:x': 50, _me: 0},
        },
        eventId: r'$pl',
        senderId: '@mod:x',
        originServerTs: DateTime(2026),
        stateKey: '',
        room: client.room,
      ),
    );
    final backend = _Backend(client);
    final polls = MatrixPolls(backend, backend);
    expect(polls.mayEndPoll(_roomId, '@creator:x', '@creator:x'), isTrue);
    expect(polls.mayEndPoll(_roomId, '@mod:x', '@creator:x'), isTrue);
    expect(polls.mayEndPoll(_roomId, _me, '@creator:x'), isFalse);
    polls.dispose();
  });

  test('a session change drops the cache and stale fetches', () async {
    final client = _Client(
      relations: {
        'm.reference': [_rawVote(r'$v1', '@a:x', 1, 'a')],
      },
    );
    client.relationGate = Completer<void>();
    final backend = _Backend(client);
    final polls = MatrixPolls(backend, backend);
    var notifications = 0;
    polls.addListener(() => notifications++);
    polls.ensurePollLoaded(_roomId, _pollId);
    await _settle();

    backend.current = false;
    expect(polls.pollSnapshot(_roomId, _pollId), isNull);
    client.relationGate!.complete();
    await _settle();
    expect(notifications, 0);

    backend.current = true;
    expect(
      polls.pollSnapshot(_roomId, _pollId),
      isNull,
      reason: 'cache was reset',
    );
    polls.dispose();
  });
}

/// A ChatBackend that is not a Matrix backend.
class _ChatBackendAdapter extends ChatBackend {
  _ChatBackendAdapter(this.inner);
  final _Backend inner;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A ChatBackend exposing the Matrix module interfaces.
class _MatrixChatBackend extends ChatBackend
    implements MatrixSdkAccess, RoomEventFeatures {
  _MatrixChatBackend(this.inner);
  final _Backend inner;
  @override
  matrix.Client? get sdkClient => inner.sdkClient;
  @override
  bool isSessionCurrent(matrix.Client client) => inner.isSessionCurrent(client);
  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) => inner.sendRoomEvent(roomId, type, content);
  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) =>
      inner.redactEvent(roomId, eventId, reason: reason);
  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) => inner.roomState(roomId, type, stateKey: stateKey);
  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) => inner.setRoomState(roomId, type, content, stateKey: stateKey);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
