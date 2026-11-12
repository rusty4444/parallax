// Exercises the live MatrixRoomsAdmin against the real SDK request builders
// with a mock HTTP transport. These prove request shapes and guards, not live
// homeserver interoperability.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_features.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_models.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/room_details.dart';

const me = '@me:example.org';
const roomId = '!room:example.org';
const guest = '@guest:example.org';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('rooms-admin', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
  }
  bool cryptoAvailable = true;
  @override
  String get userID => me;
  @override
  String get deviceID => 'DEVICE';
  @override
  bool get encryptionEnabled => cryptoAvailable;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Request {
  _Request(this.method, this.segments, this.query, this.body);
  final String method;
  final List<String> segments;
  final Map<String, List<String>> query;
  final Map<String, Object?>? body;
  String get path => segments.join('/');
}

typedef _Handler = http.Response Function(_Request request);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _error(String code, int status) =>
    _json({'errcode': code, 'error': 'nope'}, status);

Map<String, Object?> _state(
  String type,
  String key,
  Map<String, Object?> content,
) => {
  'type': type,
  'state_key': key,
  'content': content,
  'sender': me,
  'event_id': '\$${type.hashCode}$key',
  'origin_server_ts': 0,
};

List<Map<String, Object?>> _roomState({
  Map<String, Object?>? levels,
  String guestMembership = 'join',
}) => [
  _state('m.room.create', '', {'room_version': '10'}),
  _state(
    'm.room.power_levels',
    '',
    levels ??
        {
          'users': {me: 100},
          'kick': 50,
          'ban': 50,
        },
  ),
  _state('m.room.member', me, {'membership': 'join'}),
  _state('m.room.member', guest, {'membership': guestMembership}),
];

({MatrixBackend backend, RoomsAdminFeatures admin, List<_Request> log}) _setup(
  _Handler handler, {
  bool joined = true,
  bool crypto = true,
}) {
  final log = <_Request>[];
  final client = _Client(
    MockClient((request) async {
      final body = request.body.isEmpty
          ? null
          : jsonDecode(request.body) as Map<String, Object?>;
      final entry = _Request(
        request.method,
        request.url.pathSegments,
        request.url.queryParametersAll,
        body,
      );
      log.add(entry);
      return handler(entry);
    }),
  )..cryptoAvailable = crypto;
  if (joined) {
    client.rooms.add(matrix.Room(id: roomId, client: client));
  }
  final backend = MatrixBackend.withClient(client);
  addTearDown(backend.dispose);
  final admin = roomsAdminFeaturesOf(backend)!;
  return (backend: backend, admin: admin, log: log);
}

