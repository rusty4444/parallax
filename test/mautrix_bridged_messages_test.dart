import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/bridged_messages/bridged_message_models.dart';
import 'package:parallax/features/bridged_messages/mautrix_bridged_messages.dart';
import 'package:parallax/room_events.dart';

import 'widget_test.dart' show FakeBackend;

const _base = 'https://messages.example.org/_matrix/provision';
const _messengerBase = 'https://messenger.example.org/_matrix/provision';
const _instagramBase = 'https://instagram.example.org/_matrix/provision';
const _auth = ProvisioningAuth(
  userId: '@me:example.org',
  accessToken: 'test-matrix-token',
  deviceId: 'DEVICE',
);
const _capabilities = BridgeCapabilities(
  canListContacts: false,
  canSearchRecipients: false,
  canResolvePhoneNumber: false,
  canResolveUsername: false,
  canUseAnyPhoneNumber: true,
  canCreateDirectConversation: true,
  supportedIdentifierTypes: {BridgeIdentifierType.phoneNumber},
);
const _metaCapabilities = BridgeCapabilities(
  canListContacts: false,
  canSearchRecipients: true,
  canResolvePhoneNumber: false,
  canResolveUsername: false,
  canUseAnyPhoneNumber: false,
  canCreateDirectConversation: true,
  supportedIdentifierTypes: {BridgeIdentifierType.remoteId},
);
const _account = BridgeAccount(
  service: BridgedService.googleMessages,
  accountId: 'login-1',
  displayName: 'Personal',
  capabilities: _capabilities,
  availability: BridgeAccountAvailability.connected,
);
const _instagramAccount = BridgeAccount(
  service: BridgedService.instagram,
  accountId: 'ig-login-1',
  displayName: '@sam',
  capabilities: _metaCapabilities,
  availability: BridgeAccountAvailability.connected,
);
const _messengerAccount = BridgeAccount(
  service: BridgedService.messenger,
  accountId: 'fb-login-1',
  displayName: 'Sam',
  capabilities: _metaCapabilities,
  availability: BridgeAccountAvailability.connected,
);
const _recipient = BridgeRecipient(
  service: BridgedService.googleMessages,
  accountId: 'login-1',
  identifierType: BridgeIdentifierType.phoneNumber,
  canonicalIdentifier: '+61412345678',
  remoteUserId: '+61412345678',
);

MautrixProvisioningApi _api(
  Future<http.Response> Function(http.BaseRequest request) handler,
) => MautrixProvisioningApi({
  BridgedService.googleMessages: Uri.parse(_base),
  BridgedService.messenger: Uri.parse(_messengerBase),
  BridgedService.instagram: Uri.parse(_instagramBase),
}, httpClient: MockClient(handler));

void expectAuthAndAccount(
  http.BaseRequest request, {
  bool login = true,
  String loginId = 'login-1',
}) {
  expect(request.headers['Authorization'], 'Bearer test-matrix-token');
  expect(request.url.queryParameters['user_id'], '@me:example.org');
  if (login) expect(request.url.queryParameters['login_id'], loginId);
}

class _StubClient extends Fake implements matrix.Client {
  @override
  String? userID = '@me:example.org';

  @override
  String? accessToken = 'test-matrix-token';

  @override
  String? deviceID = 'DEVICE';

  bool logged = true;

  @override
  bool isLogged() => logged;
}

class _SdkFakeBackend extends FakeBackend implements MatrixSdkAccess {
  _SdkFakeBackend(this.client);

  _StubClient? client;
  bool sessionCurrent = true;

  @override
  matrix.Client? get sdkClient => client;

  @override
  bool isSessionCurrent(matrix.Client candidate) =>
      sessionCurrent && identical(candidate, client);
}

