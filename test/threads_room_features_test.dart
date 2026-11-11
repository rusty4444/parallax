import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:parallax/features/threads/event_projection.dart';
import 'package:parallax/features/threads/thread_features.dart';
import 'package:parallax/features/threads/thread_models.dart';
import 'package:parallax/matrix_room_features.dart';
import 'package:parallax/room_events.dart';

const _roomId = '!chat:matrix.example';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client(http.Client transport)
    : super(
        'threads-test',
        database: _UnusedDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }
  @override
  String get userID => '@me:matrix.example';
}

class _Access implements MatrixSdkAccess {
  _Access(this.client);
  final Client client;
  bool current = true;
  @override
  Client? get sdkClient => client;
  @override
  bool isSessionCurrent(Client client) => current;
}

Room _room(Client client, {LatestReceiptState? receipts}) {
  final room = Room(
    id: _roomId,
    client: client,
    membership: Membership.join,
    receiptState: receipts,
  );
  client.rooms.add(room);
  return room;
}

Map<String, Object?> _message(
  String id,
  int ts, {
  String sender = '@alice:matrix.example',
  String body = 'hello',
  Map<String, Object?>? unsigned,
}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': sender,
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': {'msgtype': 'm.text', 'body': body},
  'unsigned': ?unsigned,
};

Map<String, Object?> _root(
  String id, {
  int count = 2,
  Map<String, Object?>? latest,
  bool participated = false,
}) => _message(
  id,
  1000,
  body: 'root $id',
  unsigned: {
    'm.relations': {
      'm.thread': {
        'count': count,
        'latest_event': ?latest,
        'current_user_participated': participated,
      },
    },
  },
);

LatestReceiptState _threadReceipt(String root, String eventId, int ts) =>
    LatestReceiptState.fromJson({
      'thread': {
        root: {
          'latest': {'e': eventId, 'ts': ts},
        },
      },
    });

