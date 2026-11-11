import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/home/matrix_home_features.dart';
import 'package:parallax/room_events.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client(http.Client transport)
    : super(
        'home-features-test',
        database: _UnusedDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }
  @override
  String get userID => '@me:matrix.example';
  @override
  String get deviceID => 'THIS';
}

class _Access implements MatrixSdkAccess {
  _Access(this.client);
  final Client client;
  bool current = true;

  @override
  Client? get sdkClient => client;

  @override
  bool isSessionCurrent(Client candidate) =>
      current && identical(candidate, client);
}

Map<String, Object?> _rule(
  String id, {
  bool enabled = true,
  List<Object?> actions = const ['notify'],
}) => {'rule_id': id, 'default': true, 'enabled': enabled, 'actions': actions};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _notFound() =>
    _json({'errcode': 'M_NOT_FOUND', 'error': 'Not found'}, 404);

http.Response _uia() => _json({
  'session': 'uia-session',
  'flows': [
    {
      'stages': ['m.login.password'],
    },
  ],
  'params': <String, Object?>{},
}, 401);

void main() {
  test('notification defaults map Element X push rules', () {
    final rules = PushRuleSet.fromJson({
      'override': [
        _rule(HomePushRules.isRoomMention, enabled: false),
        _rule(HomePushRules.inviteForMe),
      ],
      'underride': [
        _rule(HomePushRules.oneToOne),
        _rule(HomePushRules.encryptedOneToOne),
        _rule(HomePushRules.message, actions: const []),
        _rule(HomePushRules.encrypted),
        _rule(HomePushRules.call, enabled: false),
      ],
    });
    final defaults = notificationDefaultsFromRules(rules);
    expect(defaults.directChats, NotificationDefaultMode.allMessages);
    // Encrypted notifies, unencrypted does not: mismatch, shown as all.
    expect(defaults.groupChats, NotificationDefaultMode.allMessages);
    expect(defaults.mismatch, isTrue);
    expect(defaults.roomMentions, isFalse);
    expect(defaults.invitations, isTrue);
    expect(defaults.calls, isFalse);

    final quiet = notificationDefaultsFromRules(
      PushRuleSet.fromJson({
        'underride': [
          _rule(HomePushRules.message, actions: const []),
          _rule(HomePushRules.encrypted, actions: const ['dont_notify']),
        ],
      }),
    );
    expect(quiet.groupChats, NotificationDefaultMode.mentionsAndKeywords);
    expect(quiet.mismatch, isFalse);
  });

  test('default mode writes both encrypted and plain rules', () async {
    final requests = <String>[];
    final client = _Client(
      MockClient((request) async {
        final path = Uri.decodeComponent(request.url.path);
        requests.add('${request.method} $path ${request.body}');
        if (path.contains('encrypted_room_one_to_one')) return _notFound();
        return _json(<String, Object?>{});
      }),
    );
    final features = MatrixHomeFeatures(_Access(client));
    await features.setDefaultNotificationMode(
      directChats: true,
      allMessages: false,
    );
    expect(requests, [
      'PUT /_matrix/client/v3/pushrules/global/underride/.m.rule.room_one_to_one/actions {"actions":[]}',
      'PUT /_matrix/client/v3/pushrules/global/underride/.m.rule.room_one_to_one/enabled {"enabled":true}',
      'PUT /_matrix/client/v3/pushrules/global/underride/.m.rule.encrypted_room_one_to_one/actions {"actions":[]}',
    ]);

    requests.clear();
    await features.setNotificationToggle(NotificationToggle.calls, true);
    expect(requests, [
      'PUT /_matrix/client/v3/pushrules/global/underride/.m.rule.call/enabled {"enabled":true}',
    ]);
  });

  test('a missing rule set fails rather than reporting success', () async {
    final client = _Client(MockClient((_) async => _notFound()));
    final features = MatrixHomeFeatures(_Access(client));
    await expectLater(
      features.setNotificationToggle(NotificationToggle.invitations, false),
      throwsStateError,
    );
  });

  test(
    'account management parses unknown provider actions leniently',
    () async {
      final client = _Client(
        MockClient((request) async {
          if (request.url.path == '/_matrix/client/v1/auth_metadata') {
            return _json({
              'issuer': 'https://auth.example/',
              'account_management_uri': 'https://auth.example/account/',
              'account_management_actions_supported': [
                'org.matrix.profile',
                'org.matrix.session_end',
                'org.matrix.device_delete',
                'org.matrix.account_deactivate',
              ],
            });
          }
          fail('unexpected ${request.url}');
        }),
      );
      final management = await MatrixHomeFeatures(
        _Access(client),
      ).accountManagement();
      expect(management.url, Uri.parse('https://auth.example/account/'));
      expect(management.delegated, isTrue);
      expect(
        management.deactivateUrl().toString(),
        'https://auth.example/account/?action=org.matrix.account_deactivate',
      );
    },
  );

  test('password changes follow the server capability', () async {
    final client = _Client(
      MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('auth_metadata') ||
            path == '/.well-known/matrix/client') {
          return _json({'errcode': 'M_UNRECOGNIZED', 'error': 'no'}, 404);
        }
        if (path == '/_matrix/client/v3/capabilities') {
          return _json({
            'capabilities': {
              'm.change_password': {'enabled': false},
            },
          });
        }
        fail('unexpected $path');
      }),
    );
    final management = await MatrixHomeFeatures(
      _Access(client),
    ).accountManagement();
    expect(management.url, isNull);
    expect(management.canChangePassword, isFalse);
  });

  test('sign out of other sessions answers password UIA', () async {
    final bodies = <Map<String, Object?>>[];
    final client = _Client(
      MockClient((request) async {
        expect(request.url.path, '/_matrix/client/v3/delete_devices');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        bodies.add(body);
        return body.containsKey('auth') ? _json({}) : _uia();
      }),
    );
    final features = MatrixHomeFeatures(_Access(client));
    await expectLater(
      features.signOutSessions(['THIS', 'OTHER']),
      throwsA(isA<PasswordRequired>()),
    );
    expect(bodies.single['devices'], ['OTHER']);
    bodies.clear();
    await features.signOutSessions(['OTHER'], password: 'secret');
    expect(bodies.last['auth'], {
      'type': 'm.login.password',
      'session': 'uia-session',
      'password': 'secret',
      'identifier': {'type': 'm.id.user', 'user': '@me:matrix.example'},
    });
  });

  test('deactivation sends erase with password auth', () async {
    final bodies = <Map<String, Object?>>[];
    final client = _Client(
      MockClient((request) async {
        expect(request.url.path, '/_matrix/client/v3/account/deactivate');
        final body = jsonDecode(request.body) as Map<String, Object?>;
        bodies.add(body);
        return body.containsKey('auth')
            ? _json({'id_server_unbind_result': 'success'})
            : _uia();
      }),
    );
    await MatrixHomeFeatures(
      _Access(client),
    ).deactivateAccount(password: 'secret', eraseMessages: true);
    expect(bodies, hasLength(2));
    expect(bodies.last['erase'], isTrue);
    expect((bodies.last['auth'] as Map)['session'], 'uia-session');
  });

  test('a replaced session rejects late results', () async {
    late _Access access;
    final client = _Client(
      MockClient((request) async {
        access.current = false;
        return _json({'devices': <Object?>[]});
      }),
    );
    access = _Access(client);
    await expectLater(MatrixHomeFeatures(access).sessions(), throwsStateError);
  });

  test('only https account pages are accepted', () {
    expect(safeAccountUrl('https://auth.example/account'), isNotNull);
    expect(safeAccountUrl('http://auth.example/account'), isNull);
    expect(safeAccountUrl('https://user@auth.example/'), isNull);
    expect(safeAccountUrl('javascript:alert(1)'), isNull);
    expect(safeAccountUrl(42), isNull);
  });
}