class _HeldClient extends http.BaseClient {
  final completer = Completer<http.StreamedResponse>();
  final aborted = Completer<void>();
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    final abortable = request as http.Abortable;
    final trigger = abortable.abortTrigger;
    if (trigger == null) throw StateError('Missing abort trigger');
    trigger.then((_) {
      if (!aborted.isCompleted) aborted.complete();
    });
    return Future.any<http.StreamedResponse>([
      completer.future,
      trigger.then((_) => throw http.RequestAbortedException(request.url)),
    ]);
  }
}

void main() {
  test('loads capabilities and account state with Matrix auth', () async {
    final paths = <String>[];
    final api = _api((request) async {
      paths.add(request.url.path);
      expectAuthAndAccount(request, login: false);
      if (request.url.path.endsWith('/capabilities')) {
        return http.Response(
          jsonEncode({
            'resolve_identifier': {
              'create_dm': true,
              'any_phone': true,
              'contact_list': false,
              'search': false,
            },
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'logins': [
            {
              'id': 'login-1',
              'name': 'Personal',
              'state': {'state_event': 'CONNECTED'},
            },
          ],
        }),
        200,
      );
    });
    final accounts = await api.loadAccounts(
      BridgedService.googleMessages,
      _auth,
    );
    expect(paths, [
      '/_matrix/provision/v3/capabilities',
      '/_matrix/provision/v3/whoami',
    ]);
    expect(accounts, hasLength(1));
    expect(accounts.single.accountId, 'login-1');
    expect(accounts.single.displayName, 'Personal');
    expect(accounts.single.availability, BridgeAccountAvailability.connected);
    expect(accounts.single.capabilities.canUseAnyPhoneNumber, isTrue);
    expect(accounts.single.capabilities.canSearchRecipients, isFalse);
  });

  test(
    'malformed capabilities fail closed instead of disabling creation',
    () async {
      for (final body in ['[]', '{}', '{"resolve_identifier":[]}']) {
        var calls = 0;
        final api = _api((_) async {
          calls++;
          return http.Response(body, 200);
        });
        await expectLater(
          api.loadAccounts(BridgedService.googleMessages, _auth),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.malformedResponse,
            ),
          ),
        );
        expect(calls, 1);
      }
    },
  );

  test('account-discovery errors do not blame a recipient', () async {
    for (final (status, message) in [
      (400, 'rejected the request'),
      (404, 'account-discovery API'),
      (401, 'Matrix session'),
    ]) {
      final api = _api((_) async => http.Response('not json', status));
      await expectLater(
        api.loadAccounts(BridgedService.googleMessages, _auth),
        throwsA(
          isA<BridgedMessageException>().having(
            (error) => error.message,
            'message',
            allOf(contains(message), isNot(contains('phone number'))),
          ),
        ),
      );
    }
  });

  test('read-only phone resolution is separate from creation', () async {
    var calls = 0;
    final api = _api((request) async {
      calls++;
      expect(request.method, 'GET');
      expectAuthAndAccount(request);
      expect(request.url.pathSegments.last, '+61412345678');
      return http.Response(jsonEncode({'id': '+61412345678'}), 200);
    });
    final recipient = await api.resolveRecipient(
      _account,
      '0412 345 678',
      _auth,
      defaultRegion: 'AU',
    );
    expect(recipient.canonicalIdentifier, '+61412345678');
    expect(recipient.verifiedRemoteIdentity, isFalse);
    expect(calls, 1);
  });

  for (final status in [200, 201]) {
    test('maps HTTP $status without claiming a new remote thread', () async {
      final api = _api((request) async {
        expect(request.method, 'POST');
        expectAuthAndAccount(request);
        expect(
          request.url.path,
          '/_matrix/provision/v3/create_dm/+61412345678',
        );
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({
            'id': 'remote-user',
            'mxid': '@gmessages_remote:example.org',
            'dm_room_mxid': '!room:example.org',
          }),
          status,
        );
      });
      final conversation = await api.ensureDirectConversation(
        _account,
        _recipient,
        _auth,
      );
      expect(conversation.roomId, '!room:example.org');
      expect(conversation.portalCreated, status == 201);
      expect(conversation.createdOrExisting, ConversationCreationState.unknown);
    });
  }

  test(
    'rejects recipient/account mismatch without a network request',
    () async {
      var calls = 0;
      final api = _api((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      const other = BridgeRecipient(
        service: BridgedService.googleMessages,
        accountId: 'another-login',
        identifierType: BridgeIdentifierType.phoneNumber,
        canonicalIdentifier: '+61412345678',
      );
      await expectLater(
        api.ensureDirectConversation(_account, other, _auth),
        throwsA(
          isA<BridgedMessageException>().having(
            (error) => error.kind,
            'kind',
            BridgedMessageErrorKind.permissionDenied,
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  test('disconnected accounts fail before a network request', () async {
    var calls = 0;
    final api = _api((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    const disconnected = BridgeAccount(
      service: BridgedService.googleMessages,
      accountId: 'login-1',
      displayName: 'Personal',
      capabilities: _capabilities,
      availability: BridgeAccountAvailability.disconnected,
    );
    await expectLater(
      api.ensureDirectConversation(disconnected, _recipient, _auth),
      throwsA(
        isA<BridgedMessageException>().having(
          (error) => error.kind,
          'kind',
          BridgedMessageErrorKind.disconnected,
        ),
      ),
    );
    expect(calls, 0);
  });

  group('safe creation errors', () {
    final cases = [
      (400, 'M_INVALID_PARAM', BridgedMessageErrorKind.invalidIdentifier, true),
      (401, 'M_UNKNOWN_TOKEN', BridgedMessageErrorKind.disconnected, true),
      (403, 'M_FORBIDDEN', BridgedMessageErrorKind.permissionDenied, false),
      (404, 'M_NOT_FOUND', BridgedMessageErrorKind.recipientNotFound, true),
      (400, 'M_LIMIT_EXCEEDED', BridgedMessageErrorKind.rateLimited, true),
      (
        501,
        'M_UNRECOGNIZED',
        BridgedMessageErrorKind.unsupportedOperation,
        true,
      ),
      (500, 'M_UNKNOWN', BridgedMessageErrorKind.uncertainOutcome, false),
    ];
    for (final (status, code, kind, definite) in cases) {
      test(
        '$status $code maps to $kind without exposing response details',
        () async {
          final api = _api(
            (_) async => http.Response(
              jsonEncode({
                'errcode': code,
                'error': 'private bridge internals and +61412345678',
              }),
              status,
            ),
          );
          try {
            await api.ensureDirectConversation(_account, _recipient, _auth);
            fail('creation should fail');
          } on BridgedMessageException catch (error) {
            expect(error.kind, kind);
            expect(error.definiteNonCreation, definite);
            expect(error.message, isNot(contains('private bridge internals')));
            expect(error.message, isNot(contains('+61412345678')));
          }
        },
      );
    }
  });

  test('network failure during creation is uncertain', () async {
    final api = _api((_) async => throw http.ClientException('offline'));
    await expectLater(
      api.ensureDirectConversation(_account, _recipient, _auth),
      throwsA(
        isA<BridgedMessageException>()
            .having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.uncertainOutcome,
            )
            .having(
              (error) => error.definiteNonCreation,
              'definiteNonCreation',
              isFalse,
            ),
      ),
    );
  });

  test(
    'creation deadline aborts transport and ignores a late response',
    () async {
      final client = _HeldClient();
      final api = MautrixProvisioningApi(
        {BridgedService.googleMessages: Uri.parse(_base)},
        httpClient: client,
        createTimeout: const Duration(milliseconds: 5),
      );
      await expectLater(
        api.ensureDirectConversation(_account, _recipient, _auth),
        throwsA(
          isA<BridgedMessageException>()
              .having(
                (error) => error.kind,
                'kind',
                BridgedMessageErrorKind.uncertainOutcome,
              )
              .having(
                (error) => error.definiteNonCreation,
                'definiteNonCreation',
                isFalse,
              ),
        ),
      );
      await client.aborted.future;
      expect(client.calls, 1);
      client.completer.complete(
        http.StreamedResponse(
          Stream.value(utf8.encode('{"dm_room_mxid":"!late:example.org"}')),
          201,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.calls, 1);
    },
  );

  test(
    'malformed or oversized successful create responses stay uncertain',
    () async {
      for (final response in [
        http.Response('{}', 200),
        http.Response('{"dm_room_mxid":"!missing-server"}', 200),
        http.Response.bytes(List.filled(129 * 1024, 65), 200),
      ]) {
        final api = _api((_) async => response);
        await expectLater(
          api.ensureDirectConversation(_account, _recipient, _auth),
          throwsA(
            isA<BridgedMessageException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  BridgedMessageErrorKind.malformedResponse,
                )
                .having(
                  (error) => error.definiteNonCreation,
                  'definiteNonCreation',
                  isFalse,
                ),
          ),
        );
      }
    },
  );

  group('Meta recipient search, creation and resilience', () {
    test(
      'searchRecipients posts query with login_id, filters unmessageable IDs and deduplicates',
      () async {
        var calls = 0;
        final api = _api((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.host, 'instagram.example.org');
          expect(request.url.path, '/_matrix/provision/v3/search_users');
          expectAuthAndAccount(request, loginId: 'ig-login-1');
          expect(
            request.headers['Content-Type'],
            startsWith('application/json'),
          );
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(body, {'query': 'alice.example'});
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': '0',
                  'name': 'Unmessageable Zero ID',
                  'identifiers': ['instagram:unmessageable'],
                },
                {
                  'id': '17841400000000001',
                  'name': 'Alice Example',
                  'avatar_url': 'mxc://example.org/avatar123',
                  'identifiers': ['instagram:alice.example'],
                  'mxid': '@instagram_17841400000000001:example.org',
                },
                {'id': '17841400000000001', 'name': 'Duplicate Alice'},
                {
                  'id': '9001',
                  'name': 'Bob Example',
                  'avatar_url': 'https://untrusted.example/pic.jpg',
                },
              ],
            }),
            200,
          );
        });
        final results = await api.searchRecipients(
          _instagramAccount,
          ' @alice.example ',
          _auth,
        );
        expect(calls, 1);
        expect(results, hasLength(2));
        expect(results.first.canonicalIdentifier, '17841400000000001');
        expect(results.first.displayName, 'Alice Example');
        expect(results.first.formattedIdentifiers, '@alice.example');
        expect(results.first.avatar?.toString(), 'mxc://example.org/avatar123');
        expect(results.first.verifiedRemoteIdentity, isTrue);
        expect(results.last.canonicalIdentifier, '9001');
        expect(results.last.avatar, isNull);
      },
    );

    test(
      'searchRecipients rejects unsupported or disconnected accounts without network',
      () async {
        var calls = 0;
        final api = _api((_) async {
          calls++;
          return http.Response('{}', 200);
        });
        await expectLater(
          api.searchRecipients(_account, 'alice', _auth),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.unsupportedOperation,
            ),
          ),
        );
        const disconnectedIg = BridgeAccount(
          service: BridgedService.instagram,
          accountId: 'ig-login-1',
          displayName: '@sam',
          capabilities: _metaCapabilities,
          availability: BridgeAccountAvailability.disconnected,
        );
        await expectLater(
          api.searchRecipients(disconnectedIg, 'alice', _auth),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.disconnected,
            ),
          ),
        );
        expect(calls, 0);
      },
    );

    test(
      'ensureDirectConversation posts numeric Meta ID and rejects arbitrary usernames',
      () async {
        var calls = 0;
        final api = _api((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.host, 'instagram.example.org');
          expect(
            request.url.path,
            '/_matrix/provision/v3/create_dm/17841400000000001',
          );
          expectAuthAndAccount(request, loginId: 'ig-login-1');
          return http.Response(
            jsonEncode({
              'id': '17841400000000001',
              'mxid': '@instagram_17841400000000001:example.org',
              'dm_room_mxid': '!igroom:example.org',
            }),
            201,
          );
        });
        const igRecipient = BridgeRecipient(
          service: BridgedService.instagram,
          accountId: 'ig-login-1',
          identifierType: BridgeIdentifierType.remoteId,
          canonicalIdentifier: '17841400000000001',
          remoteUserId: '17841400000000001',
          displayName: 'Alice Example',
          identifiers: ['instagram:alice.example'],
          verifiedRemoteIdentity: true,
        );
        final conversation = await api.ensureDirectConversation(
          _instagramAccount,
          igRecipient,
          _auth,
        );
        expect(conversation.roomId, '!igroom:example.org');
        expect(conversation.service, BridgedService.instagram);
        expect(conversation.portalCreated, isTrue);
        expect(calls, 1);

        const invalidMetaRecipient = BridgeRecipient(
          service: BridgedService.instagram,
          accountId: 'ig-login-1',
          identifierType: BridgeIdentifierType.remoteId,
          canonicalIdentifier: 'alice.example',
        );
        await expectLater(
          api.ensureDirectConversation(
            _instagramAccount,
            invalidMetaRecipient,
            _auth,
          ),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.invalidIdentifier,
            ),
          ),
        );
        expect(calls, 1);
      },
    );

    test(
      'Meta error mapping handles FI.MAU.NOT_CONNECTED and avoids phone-number wording',
      () async {
        final disconnectedApi = _api(
          (_) async => http.Response(
            jsonEncode({
              'errcode': 'FI.MAU.NOT_CONNECTED',
              'error': 'internal socket closed',
            }),
            503,
          ),
        );
        await expectLater(
          disconnectedApi.ensureDirectConversation(
            _messengerAccount,
            const BridgeRecipient(
              service: BridgedService.messenger,
              accountId: 'fb-login-1',
              identifierType: BridgeIdentifierType.remoteId,
              canonicalIdentifier: '100001234567890',
            ),
            _auth,
          ),
          throwsA(
            isA<BridgedMessageException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  BridgedMessageErrorKind.disconnected,
                )
                .having(
                  (error) => error.definiteNonCreation,
                  'definiteNonCreation',
                  isTrue,
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('internal socket')),
                ),
          ),
        );

        final invalidSearchApi = _api(
          (_) async => http.Response(
            jsonEncode({'errcode': 'M_INVALID_PARAM', 'error': 'bad query'}),
            400,
          ),
        );
        await expectLater(
          invalidSearchApi.searchRecipients(_messengerAccount, 'alice', _auth),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.message,
              'message',
              allOf(contains('search'), isNot(contains('phone number'))),
            ),
          ),
        );
      },
    );

    test(
      'Default deadlines cover Meta connection wait plus ghost sync below the proxy timeout',
      () {
        final api = MautrixProvisioningApi({
          BridgedService.messenger: Uri.parse(_messengerBase),
        });
        // Messenger waits up to 60s for its socket and search_users then
        // synchronously refreshes ghost profiles; live searches measured
        // 44-65s while CONNECTED. The nginx proxy read timeout is 90s.
        expect(api.readTimeout, const Duration(seconds: 15));
        expect(api.metaReadTimeout, const Duration(seconds: 80));
        expect(api.createTimeout, const Duration(seconds: 85));
        expect(api.metaReadTimeout.inSeconds, greaterThan(65));
        expect(api.createTimeout.inSeconds, greaterThan(75));
        expect(api.metaReadTimeout.inSeconds, lessThan(90));
        expect(api.createTimeout.inSeconds, lessThan(90));
      },
    );

    test(
      'Meta read operations use metaReadTimeout rather than Google readTimeout',
      () async {
        final client = _HeldClient();
        final api = MautrixProvisioningApi(
          {
            BridgedService.googleMessages: Uri.parse(_base),
            BridgedService.messenger: Uri.parse(_messengerBase),
          },
          httpClient: client,
          readTimeout: const Duration(milliseconds: 5),
          metaReadTimeout: const Duration(milliseconds: 80),
        );
        final future = api.searchRecipients(_messengerAccount, 'alice', _auth);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.aborted.isCompleted, isFalse);
        client.completer.complete(
          http.StreamedResponse(
            Stream.value(utf8.encode('{"results":[]}')),
            200,
          ),
        );
        expect(await future, isEmpty);
      },
    );

    test(
      'keeps healthy accounts and records serviceWarnings when one bridge fails',
      () async {
        final config = BridgedMessageConfig.fromValues(
          enabled: true,
          googleMessagesUrl: _base,
          messengerUrl: _messengerBase,
          instagramUrl: _instagramBase,
        );
        final api = _api((request) async {
          if (request.url.host == 'messenger.example.org') {
            return http.Response('bad gateway', 502);
          }
          if (request.url.path.endsWith('/capabilities')) {
            final isMeta = request.url.host == 'instagram.example.org';
            return http.Response(
              jsonEncode({
                'resolve_identifier': {
                  'create_dm': true,
                  'any_phone': !isMeta,
                  'search': isMeta,
                },
              }),
              200,
            );
          }
          final id = request.url.host == 'instagram.example.org'
              ? 'ig-1'
              : 'gm-1';
          return http.Response(
            jsonEncode({
              'logins': [
                {
                  'id': id,
                  'name': id,
                  'state': {'state_event': 'CONNECTED'},
                },
              ],
            }),
            200,
          );
        });
        final backend = _SdkFakeBackend(_StubClient());
        final live = MatrixBridgedMessages(backend, config, api: api);
        final accounts = await live.loadAccounts();
        expect(accounts.map((a) => a.key), [
          'googleMessages:gm-1',
          'instagram:ig-1',
        ]);
        expect(live.serviceWarnings, hasLength(1));
        expect(live.serviceWarnings.single, contains('Messenger'));
      },
    );

    test('invalidates results when the Matrix user changes mid-call', () async {
      final config = BridgedMessageConfig.fromValues(
        enabled: true,
        instagramUrl: _instagramBase,
      );
      final stub = _StubClient();
      final backend = _SdkFakeBackend(stub);
      final api = _api((_) async {
        stub.userID = '@someone-else:example.org';
        return http.Response('{"results":[]}', 200);
      });
      final live = MatrixBridgedMessages(backend, config, api: api);
      await expectLater(
        live.searchRecipients(_instagramAccount, 'alice'),
        throwsStateError,
      );
    });

    test('a refreshed access token mid-create keeps the confirmed room', () async {
      // Regression: a ~40s gmessages create_dm refreshed the SDK token; the old
      // token-string pin threw StateError after the 201, discarding the room ID
      // and locking the inbox into "Room creation not confirmed".
      final config = BridgedMessageConfig.fromValues(
        enabled: true,
        googleMessagesUrl: _base,
      );
      final stub = _StubClient();
      final backend = _SdkFakeBackend(stub);
      final api = _api((_) async {
        stub.accessToken = 'rotated-token';
        return http.Response('{"dm_room_mxid":"!room:example.org"}', 201);
      });
      final live = MatrixBridgedMessages(backend, config, api: api);
      final conversation = await live.ensureDirectConversation(
        _account,
        _recipient,
      );
      expect(conversation.roomId, '!room:example.org');
      expect(stub.userID, '@me:example.org');
      expect(stub.deviceID, 'DEVICE');
    });

    test('a logged-out session mid-create still invalidates', () async {
      final config = BridgedMessageConfig.fromValues(
        enabled: true,
        googleMessagesUrl: _base,
      );
      final stub = _StubClient();
      final backend = _SdkFakeBackend(stub);
      final api = _api((_) async {
        backend.sessionCurrent = false;
        return http.Response('{"dm_room_mxid":"!room:example.org"}', 201);
      });
      final live = MatrixBridgedMessages(backend, config, api: api);
      await expectLater(
        live.ensureDirectConversation(_account, _recipient),
        throwsStateError,
      );
    });
  });
}
