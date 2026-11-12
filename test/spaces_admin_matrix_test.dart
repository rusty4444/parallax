// Exercises the live MatrixSpacesAdmin against the real SDK request builders
// with a mock HTTP transport. These prove request shapes and guards, not live
// homeserver interoperability.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/spaces_admin/matrix_spaces_admin.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_features.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_models.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/room_details.dart';
import 'package:parallax/room_events.dart';

import 'widget_test.dart' show FakeBackend;

const me = '@me:example.org';
const other = '@other:example.org';
const spaceId = '!space:example.org';
const roomA = '!a:example.org';
const roomB = '!b:remote.org';
const roomC = '!c:example.org';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('spaces-admin', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
  }
  @override
  String get userID => me;
  @override
  String get deviceID => 'DEVICE';
  @override
  bool get encryptionEnabled => true;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Request {
  _Request(this.method, this.segments, this.body);
  final String method;
  final List<String> segments;
  final Object? body;
  String get path => segments.join('/');

  /// `room/type/key` for `/rooms/{room}/state/{type}/{key}`.
  String? get stateTarget {
    final rooms = segments.indexOf('rooms');
    if (rooms < 0 || segments.length < rooms + 5) return null;
    if (segments[rooms + 2] != 'state') return null;
    return '${segments[rooms + 1]}/${segments[rooms + 3]}/'
        '${segments[rooms + 4]}';
  }
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _error(String code, int status) =>
    _json({'errcode': code, 'error': 'nope'}, status);

Map<String, Object?> _event(
  String type,
  String key,
  Map<String, Object?> content, {
  String sender = me,
  int ts = 0,
}) => {
  'type': type,
  'state_key': key,
  'content': content,
  'sender': sender,
  'event_id': '\$${type.hashCode}$key$ts',
  'origin_server_ts': ts,
};

Map<String, Object?> _levels(int mine, [Map<String, int> others = const {}]) =>
    {
      'users': {me: mine, ...others},
    };

/// A fake homeserver: full `/state` per room, single state reads derived
/// from it, and every request logged.
class _Server {
  final state = <String, List<Map<String, Object?>>>{};
  final log = <_Request>[];
  final failPuts = <String>{};
  Map<String, Object?> capabilities = const {};
  Object Function(_Request request)? createRoom;
  Map<String, Object?> hierarchy = const {'rooms': <Object>[]};

  void put(String roomId, Map<String, Object?> event) {
    final list = state.putIfAbsent(roomId, () => []);
    list.removeWhere(
      (e) => e['type'] == event['type'] && e['state_key'] == event['state_key'],
    );
    list.add(event);
  }

  List<_Request> get writes =>
      log.where((r) => r.method == 'PUT' || r.method == 'POST').toList();

  http.Response handle(_Request request) {
    log.add(request);
    final segments = request.segments;
    if (request.path.endsWith('v3/createRoom')) {
      final result =
          createRoom?.call(request) ?? {'room_id': '!new:example.org'};
      return result is http.Response ? result : _json(result);
    }
    if (request.path.endsWith('v3/capabilities')) {
      return _json({'capabilities': capabilities});
    }
    if (segments.contains('hierarchy')) return _json(hierarchy);
    final target = request.stateTarget;
    if (target != null) {
      final [room, type, key] = target.split('/');
      if (request.method == 'PUT') {
        if (failPuts.contains(target)) return _error('M_FORBIDDEN', 403);
        put(room, _event(type, key, request.body! as Map<String, Object?>));
        return _json({'event_id': '\$written'});
      }
      final event = state[room]
          ?.where((e) => e['type'] == type && e['state_key'] == key)
          .firstOrNull;
      if (event == null || (event['content']! as Map).isEmpty) {
        return _error('M_NOT_FOUND', 404);
      }
      return _json(event['content']!);
    }
    final rooms = segments.indexOf('rooms');
    if (rooms >= 0 &&
        segments.length == rooms + 3 &&
        segments[rooms + 2] == 'state') {
      return _json(state[segments[rooms + 1]] ?? const []);
    }
    return _json({});
  }
}

({MatrixBackend backend, SpacesAdminFeatures spaces, _Client client}) _setup(
  _Server server,
) {
  final client = _Client(
    MockClient((request) async {
      final body = request.body.isEmpty ? null : jsonDecode(request.body);
      return server.handle(
        _Request(request.method, request.url.pathSegments, body),
      );
    }),
  );
  final backend = MatrixBackend.withClient(client);
  addTearDown(backend.dispose);
  return (
    backend: backend,
    spaces: spacesAdminFeaturesOf(backend)!,
    client: client,
  );
}

/// A locally synced room with the given state events.
matrix.Room _local(
  matrix.Client client,
  String id, {
  bool space = false,
  String version = '11',
  Map<String, Object?>? levels,
  int members = 2,
  List<Map<String, Object?>> extra = const [],
}) {
  final room = matrix.Room(
    id: id,
    client: client,
    summary: matrix.RoomSummary.fromJson({'m.joined_member_count': members}),
  );
  for (final event in [
    _event('m.room.create', '', {
      'room_version': version,
      if (space) 'type': 'm.space',
    }),
    _event('m.room.member', me, {'membership': 'join'}),
    if (levels != null) _event('m.room.power_levels', '', levels),
    ...extra,
  ]) {
    room.setState(matrix.Event.fromJson(event, room));
  }
  client.rooms.add(room);
  return room;
}

/// Server `/state` of a Space the user administers.
void _serveSpace(
  _Server server, {
  int myPower = 100,
  List<Map<String, Object?>> children = const [],
  String version = '11',
}) {
  server.state[spaceId] = [
    _event('m.room.create', '', {'room_version': version, 'type': 'm.space'}),
    _event('m.room.name', '', {'name': 'Team'}),
    _event('m.room.power_levels', '', _levels(myPower)),
    _event('m.room.member', me, {'membership': 'join'}),
    ...children,
  ];
}

Map<String, Object?> _createBody(_Server server) =>
    server.log.singleWhere((r) => r.path.endsWith('createRoom')).body!
        as Map<String, Object?>;

List<Map<String, Object?>> _initial(Map<String, Object?> body) => [
  for (final event in body['initial_state']! as List)
    event as Map<String, Object?>,
];

void main() {
  test('resolver caches one live adapter per backend', () {
    final setup = _setup(_Server());
    expect(setup.spaces, isA<MatrixSpacesAdmin>());
    expect(spacesAdminFeaturesOf(setup.backend), same(setup.spaces));
    expect(setup.spaces.homeserverName, 'example.org');
  });

  group('create space', () {
    test('posts an m.space room with Element power levels', () async {
      final server = _Server();
      final setup = _setup(server);
      final id = await setup.spaces.createSpace(
        const SpaceCreationOptions(name: ' Team ', topic: 'Work things'),
      );
      expect(id, '!new:example.org');
      final body = _createBody(server);
      expect(body['name'], 'Team');
      expect(body['topic'], 'Work things');
      expect(body['creation_content'], {'type': 'm.space'});
      expect(body['preset'], 'private_chat');
      expect(body['visibility'], 'private');
      expect(body.containsKey('room_alias_name'), isFalse);
      expect(body['power_level_content_override'], {
        'events_default': 100,
        'invite': 50,
      });
      expect(_initial(body), [
        {
          'type': 'm.room.history_visibility',
          'state_key': '',
          'content': {'history_visibility': 'invited'},
        },
      ]);
    });

    test('public and ask-to-join Spaces get an address', () async {
      final server = _Server();
      final setup = _setup(server);
      await setup.spaces.createSpace(
        const SpaceCreationOptions(
          name: 'Open',
          access: SpaceCreationAccess.public,
          aliasLocalpart: 'open',
        ),
      );
      var body = _createBody(server);
      expect(body['preset'], 'public_chat');
      expect(body['visibility'], 'public');
      expect(body['room_alias_name'], 'open');
      expect(body['power_level_content_override'], {
        'events_default': 100,
        'invite': 0,
      });
      expect(_initial(body), isEmpty);

      server.log.clear();
      await setup.spaces.createSpace(
        const SpaceCreationOptions(
          name: 'Club',
          access: SpaceCreationAccess.askToJoin,
          aliasLocalpart: 'club',
        ),
      );
      body = _createBody(server);
      expect(body['room_alias_name'], 'club');
      expect(_initial(body), [
        {
          'type': 'm.room.join_rules',
          'state_key': '',
          'content': {'join_rule': 'knock'},
        },
      ]);
    });

    test('validation and refusals are definite; transport errors are not', () {
      final server = _Server();
      final setup = _setup(server);
      expect(
        setup.spaces.createSpace(
          const SpaceCreationOptions(
            name: 'Open',
            access: SpaceCreationAccess.public,
          ),
        ),
        throwsA(isA<RoomCreationFailure>()),
      );
      expect(
        setup.spaces.createSpace(
          const SpaceCreationOptions(
            name: 'Members',
            access: SpaceCreationAccess.spaceMembers,
          ),
        ),
        throwsA(isA<RoomCreationFailure>()),
      );
      server.createRoom = (_) => _error('M_FORBIDDEN', 403);
      expect(
        setup.spaces.createSpace(const SpaceCreationOptions(name: 'No')),
        throwsA(
          isA<RoomCreationFailure>().having(
            (f) => f.kind,
            'kind',
            RoomCreationFailureKind.rejected,
          ),
        ),
      );
    });

    test('an ambiguous server error stays uncertain', () async {
      final server = _Server()..createRoom = (_) => _error('M_UNKNOWN', 500);
      final setup = _setup(server);
      await expectLater(
        setup.spaces.createSpace(const SpaceCreationOptions(name: 'Maybe')),
        throwsA(isNot(isA<RoomCreationFailure>())),
      );
    });
  });

  group('create room in space', () {
    test('adds the parent and a Space-member join rule', () async {
      final server = _Server()
        ..capabilities = {
          'm.room_versions': {
            'default': '10',
            'available': {'10': 'stable', '11': 'stable'},
          },
        };
      _serveSpace(server);
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      await setup.spaces.createRoomInSpace(
        spaceId,
        const SpaceCreationOptions(
          name: 'General',
          access: SpaceCreationAccess.spaceMembers,
        ),
      );
      final body = _createBody(server);
      expect(body.containsKey('room_version'), isFalse);
      expect(body['preset'], 'private_chat');
      final initial = _initial(body);
      expect(
        initial,
        containsAll([
          {
            'type': 'm.room.join_rules',
            'state_key': '',
            'content': {
              'join_rule': 'restricted',
              'allow': [
                {'type': 'm.room_membership', 'room_id': spaceId},
              ],
            },
          },
          {
            'type': 'm.space.parent',
            'state_key': spaceId,
            'content': {
              'via': ['example.org'],
              'canonical': true,
            },
          },
          {
            'type': 'm.room.encryption',
            'state_key': '',
            'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
          },
        ]),
      );
    });

    test('ask to join picks a room version with knock_restricted', () async {
      final server = _Server()
        ..capabilities = {
          'm.room_versions': {
            'default': '9',
            'available': {'9': 'stable', '10': 'stable', '11': 'unstable'},
          },
        };
      _serveSpace(server);
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      await setup.spaces.createRoomInSpace(
        spaceId,
        const SpaceCreationOptions(
          name: 'Lobby',
          access: SpaceCreationAccess.askToJoinSpaceMembers,
        ),
      );
      final body = _createBody(server);
      expect(body['room_version'], '10');
      final rules = _initial(
        body,
      ).singleWhere((e) => e['type'] == 'm.room.join_rules');
      expect((rules['content']! as Map)['join_rule'], 'knock_restricted');
    });

    test('refuses before posting without permission in the Space', () async {
      final server = _Server();
      _serveSpace(server, myPower: 0);
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(0));
      await expectLater(
        setup.spaces.createRoomInSpace(
          spaceId,
          const SpaceCreationOptions(name: 'Nope'),
        ),
        throwsA(
          isA<RoomCreationFailure>().having(
            (f) => f.kind,
            'kind',
            RoomCreationFailureKind.notSubmitted,
          ),
        ),
      );
      expect(server.log.where((r) => r.path.endsWith('createRoom')), isEmpty);
    });
  });

  group('children', () {
    test('loadSpaceGraph projects valid children in spec order', () async {
      final server = _Server()
        ..hierarchy = {
          'rooms': [
            {
              'room_id': roomB,
              'name': 'Remote room',
              'num_joined_members': 7,
              'guest_can_join': false,
              'world_readable': false,
              'children_state': <Object>[],
            },
          ],
        };
      _serveSpace(
        server,
        children: [
          _event('m.space.child', roomB, {
            'via': ['remote.org'],
          }, ts: 5),
          _event('m.space.child', roomA, {
            'via': ['example.org'],
            'order': 'b',
            'suggested': true,
          }, ts: 9),
          _event('m.space.child', roomC, {
            'via': ['example.org'],
            'order': 'a',
          }, ts: 9),
          // Removed and invalid children are ignored.
          _event('m.space.child', '!gone:example.org', {}),
          _event('m.space.child', '!novia:example.org', {'via': <Object>[]}),
        ],
      );
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      _local(
        setup.client,
        roomA,
        extra: [
          _event('m.room.name', '', {'name': 'Alpha'}),
        ],
      );
      final graph = await setup.spaces.loadSpaceGraph(spaceId);
      expect(graph.canEditChildren, isTrue);
      expect(graph.children.map((c) => c.roomId), [roomC, roomA, roomB]);
      final a = graph.child(roomA)!;
      expect(a.label, 'Alpha');
      expect(a.joined, isTrue);
      expect(a.suggested, isTrue);
      final b = graph.child(roomB)!;
      expect(b.label, 'Remote room');
      expect(b.members, 7);
      expect(b.joined, isFalse);
    });

    test(
      'addChildren writes child, canonical parent and reports failures',
      () async {
        final server = _Server()..failPuts.add('$spaceId/m.space.child/$roomC');
        _serveSpace(server);
        server.state[roomA] = [_event('m.room.power_levels', '', _levels(100))];
        final setup = _setup(server);
        _local(setup.client, spaceId, space: true, levels: _levels(100));
        _local(setup.client, roomA, levels: _levels(100));
        final failed = await setup.spaces.addChildren(spaceId, [
          roomA,
          roomB,
          roomC,
        ], suggested: true);
        expect(failed, [roomC]);
        final puts = {
          for (final r in server.log.where((r) => r.method == 'PUT'))
            r.stateTarget!: r.body,
        };
        expect(puts['$spaceId/m.space.child/$roomA'], {
          'via': ['example.org'],
          'suggested': true,
        });
        // A room on another server is reachable through both servers.
        expect(puts['$spaceId/m.space.child/$roomB'], {
          'via': ['example.org', 'remote.org'],
          'suggested': true,
        });
        expect(puts['$roomA/m.space.parent/$spaceId'], {
          'via': ['example.org'],
          'canonical': true,
        });
        // Not joined to roomB: no parent pointer can be written there.
        expect(puts.containsKey('$roomB/m.space.parent/$spaceId'), isFalse);
      },
    );

    test('parent is not canonical when another canonical parent exists, '
        'and is skipped without permission', () async {
      final server = _Server();
      _serveSpace(server);
      server.state[roomA] = [_event('m.room.power_levels', '', _levels(100))];
      server.state[roomC] = [_event('m.room.power_levels', '', _levels(0))];
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      _local(
        setup.client,
        roomA,
        levels: _levels(100),
        extra: [
          _event('m.space.parent', '!main:example.org', {
            'via': ['example.org'],
            'canonical': true,
          }),
        ],
      );
      _local(setup.client, roomC, levels: _levels(0));
      expect(await setup.spaces.addChildren(spaceId, [roomA, roomC]), isEmpty);
      final puts = {
        for (final r in server.log.where((r) => r.method == 'PUT'))
          r.stateTarget!: r.body,
      };
      expect(puts['$roomA/m.space.parent/$spaceId'], {
        'via': ['example.org'],
      });
      expect(puts.containsKey('$roomC/m.space.parent/$spaceId'), isFalse);
      expect(puts.containsKey('$spaceId/m.space.child/$roomC'), isTrue);
    });

    test('Space writes refuse without fresh permission', () async {
      final server = _Server();
      _serveSpace(server, myPower: 0);
      final setup = _setup(server);
      // Stale synced power levels claim admin; the fresh read wins.
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      await expectLater(
        setup.spaces.addChildren(spaceId, [roomA]),
        throwsStateError,
      );
      await expectLater(
        setup.spaces.removeChild(spaceId, roomA),
        throwsStateError,
      );
      await expectLater(
        setup.spaces.setChildSuggested(spaceId, roomA, true),
        throwsStateError,
      );
      await expectLater(
        setup.spaces.moveChild(spaceId, roomA, 0),
        throwsStateError,
      );
      expect(server.log.where((r) => r.method == 'PUT'), isEmpty);
    });

    test('removeChild empties the child and the parent pointer', () async {
      final server = _Server();
      _serveSpace(
        server,
        children: [
          _event('m.space.child', roomA, {
            'via': ['example.org'],
          }),
        ],
      );
      server.state[roomA] = [
        _event('m.room.power_levels', '', _levels(100)),
        _event('m.space.parent', spaceId, {
          'via': ['example.org'],
          'canonical': true,
        }),
      ];
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      _local(setup.client, roomA, levels: _levels(100));
      await setup.spaces.removeChild(spaceId, roomA);
      final puts = server.log.where((r) => r.method == 'PUT').toList();
      expect(puts.map((r) => r.stateTarget), [
        '$spaceId/m.space.child/$roomA',
        '$roomA/m.space.parent/$spaceId',
      ]);
      expect(puts.map((r) => r.body), [isEmpty, isEmpty]);
    });

    test('setChildSuggested preserves via and order', () async {
      final server = _Server();
      _serveSpace(
        server,
        children: [
          _event('m.space.child', roomA, {
            'via': ['example.org'],
            'order': 'b',
          }),
        ],
      );
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      await setup.spaces.setChildSuggested(spaceId, roomA, true);
      expect(server.log.lastWhere((r) => r.method == 'PUT').body, {
        'via': ['example.org'],
        'order': 'b',
        'suggested': true,
      });
      await setup.spaces.setChildSuggested(spaceId, roomA, false);
      expect(server.log.lastWhere((r) => r.method == 'PUT').body, {
        'via': ['example.org'],
        'order': 'b',
      });
      await expectLater(
        setup.spaces.setChildSuggested(spaceId, roomB, true),
        throwsStateError,
      );
    });

    test('moveChild writes one order between the new neighbours', () async {
      final server = _Server();
      _serveSpace(
        server,
        children: [
          _event('m.space.child', roomA, {
            'via': ['example.org'],
            'order': 'b',
          }),
          _event('m.space.child', roomB, {
            'via': ['remote.org'],
            'order': 'd',
            'suggested': true,
          }),
          _event('m.space.child', roomC, {
            'via': ['example.org'],
            'order': 'f',
          }),
        ],
      );
      final setup = _setup(server);
      _local(setup.client, spaceId, space: true, levels: _levels(100));
      await setup.spaces.moveChild(spaceId, roomC, 0);
      final put = server.log.singleWhere((r) => r.method == 'PUT');
      expect(put.stateTarget, '$spaceId/m.space.child/$roomC');
      final body = put.body! as Map<String, Object?>;
      expect(body['via'], ['example.org']);
      expect((body['order']! as String).compareTo('b'), lessThan(0));
      // The server now sorts C first.
      final graph = await setup.spaces.loadSpaceGraph(spaceId);
      expect(graph.children.map((c) => c.roomId), [roomC, roomA, roomB]);

      server.log.clear();
      await setup.spaces.moveChild(spaceId, roomC, 2);
      final after = await setup.spaces.loadSpaceGraph(spaceId);
      expect(after.children.map((c) => c.roomId), [roomA, roomB, roomC]);
      expect(after.child(roomB)!.suggested, isTrue);
    });
  });

  group('authorised spaces', () {
    test('writes restricted and knock_restricted allow lists', () async {
      final server = _Server();
      server.state[roomA] = [
        _event('m.room.create', '', {'room_version': '11'}),
        _event('m.room.power_levels', '', _levels(100)),
        _event('m.room.member', me, {'membership': 'join'}),
        _event('m.room.join_rules', '', {'join_rule': 'invite'}),
      ];
      final setup = _setup(server);
      _local(setup.client, roomA, levels: _levels(100));
      await setup.spaces.setAuthorisedSpaces(roomA, [
        spaceId,
        '!other:example.org',
        spaceId,
      ], askToJoin: false);
      expect(server.log.lastWhere((r) => r.method == 'PUT').body, {
        'join_rule': 'restricted',
        'allow': [
          {'type': 'm.room_membership', 'room_id': spaceId},
          {'type': 'm.room_membership', 'room_id': '!other:example.org'},
        ],
      });
      await setup.spaces.setAuthorisedSpaces(roomA, [spaceId], askToJoin: true);
      final put = server.log.lastWhere((r) => r.method == 'PUT');
      expect(put.stateTarget, '$roomA/m.room.join_rules/');
      expect(put.body, {
        'join_rule': 'knock_restricted',
        'allow': [
          {'type': 'm.room_membership', 'room_id': spaceId},
        ],
      });
    });

    test('refuses old room versions, no permission or no Spaces', () async {
      final server = _Server();
      List<Map<String, Object?>> state(String version, int power) => [
        _event('m.room.create', '', {'room_version': version}),
        _event('m.room.power_levels', '', _levels(power)),
        _event('m.room.member', me, {'membership': 'join'}),
      ];
      final setup = _setup(server);
      _local(setup.client, roomA, levels: _levels(100));
      server.state[roomA] = state('9', 100);
      await expectLater(
        setup.spaces.setAuthorisedSpaces(roomA, [spaceId], askToJoin: true),
        throwsStateError,
      );
      server.state[roomA] = state('7', 100);
      await expectLater(
        setup.spaces.setAuthorisedSpaces(roomA, [spaceId], askToJoin: false),
        throwsStateError,
      );
      server.state[roomA] = state('11', 0);
      await expectLater(
        setup.spaces.setAuthorisedSpaces(roomA, [spaceId], askToJoin: false),
        throwsStateError,
      );
      await expectLater(
        setup.spaces.setAuthorisedSpaces(roomA, [
          'not-a-room',
        ], askToJoin: false),
        throwsArgumentError,
      );
      expect(server.log.where((r) => r.method == 'PUT'), isEmpty);
    });

    test('offers joined parents and keeps unknown allowed Spaces', () {
      final setup = _setup(_Server());
      _local(
        setup.client,
        spaceId,
        space: true,
        extra: [
          _event('m.room.name', '', {'name': 'Team'}),
          _event('m.space.child', roomA, {
            'via': ['example.org'],
          }),
        ],
      );
      _local(
        setup.client,
        '!unrelated:example.org',
        space: true,
        extra: [
          _event('m.room.name', '', {'name': 'Unrelated'}),
        ],
      );
      _local(
        setup.client,
        '!parent:example.org',
        space: true,
        extra: [
          _event('m.room.name', '', {'name': 'Parent'}),
        ],
      );
      _local(
        setup.client,
        roomA,
        extra: [
          _event('m.space.parent', '!parent:example.org', {
            'via': ['example.org'],
          }),
        ],
      );
      final spaces = setup.spaces.authorisedSpacesFor(roomA, [
        '!gone:example.org',
      ]);
      expect(spaces.selectable.map((s) => s.name), ['Parent', 'Team']);
      expect(spaces.unknown, ['!gone:example.org']);
      expect(spaces.count, 3);
    });
  });

  group('synced lookups', () {
    test('addable rooms exclude Spaces and children; targets need power', () {
      final setup = _setup(_Server());
      _local(
        setup.client,
        spaceId,
        space: true,
        levels: _levels(100),
        extra: [
          _event('m.room.name', '', {'name': 'Team'}),
          _event('m.space.child', roomA, {
            'via': ['example.org'],
          }),
        ],
      );
      _local(
        setup.client,
        '!readonly:example.org',
        space: true,
        levels: _levels(0),
      );
      _local(setup.client, roomA);
      _local(
        setup.client,
        roomC,
        extra: [
          _event('m.room.name', '', {'name': 'Gamma'}),
        ],
      );
      expect(setup.spaces.addableRooms(spaceId).map((r) => r.id), [roomC]);
      expect(setup.spaces.isJoinedSpace(spaceId), isTrue);
      expect(setup.spaces.isJoinedSpace(roomC), isFalse);
      expect(setup.spaces.spacesAcceptingChild(roomC).map((s) => s.id), [
        spaceId,
      ]);
      // Already a child of the only writable Space.
      expect(setup.spaces.spacesAcceptingChild(roomA), isEmpty);
    });
  });

  group('leaving', () {
    test('plan flags rooms where the user is the last admin', () async {
      final server = _Server();
      _serveSpace(
        server,
        children: [
          _event('m.room.member', other, {'membership': 'join'}),
        ],
      );
      // @other is an admin of roomA but has left (lazy-loaded: not synced).
      server.state[roomA] = [
        _event('m.room.member', other, {'membership': 'leave'}),
      ];
      final setup = _setup(server);
      _local(
        setup.client,
        spaceId,
        space: true,
        levels: _levels(100),
        extra: [
          for (final id in [roomA, roomC, '!sub:example.org'])
            _event('m.space.child', id, {
              'via': ['example.org'],
            }),
        ],
      );
      _local(
        setup.client,
        roomA,
        levels: _levels(100, {other: 100}),
        members: 3,
      );
      _local(
        setup.client,
        roomC,
        levels: _levels(100, {other: 100}),
        members: 3,
        extra: [
          _event('m.room.member', other, {'membership': 'join'}),
        ],
      );
      _local(
        setup.client,
        '!sub:example.org',
        space: true,
        levels: _levels(50),
        extra: [
          _event('m.space.child', roomB, {
            'via': ['remote.org'],
          }),
        ],
      );
      _local(setup.client, roomB, levels: _levels(100), members: 1);
      final plan = await setup.spaces.leavePlan(spaceId);
      // The Space itself has another member but the user is its only admin.
      expect(plan.lastAdmin, isTrue);
      expect(plan.spaceName, 'Team');
      expect(
        plan.rooms.map((r) => r.id),
        unorderedEquals([roomA, roomC, '!sub:example.org', roomB]),
      );
      expect(plan.adminRooms.map((r) => r.id), [roomA]);
      expect(
        plan.rooms.singleWhere((r) => r.id == '!sub:example.org').isSpace,
        isTrue,
      );
      // Alone in roomB: leaving is not blocked.
      expect(plan.selectable.map((r) => r.id), contains(roomB));
    });

    test(
      'leaves the chosen rooms before the Space and stops on failure',
      () async {
        final client = _Client(MockClient((_) async => _json({})));
        final backend = _LeaveBackend(client);
        addTearDown(backend.dispose);
        for (final id in [spaceId, roomA, roomB]) {
          _local(client, id, space: id == spaceId);
        }
        final spaces = MatrixSpacesAdmin(backend);
        await spaces.leaveSpaceAndRooms(spaceId, [roomA, spaceId, roomB]);
        expect(backend.left, [roomA, roomB, spaceId]);

        backend.left.clear();
        backend.failing.add(roomB);
        await expectLater(
          spaces.leaveSpaceAndRooms(spaceId, [roomA, roomB]),
          throwsA(
            isA<LeaveSpaceFailure>()
                .having((f) => f.roomId, 'roomId', roomB)
                .having((f) => f.left, 'left', [roomA]),
          ),
        );
        expect(backend.left, [roomA]);
      },
    );

    test('a session change stops leaving', () async {
      final client = _Client(MockClient((_) async => _json({})));
      final backend = _LeaveBackend(client);
      addTearDown(backend.dispose);
      for (final id in [spaceId, roomA]) {
        _local(client, id);
      }
      backend.onLeave = (_) => backend.current = false;
      await expectLater(
        MatrixSpacesAdmin(backend).leaveSpaceAndRooms(spaceId, [roomA]),
        throwsStateError,
      );
      expect(backend.left, [roomA]);
    });
  });
}

/// Records leaves; MatrixBackend.leaveRoom waits for a sync the mock
/// transport never delivers.
class _LeaveBackend extends FakeBackend
    implements MatrixSdkAccess, RoomEventFeatures {
  _LeaveBackend(this.client);
  final matrix.Client client;
  final left = <String>[];
  final failing = <String>{};
  bool current = true;
  void Function(String roomId)? onLeave;

  @override
  matrix.Client? get sdkClient => client;
  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);
  @override
  Future<void> leaveRoom(String roomId) async {
    if (failing.contains(roomId)) throw StateError('Network');
    left.add(roomId);
    onLeave?.call(roomId);
  }

  @override
  Future<RoomDetails> getRoomDetails(String roomId) =>
      throw UnimplementedError();

  @override
  // ignore: unnecessary_overrides
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
