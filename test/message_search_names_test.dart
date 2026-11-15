import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';

class _Database implements matrix.DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('search-name-test', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }

  @override
  String get userID => '@me:matrix.example';

  @override
  bool isLogged() => true;

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

const _roomId = '!room:matrix.example';
const _named = '@sam:matrix.example';
const _blank = '@blank:matrix.example';
const _missing = '@missing:matrix.example';

Map<String, Object?> _result(String id, String sender) => {
  'rank': 1.0,
  'result': {
    'event_id': id,
    'type': 'm.room.message',
    'sender': sender,
    'origin_server_ts': 1000,
    'room_id': _roomId,
    'content': {'msgtype': 'm.text', 'body': 'A matching message'},
  },
};

void _member(matrix.Room room, String sender, String displayName) {
  room.setState(
    matrix.Event.fromJson({
      'event_id': '\$member-$sender',
      'type': 'm.room.member',
      'state_key': sender,
      'sender': sender,
      'origin_server_ts': 1,
      'room_id': _roomId,
      'content': {'membership': 'join', 'displayname': displayName},
    }, room),
  );
}

void main() {
  test(
    'server message search prefers display names and keeps ID fallbacks',
    () async {
      final client = _Client(
        MockClient((request) async {
          expect(request.url.path, endsWith('/_matrix/client/v3/search'));
          return http.Response(
            jsonEncode({
              'search_categories': {
                'room_events': {
                  'count': 3,
                  'results': [
                    _result(r'$named', _named),
                    _result(r'$blank', _blank),
                    _result(r'$missing', _missing),
                  ],
                },
              },
            }),
            200,
          );
        }),
      );
      final room = matrix.Room(
        id: _roomId,
        client: client,
        membership: matrix.Membership.join,
      );
      client.rooms.add(room);
      _member(room, _named, '  Sam Russell  ');
      _member(room, _blank, '   ');
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);

      final page = await backend.searchMessages('matching');

      expect(page.hits.map((hit) => hit.sender), [
        'Sam Russell',
        _blank,
        _missing,
      ]);
    },
  );
}