void main() {
  test('threads list uses the /threads endpoint and maps summaries', () async {
    late http.Request seen;
    final client = _Client(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'chunk': [
              _root(
                r'$one',
                count: 3,
                participated: true,
                latest: _message(r'$latest', 5000, body: 'latest reply'),
              ),
              _root(r'$one'),
              _root(r'$two', count: 1),
            ],
            'next_batch': 'next-page',
          }),
          200,
        );
      }),
    );
    _room(client);
    final page = await MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: projectStandaloneEvent,
    ).loadThreadRoots(_roomId, filter: ThreadListFilter.participated);
    expect(
      Uri.decodeComponent(seen.url.path),
      '/_matrix/client/v1/rooms/$_roomId/threads',
    );
    expect(seen.url.queryParameters['include'], 'participated');
    expect(seen.url.queryParameters['limit'], '25');
    expect(seen.url.queryParameters.containsKey('from'), isFalse);
    expect(page.threads.map((t) => t.root.id), [r'$one', r'$two']);
    final first = page.threads.first;
    expect(first.replyCount, 3);
    expect(first.participated, isTrue);
    expect(first.latest!.body, 'latest reply');
    expect(first.root.body, r'root $one');
    expect(first.activity, first.latest!.time);
    // No threaded receipt yet: unread state is unknown, not guessed.
    expect(first.unread, isNull);
    expect(page.threads.last.latest, isNull);
    expect(page.nextBatch, 'next-page');
  });

  test('pagination forwards the cursor and stops on a repeated one', () async {
    final client = _Client(
      MockClient((request) async {
        expect(request.url.queryParameters['from'], 'cursor');
        expect(request.url.queryParameters['include'], 'all');
        return http.Response(
          jsonEncode({'chunk': <Object?>[], 'next_batch': 'cursor'}),
          200,
        );
      }),
    );
    _room(client);
    final page = await MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: projectStandaloneEvent,
    ).loadThreadRoots(_roomId, nextBatch: 'cursor');
    expect(page.threads, isEmpty);
    expect(page.nextBatch, isNull);
  });

  test('unread compares the latest reply with the threaded receipt', () {
    final client = _Client(MockClient((_) async => http.Response('{}', 500)));
    final room = _room(
      client,
      receipts: _threadReceipt(r'$root', r'$read', 4000),
    );
    final features = MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: projectStandaloneEvent,
    );
    Event latest(
      String id,
      int ts, {
      String sender = '@alice:matrix.example',
    }) => Event.fromJson(_message(id, ts, sender: sender), room);
    expect(features.threadUnread(room, r'$root', latest(r'$new', 5000)), true);
    expect(
      features.threadUnread(room, r'$root', latest(r'$read', 4000)),
      false,
    );
    expect(
      features.threadUnread(
        room,
        r'$root',
        latest(r'$mine', 6000, sender: '@me:matrix.example'),
      ),
      false,
    );
    expect(
      features.threadUnread(room, r'$other-root', latest(r'$new', 5000)),
      isNull,
    );
  });

  test('threaded receipts carry thread_id and honour private mode', () async {
    final posts = <http.Request>[];
    final client = _Client(
      MockClient((request) async {
        posts.add(request);
        return http.Response('{}', 200);
      }),
    );
    _room(client, receipts: _threadReceipt(r'$root', r'$seen', 1000));
    final features = MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: projectStandaloneEvent,
    );
    await features.sendThreadReceipt(
      _roomId,
      r'$root',
      r'$reply',
      public: true,
    );
    await features.sendThreadReceipt(
      _roomId,
      r'$root',
      r'$reply2',
      public: false,
    );
    // Already the latest own receipt, the root itself, or a local echo.
    await features.sendThreadReceipt(_roomId, r'$root', r'$seen', public: true);
    await features.sendThreadReceipt(_roomId, r'$root', r'$root', public: true);
    await features.sendThreadReceipt(_roomId, r'$root', 'txn-1', public: true);
    expect(posts, hasLength(2));
    expect(
      Uri.decodeComponent(posts[0].url.path),
      '/_matrix/client/v3/rooms/$_roomId/receipt/m.read/\$reply',
    );
    expect(jsonDecode(posts[0].body), {'thread_id': r'$root'});
    expect(
      Uri.decodeComponent(posts[1].url.path),
      '/_matrix/client/v3/rooms/$_roomId/receipt/m.read.private/\$reply2',
    );
  });

  test('late thread list from a retired session is rejected', () async {
    final response = Completer<http.Response>();
    final client = _Client(MockClient((_) => response.future));
    _room(client);
    final access = _Access(client);
    final threads = MatrixThreads(access);
    final pending = threads.loadThreads(_roomId);
    final assertion = expectLater(pending, throwsStateError);
    access.current = false;
    response.complete(http.Response(jsonEncode({'chunk': <Object?>[]}), 200));
    await assertion;
  });

  test('servers without the threads endpoint are reported as such', () async {
    final client = _Client(
      MockClient(
        (_) async => http.Response(
          jsonEncode({'errcode': 'M_UNRECOGNIZED', 'error': 'Unrecognized'}),
          404,
        ),
      ),
    );
    _room(client);
    await expectLater(
      MatrixThreads(_Access(client)).loadThreads(_roomId),
      throwsA(isA<ThreadListUnsupported>()),
    );
  });

  test('thread activity emits roots of new thread replies only', () async {
    final client = _Client(MockClient((_) async => http.Response('{}', 500)));
    final room = _room(client);
    final threads = MatrixThreads(_Access(client));
    final roots = <String>[];
    final subscription = threads.threadActivity(_roomId).listen(roots.add);
    addTearDown(subscription.cancel);
    client.onTimelineEvent.add(
      Event.fromJson({
        ..._message(r'$reply', 1),
        'content': {
          'msgtype': 'm.text',
          'body': 'in thread',
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': r'$root'},
        },
      }, room),
    );
    client.onTimelineEvent.add(Event.fromJson(_message(r'$plain', 2), room));
    await Future<void>.delayed(Duration.zero);
    expect(roots, [r'$root']);
  });

  test('standalone projection strips reply fallbacks and reads members', () {
    final client = _Client(MockClient((_) async => http.Response('{}', 500)));
    final room = _room(client);
    room.setState(
      Event.fromJson({
        'event_id': r'$member',
        'type': 'm.room.member',
        'state_key': '@alice:matrix.example',
        'sender': '@alice:matrix.example',
        'origin_server_ts': 1,
        'room_id': _roomId,
        'content': {'membership': 'join', 'displayname': 'Alice'},
      }, room),
    );
    final entry = projectStandaloneEvent(
      Event.fromJson({
        ..._message(r'$reply', 1),
        'content': {
          'msgtype': 'm.text',
          'body': '> <@bob:matrix.example> earlier\n\nactual reply',
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$earlier'},
          },
        },
      }, room),
    );
    expect(entry.body, 'actual reply');
    expect(entry.replyToId, r'$earlier');
    expect(entry.senderLabel, 'Alice');
    expect(entryPreview(entry), 'actual reply');
  });
}