void main() {
  test('resolver caches one live adapter per backend', () {
    final setup = _setup((_) => _json({}));
    expect(setup.admin, isA<MatrixRoomsAdmin>());
    expect(roomsAdminFeaturesOf(setup.backend), same(setup.admin));
    expect(setup.admin.homeserverName, 'example.org');
  });

  group('notifications', () {
    Map<String, Object?> rules({bool room = false, bool override = false}) => {
      'global': {
        'override': [
          if (override)
            {
              'rule_id': roomId,
              'default': false,
              'enabled': true,
              'actions': <Object>[],
              'conditions': [
                {'kind': 'event_match', 'key': 'room_id', 'pattern': roomId},
              ],
            },
        ],
        'room': [
          if (room)
            {
              'rule_id': roomId,
              'default': false,
              'enabled': true,
              'actions': ['notify'],
            },
        ],
        'underride': [
          {
            'rule_id': '.m.rule.message',
            'default': true,
            'enabled': true,
            'actions': ['notify'],
          },
        ],
      },
    };

    test('reads the room rule and mutes via an override rule', () async {
      var current = rules(room: true);
      final setup = _setup((request) {
        if (request.method == 'GET' && request.path.endsWith('pushrules/')) {
          return _json(current);
        }
        return _json({});
      });
      final settings = await setup.admin.notificationSettings(roomId);
      expect(settings.customMode, RoomNotificationMode.allMessages);
      expect(settings.defaultMode, RoomNotificationMode.allMessages);

      setup.log.clear();
      await setup.admin.setNotificationMode(roomId, RoomNotificationMode.mute);
      final writes = setup.log.where((r) => r.method != 'GET').toList();
      expect(writes.map((r) => '${r.method} ${r.segments.skip(5).join('/')}'), [
        'PUT override/$roomId',
        'DELETE room/$roomId',
      ]);
      expect(writes.first.body, {
        'actions': <Object>[],
        'conditions': [
          {'kind': 'event_match', 'key': 'room_id', 'pattern': roomId},
        ],
      });

      current = rules(override: true);
      setup.log.clear();
      await setup.admin.setNotificationMode(roomId, null);
      expect(
        setup.log
            .where((r) => r.method != 'GET')
            .map((r) => '${r.method} ${r.segments.skip(5).join('/')}'),
        ['DELETE override/$roomId'],
      );

      setup.log.clear();
      await setup.admin.setNotificationMode(
        roomId,
        RoomNotificationMode.mentionsAndKeywords,
      );
      final put = setup.log.firstWhere((r) => r.method == 'PUT');
      expect(put.segments.skip(5).join('/'), 'room/$roomId');
      expect(put.body, {'actions': <Object>[]});
    });
  });

  group('report room', () {
    test(
      'posts the reason and maps a missing endpoint to unsupported',
      () async {
        var status = 200;
        final setup = _setup(
          (request) =>
              status == 200 ? _json({}) : _error('M_UNRECOGNIZED', status),
        );
        await setup.admin.reportRoom(roomId, '  Spam  ');
        expect(setup.log.single.path, '_matrix/client/v3/rooms/$roomId/report');
        expect(setup.log.single.body, {'reason': 'Spam'});
        status = 404;
        await expectLater(
          setup.admin.reportRoom(roomId, 'Spam'),
          throwsA(isA<ReportRoomUnsupported>()),
        );
      },
    );

    test('other server errors are not reported as unsupported', () async {
      final setup = _setup((_) => _error('M_LIMIT_EXCEEDED', 429));
      await expectLater(
        setup.admin.reportRoom(roomId, 'Spam'),
        throwsA(isA<matrix.MatrixException>()),
      );
    });
  });

  group('configured room creation', () {
    test('public rooms publish an address without encryption', () async {
      final setup = _setup((_) => _json({'room_id': '!new:example.org'}));
      final id = await setup.admin.createConfiguredRoom(
        const RoomCreationOptions(
          name: ' Book club ',
          topic: 'Monthly reads',
          visibility: RoomVisibilityOption.public,
          aliasLocalpart: 'book-club',
        ),
      );
      expect(id, '!new:example.org');
      final body = setup.log.single.body!;
      expect(body['name'], 'Book club');
      expect(body['topic'], 'Monthly reads');
      expect(body['preset'], 'public_chat');
      expect(body['visibility'], 'public');
      expect(body['room_alias_name'], 'book-club');
      expect(
        (body['initial_state'] as List).map((e) => (e as Map)['type']),
        isNot(contains('m.room.encryption')),
      );
    });

    test('private rooms are encrypted with invited history', () async {
      final setup = _setup((_) => _json({'room_id': '!new:example.org'}));
      await setup.admin.createConfiguredRoom(
        const RoomCreationOptions(name: 'Family'),
      );
      final body = setup.log.single.body!;
      expect(body['preset'], 'private_chat');
      expect(body['visibility'], 'private');
      expect(body.containsKey('room_alias_name'), isFalse);
      final state = {
        for (final event in body['initial_state'] as List)
          (event as Map)['type']: event['content'],
      };
      expect(state['m.room.encryption'], {'algorithm': 'm.megolm.v1.aes-sha2'});
      expect(state['m.room.history_visibility'], {
        'history_visibility': 'invited',
      });
    });

    test('ask to join sets the knock join rule', () async {
      final setup = _setup((_) => _json({'room_id': '!new:example.org'}));
      await setup.admin.createConfiguredRoom(
        const RoomCreationOptions(
          name: 'Club',
          visibility: RoomVisibilityOption.public,
          askToJoin: true,
          aliasLocalpart: 'club',
        ),
      );
      final state = {
        for (final event in setup.log.single.body!['initial_state'] as List)
          (event as Map)['type']: event['content'],
      };
      expect(state['m.room.join_rules'], {'join_rule': 'knock'});
    });

    test('definite refusals are typed; uncertain failures are not', () async {
      var reply = _error('M_ROOM_IN_USE', 400);
      final setup = _setup((_) => reply);
      const options = RoomCreationOptions(
        name: 'Club',
        visibility: RoomVisibilityOption.public,
        aliasLocalpart: 'club',
      );
      await expectLater(
        setup.admin.createConfiguredRoom(options),
        throwsA(
          isA<RoomCreationFailure>()
              .having(
                (f) => f.kind,
                'kind',
                RoomCreationFailureKind.notSubmitted,
              )
              .having((f) => f.message, 'message', contains('already taken')),
        ),
      );
      reply = _error('M_FORBIDDEN', 403);
      await expectLater(
        setup.admin.createConfiguredRoom(options),
        throwsA(
          isA<RoomCreationFailure>().having(
            (f) => f.kind,
            'kind',
            RoomCreationFailureKind.rejected,
          ),
        ),
      );
      reply = _error('M_UNKNOWN', 500);
      await expectLater(
        setup.admin.createConfiguredRoom(options),
        throwsA(isA<matrix.MatrixException>()),
      );
    });

    test('validation and missing encryption never send a request', () async {
      final setup = _setup(
        (_) => _json({'room_id': '!new:example.org'}),
        crypto: false,
      );
      for (final options in const [
        RoomCreationOptions(name: '  '),
        RoomCreationOptions(name: 'Family'),
        RoomCreationOptions(
          name: 'Public',
          visibility: RoomVisibilityOption.public,
          aliasLocalpart: 'bad:alias',
        ),
      ]) {
        await expectLater(
          setup.admin.createConfiguredRoom(options),
          throwsA(isA<RoomCreationFailure>()),
        );
      }
      expect(setup.log, isEmpty);
    });
  });

  group('join by address', () {
    test('resolves an alias then previews with the room summary', () async {
      final setup = _setup((request) {
        if (request.path.contains('directory/room')) {
          return _json({
            'room_id': '!remote:other.org',
            'servers': ['other.org'],
          });
        }
        if (request.path.contains('room_summary')) {
          expect(request.query['via'], ['other.org']);
          return _json({
            'room_id': '!remote:other.org',
            'name': 'Remote room',
            'num_joined_members': 42,
            'guest_can_join': false,
            'world_readable': false,
            'join_rule': 'knock',
            'canonical_alias': '#remote:other.org',
          });
        }
        return _error('M_NOT_FOUND', 404);
      }, joined: false);
      final preview = await setup.admin.previewRoom(
        parseRoomAddress('#remote:other.org')!,
      );
      expect(preview.roomId, '!remote:other.org');
      expect(preview.displayName, 'Remote room');
      expect(preview.memberCount, 42);
      expect(preview.canKnock, isTrue);
      expect(preview.via, ['other.org']);
      expect(setup.log.first.path, contains('#remote:other.org'));
    });

    test('falls back to the hierarchy when summaries are missing', () async {
      final setup = _setup((request) {
        if (request.path.contains('hierarchy')) {
          return _json({
            'rooms': [
              {
                'room_id': '!pub:example.org',
                'name': 'Public',
                'num_joined_members': 3,
                'guest_can_join': false,
                'world_readable': true,
                'join_rule': 'public',
                'children_state': <Object>[],
              },
            ],
          });
        }
        return _error('M_UNRECOGNIZED', 404);
      }, joined: false);
      final preview = await setup.admin.previewRoom(
        parseRoomAddress('!pub:example.org')!,
      );
      expect(preview.name, 'Public');
      expect(preview.joinRule, 'public');
    });

    test('a missing alias is an error', () async {
      final setup = _setup((_) => _error('M_NOT_FOUND', 404), joined: false);
      await expectLater(
        setup.admin.previewRoom(parseRoomAddress('#gone:example.org')!),
        throwsA(isA<matrix.MatrixException>()),
      );
    });

    test('knock sends the optional message and via servers', () async {
      final setup = _setup(
        (_) => _json({'room_id': '!remote:other.org'}),
        joined: false,
      );
      await setup.admin.knockRoom(
        '!remote:other.org',
        via: ['other.org'],
        reason: ' Hi! ',
      );
      expect(setup.log.single.path, contains('knock'));
      expect(setup.log.single.query['via'], ['other.org']);
      expect(setup.log.single.body, {'reason': 'Hi!'});
    });
  });

  group('moderation and roles', () {
    test('kicks with a reason only after a fresh permission read', () async {
      final setup = _setup((request) {
        if (request.method == 'GET') return _json(_roomState());
        return _json({});
      });
      await setup.admin.moderateMember(
        roomId,
        guest,
        RoomAction.kick,
        reason: ' Off topic ',
      );
      expect(setup.log.map((r) => r.method), ['GET', 'POST']);
      expect(setup.log.last.path, '_matrix/client/v3/rooms/$roomId/kick');
      expect(setup.log.last.body, {'user_id': guest, 'reason': 'Off topic'});
    });

    test('refuses moderation the fresh state does not allow', () async {
      final setup = _setup(
        (request) => _json(
          _roomState(
            levels: {
              'users': {me: 50, guest: 50},
            },
          ),
        ),
      );
      await expectLater(
        setup.admin.moderateMember(roomId, guest, RoomAction.ban),
        throwsStateError,
      );
      expect(setup.log.map((r) => r.method), ['GET']);
    });

    test('role changes rewrite only the users map', () async {
      final setup = _setup((request) {
        if (request.method == 'GET') {
          return _json(
            _roomState(
              levels: {
                'users': {me: 100},
                'kick': 60,
                'events': {'m.room.name': 50},
              },
            ),
          );
        }
        return _json({'event_id': r'$pl'});
      });
      await setup.admin.setMemberPowerLevels(roomId, {guest: 50});
      final put = setup.log.last;
      expect(put.method, 'PUT');
      expect(
        put.path,
        '_matrix/client/v3/rooms/$roomId/state/m.room.power_levels/',
      );
      expect(put.body, {
        'users': {me: 100, guest: 50},
        'kick': 60,
        'events': {'m.room.name': 50},
      });
      await expectLater(
        setup.admin.setMemberPowerLevels(roomId, {guest: 101}),
        throwsStateError,
      );
    });

    test('permission edits are bounded by the user’s own level', () async {
      final setup = _setup((request) {
        if (request.method == 'GET') {
          return _json(
            _roomState(
              levels: {
                'users': {me: 50},
                'state_default': 50,
                'invite': 0,
              },
            ),
          );
        }
        return _json({'event_id': r'$pl'});
      });
      const invite = PermissionItem('invite', 'Invite people', 0);
      await setup.admin.setPermissionLevel(roomId, invite, 50);
      expect(setup.log.last.body?['invite'], 50);
      await expectLater(
        setup.admin.setPermissionLevel(roomId, invite, 100),
        throwsStateError,
      );
    });
  });

  group('settings', () {
    test('address publishes the alias, then the canonical alias', () async {
      final setup = _setup((request) {
        if (request.method == 'GET') {
          return _json([
            ..._roomState(),
            _state('m.room.canonical_alias', '', {
              'alt_aliases': ['#old:other.org'],
            }),
          ]);
        }
        return _json({'event_id': r'$alias'});
      });
      await setup.admin.setRoomAddress(roomId, 'club');
      final writes = setup.log.where((r) => r.method == 'PUT').toList();
      expect(
        writes.first.path,
        '_matrix/client/v3/directory/room/#club:example.org',
      );
      expect(writes.first.body, {'room_id': roomId});
      expect(writes.last.body, {
        'alias': '#club:example.org',
        'alt_aliases': ['#old:other.org'],
      });
    });

    test('join rule and encryption writes are permission-checked', () async {
      final setup = _setup((request) {
        if (request.method == 'GET') return _json(_roomState());
        return _json({'event_id': r'$x'});
      });
      await setup.admin.setJoinRule(roomId, 'knock');
      expect(setup.log.last.body, {'join_rule': 'knock'});
      await expectLater(
        setup.admin.setJoinRule(roomId, 'restricted'),
        throwsStateError, // No authorised spaces to keep.
      );
      await setup.admin.enableEncryption(roomId);
      expect(setup.log.last.path, endsWith('state/m.room.encryption/'));
      await expectLater(
        setup.admin.setHistoryVisibility(roomId, 'everyone'),
        throwsArgumentError,
      );
    });
  });

  group('blocking', () {
    test('read-modify-writes the ignore list', () async {
      Map<String, Object?>? stored = {
        'ignored_users': {'@old:example.org': <String, Object?>{}},
      };
      final setup = _setup((request) {
        if (request.method == 'GET') {
          return stored == null ? _error('M_NOT_FOUND', 404) : _json(stored!);
        }
        stored = request.body;
        return _json({});
      });
      await setup.admin.setIgnored(guest, true);
      expect(stored, {
        'ignored_users': {'@old:example.org': {}, guest: {}},
      });
      expect(setup.admin.isIgnored(guest), isTrue);
      await setup.admin.setIgnored('@old:example.org', false);
      expect(stored, {
        'ignored_users': {guest: {}},
      });
      stored = null;
      await setup.admin.setIgnored('@new:example.org', true);
      expect(stored, {
        'ignored_users': {'@new:example.org': {}},
      });
      await expectLater(setup.admin.setIgnored(me, true), throwsArgumentError);
    });
  });
}
