import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/matrix_room_features.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client(http.Client transport)
    : super(
        'room-features-test',
        database: _UnusedDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }
  String account = '@me:matrix.example';
  @override
  String get userID => account;
}

ChatEntry _map(Event event) => ChatEntry(
  id: event.eventId,
  sender: event.senderId,
  body: event.redacted ? 'Message removed' : event.body,
  time: event.originServerTs,
  mine: event.senderId == event.room.client.userID,
  redacted: event.redacted,
);

Map<String, Object?> _room(String id, {bool space = false}) => {
  'room_id': id,
  'name': id,
  'room_type': space ? 'm.space' : null,
  'num_joined_members': 3,
  'world_readable': false,
  'guest_can_join': false,
  'children_state': <Object?>[],
};

void main() {
  test('directory uses real SDK transport and maps profiles', () async {
    final client = _Client(
      MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          Uri.decodeComponent(request.url.path),
          '/_matrix/client/v3/user_directory/search',
        );
        expect(request.headers['authorization'], 'Bearer test-token');
        expect(jsonDecode(request.body), {'search_term': 'Alice', 'limit': 50});
        return http.Response(
          jsonEncode({
            'limited': false,
            'results': [
              {
                'user_id': '@alice:matrix.example',
                'display_name': 'Alice',
                'avatar_url': 'mxc://matrix.example/a',
              },
            ],
          }),
          200,
        );
      }),
    );
    final features = MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: _map,
    );
    final users = await features.searchUsers(' Alice ');
    expect(users.single.id, '@alice:matrix.example');
    expect(users.single.name, 'Alice');
    expect(users.single.avatar, Uri.parse('mxc://matrix.example/a'));
  });

  test('hierarchy sends direct-depth cursor and excludes the root', () async {
    final client = _Client(
      MockClient((request) async {
        expect(
          Uri.decodeComponent(request.url.path),
          '/_matrix/client/v1/rooms/!space:matrix.example/hierarchy',
        );
        expect(request.url.queryParameters['from'], 'opaque/next');
        expect(request.url.queryParameters['max_depth'], '1');
        return http.Response(
          jsonEncode({
            'rooms': [
              _room('!space:matrix.example', space: true),
              _room('!nested:matrix.example', space: true),
              _room('!chat:matrix.example'),
            ],
            'next_batch': 'last',
          }),
          200,
        );
      }),
    );
    final page = await MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: _map,
    ).loadSpace('!space:matrix.example', nextBatch: 'opaque/next');
    expect(page.rooms.map((e) => e.id), [
      '!nested:matrix.example',
      '!chat:matrix.example',
    ]);
    expect(page.rooms.first.isSpace, isTrue);
    expect(page.nextBatch, 'last');
  });

  test(
    'thread relation cursor is preserved and messages deduplicated/sorted',
    () async {
      final client = _Client(
        MockClient((request) async {
          expect(
            Uri.decodeComponent(request.url.path),
            r'/_matrix/client/v1/rooms/!chat:matrix.example/relations/$root/m.thread',
          );
          expect(request.url.queryParameters['from'], 'page-2');
          expect(request.url.queryParameters['dir'], 'b');
          Map<String, Object?> event(String id, int ts) => {
            'event_id': id,
            'sender': '@alice:matrix.example',
            'origin_server_ts': ts,
            'type': 'm.room.message',
            'content': {
              'body': id,
              'msgtype': 'm.text',
              'm.relates_to': {'rel_type': 'm.thread', 'event_id': r'$root'},
            },
          };
          return http.Response(
            jsonEncode({
              'chunk': [
                event(r'$later', 2000),
                event(r'$earlier', 1000),
                event(r'$later', 2000),
              ],
              'next_batch': 'page-3',
            }),
            200,
          );
        }),
      );
      client.rooms.add(
        Room(
          id: '!chat:matrix.example',
          client: client,
          membership: Membership.join,
        ),
      );
      final page = await MatrixRoomFeatures(
        client,
        ownerCurrent: () => true,
        mapEvent: _map,
      ).loadThread('!chat:matrix.example', r'$root', nextBatch: 'page-2');
      expect(page.messages.map((e) => e.id), [r'$earlier', r'$later']);
      expect(page.nextBatch, 'page-3');
    },
  );

  test(
    'late directory success is rejected after account replacement',
    () async {
      final response = Completer<http.Response>();
      final client = _Client(MockClient((_) => response.future));
      var current = true;
      final features = MatrixRoomFeatures(
        client,
        ownerCurrent: () => current,
        mapEvent: _map,
      );
      final pending = features.searchUsers('alice');
      final assertion = expectLater(pending, throwsStateError);
      current = false;
      response.complete(http.Response('{"limited":false,"results":[]}', 200));
      await assertion;
      await expectLater(features.searchUsers('bob'), throwsStateError);
    },
  );

  test(
    'favourite writes use SDK tags and verify authoritative readback',
    () async {
      final methods = <String>[];
      var favourite = false;
      final client = _Client(
        MockClient((request) async {
          methods.add(request.method);
          if (request.method == 'PUT') favourite = true;
          if (request.method == 'DELETE') favourite = false;
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'tags': {if (favourite) 'm.favourite': {}},
              }),
              200,
            );
          }
          expect(request.url.path.endsWith('/tags/m.favourite'), isTrue);
          return http.Response('{}', 200);
        }),
      );
      client.rooms.add(
        Room(
          id: '!chat:matrix.example',
          client: client,
          membership: Membership.join,
        ),
      );
      final features = MatrixRoomFeatures(
        client,
        ownerCurrent: () => true,
        mapEvent: _map,
      );
      expect(features.isFavourite('!chat:matrix.example'), isFalse);
      await features.setFavourite('!chat:matrix.example', true);
      expect(features.isFavourite('!chat:matrix.example'), isTrue);
      await features.setFavourite('!chat:matrix.example', false);
      expect(features.isFavourite('!chat:matrix.example'), isFalse);
      expect(methods, ['PUT', 'GET', 'DELETE', 'GET']);
    },
  );

  test(
    'receipt projection includes global/main/thread and deduplicates users',
    () async {
      final client = _Client(
        MockClient(
          (_) async => throw StateError('Receipts must use sync state'),
        ),
      );
      final room = Room(
        id: '!chat:matrix.example',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      room.receiptState = LatestReceiptState(
        global: LatestReceiptStateForTimeline.empty()
          ..otherUsers['@alice:matrix.example'] = LatestReceiptStateData(
            'target',
            1000,
          )
          ..otherUsers['@later:matrix.example'] = LatestReceiptStateData(
            'different',
            9000,
          ),
        mainThread: LatestReceiptStateForTimeline.empty()
          ..otherUsers['@alice:matrix.example'] = LatestReceiptStateData(
            'target',
            2000,
          ),
        byThread: {
          'root': LatestReceiptStateForTimeline.empty()
            ..otherUsers['@bob:matrix.example'] = LatestReceiptStateData(
              'target',
              3000,
            ),
        },
      );
      final readers = await MatrixRoomFeatures(
        client,
        ownerCurrent: () => true,
        mapEvent: _map,
      ).messageReaders(room.id, 'target');
      expect(readers.map((e) => e.userId), [
        '@bob:matrix.example',
        '@alice:matrix.example',
      ]);
      expect(readers.last.time, DateTime.fromMillisecondsSinceEpoch(2000));
    },
  );

  test('spaces getter lists only joined SDK Space rooms', () {
    final client = _Client(
      MockClient((_) async => throw StateError('local projection')),
    );
    Room space(String id, Membership membership) =>
        Room(id: id, client: client, membership: membership)..setState(
          Event.fromJson({
            'type': 'm.room.create',
            'state_key': '',
            'sender': client.userID,
            'event_id': 'create-$id',
            'origin_server_ts': 1000,
            'content': {'type': 'm.space'},
          }, Room(id: id, client: client)),
        );
    client.rooms.addAll([
      space('!joined:matrix.example', Membership.join),
      space('!invite:matrix.example', Membership.invite),
      Room(
        id: '!chat:matrix.example',
        client: client,
        membership: Membership.join,
      ),
    ]);
    expect(
      MatrixRoomFeatures(
        client,
        ownerCurrent: () => true,
        mapEvent: _map,
      ).spaces.map((e) => e.id),
      ['!joined:matrix.example'],
    );
  });

  for (final operation in ['space', 'thread']) {
    for (final fail in [false, true]) {
      test(
        '$operation rejects stale transport ${fail ? 'error' : 'success'}',
        () async {
          final response = Completer<http.Response>();
          final client = _Client(MockClient((_) => response.future));
          client.rooms.add(
            Room(
              id: '!chat:matrix.example',
              client: client,
              membership: Membership.join,
            ),
          );
          var current = true;
          final features = MatrixRoomFeatures(
            client,
            ownerCurrent: () => current,
            mapEvent: _map,
          );
          final future = operation == 'space'
              ? features.loadSpace('!space:matrix.example')
              : features.loadThread('!chat:matrix.example', 'root');
          final assertion = expectLater(future, throwsStateError);
          current = false;
          response.complete(
            http.Response(
              fail
                  ? '{"errcode":"M_FORBIDDEN","error":"old account"}'
                  : operation == 'space'
                  ? '{"rooms":[]}'
                  : '{"chunk":[]}',
              fail ? 403 : 200,
            ),
          );
          await assertion;
        },
      );
    }
  }

  test(
    'client identity change is rejected even with a permissive owner callback',
    () async {
      final response = Completer<http.Response>();
      final client = _Client(MockClient((_) => response.future));
      final features = MatrixRoomFeatures(
        client,
        ownerCurrent: () => true,
        mapEvent: _map,
      );
      final assertion = expectLater(
        features.searchUsers('alice'),
        throwsStateError,
      );
      client.account = '@replacement:matrix.example';
      response.complete(http.Response('{"limited":false,"results":[]}', 200));
      await assertion;
      expect(() => features.spaces, throwsStateError);
      expect(() => features.isFavourite('anything'), throwsStateError);
    },
  );

  test('favourite readback mismatch fails without poisoning retry', () async {
    var reads = 0;
    final client = _Client(
      MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(
            reads++ == 0 ? '{"tags":{}}' : '{"tags":{"m.favourite":{}}}',
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
    final room = Room(
      id: '!chat:matrix.example',
      client: client,
      membership: Membership.join,
    );
    client.rooms.add(room);
    final features = MatrixRoomFeatures(
      client,
      ownerCurrent: () => true,
      mapEvent: _map,
    );
    await expectLater(features.setFavourite(room.id, true), throwsStateError);
    expect(features.isFavourite(room.id), isFalse);
    await features.setFavourite(room.id, true);
    expect(features.isFavourite(room.id), isTrue);
  });

  test(
    'late favourite readback cannot update a replaced account projection',
    () async {
      final readStarted = Completer<void>();
      final read = Completer<http.Response>();
      final client = _Client(
        MockClient((request) async {
          if (request.method == 'GET') {
            readStarted.complete();
            return read.future;
          }
          return http.Response('{}', 200);
        }),
      );
      final room = Room(
        id: '!chat:matrix.example',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      var current = true;
      final features = MatrixRoomFeatures(
        client,
        ownerCurrent: () => current,
        mapEvent: _map,
      );
      final assertion = expectLater(
        features.setFavourite(room.id, true),
        throwsStateError,
      );
      await readStarted.future;
      current = false;
      read.complete(http.Response('{"tags":{"m.favourite":{}}}', 200));
      await assertion;
      expect(room.isFavourite, isFalse);
    },
  );

  test('favourite operations serialize across short-lived helpers', () async {
    final firstReadStarted = Completer<void>();
    final firstRead = Completer<http.Response>();
    final methods = <String>[];
    var reads = 0;
    final client = _Client(
      MockClient((request) async {
        methods.add(request.method);
        if (request.method == 'GET' && reads++ == 0) {
          firstReadStarted.complete();
          return firstRead.future;
        }
        return http.Response(
          request.method == 'GET' ? '{"tags":{}}' : '{}',
          200,
        );
      }),
    );
    client.rooms.add(
      Room(
        id: '!chat:matrix.example',
        client: client,
        membership: Membership.join,
      ),
    );
    MatrixRoomFeatures helper() =>
        MatrixRoomFeatures(client, ownerCurrent: () => true, mapEvent: _map);
    final first = helper().setFavourite('!chat:matrix.example', true);
    await firstReadStarted.future;
    final second = helper().setFavourite('!chat:matrix.example', false);
    // Advance to the next event turn, so all ready microtasks have run.
    await Future<void>(() {});
    final whileFirstReadPending = List<String>.of(methods);
    firstRead.complete(http.Response('{"tags":{"m.favourite":{}}}', 200));
    await first;
    await second;
    expect(whileFirstReadPending, ['PUT', 'GET']);
    expect(methods, ['PUT', 'GET', 'DELETE', 'GET']);
    expect(helper().isFavourite('!chat:matrix.example'), isFalse);
  });
}
