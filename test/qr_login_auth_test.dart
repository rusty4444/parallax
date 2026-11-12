// OAuth 2.0 device authorization grant (RFC 8628) for QR sign-in, against a
// fake homeserver + MAS behind an http MockClient, through the real
// MatrixAuthService commit path and the MatrixBackend UI hold.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/matrix_auth_service.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/secure_store.dart';

const _hs = 'https://matrix.example';

http.Response _json(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object?> _metadata() => {
  'issuer': 'https://id.example/',
  'authorization_endpoint': 'https://id.example/authorize',
  'token_endpoint': 'https://id.example/oauth2/token',
  'registration_endpoint': 'https://id.example/oauth2/registration',
  'revocation_endpoint': 'https://id.example/oauth2/revoke',
  'device_authorization_endpoint': 'https://id.example/oauth2/device',
  'grant_types_supported': [
    'authorization_code',
    'refresh_token',
    'urn:ietf:params:oauth:grant-type:device_code',
  ],
  // Unknown actions must not break the lenient device-grant parser.
  'account_management_actions_supported': ['org.matrix.session_end', 'x.y'],
};

class _FakeMas {
  _FakeMas();
  final requests = <http.Request>[];
  Map<String, Object?> metadata = _metadata();
  bool wellKnownDelegates = false;
  List<Object> tokenReplies = [
    {'error': 'authorization_pending'},
    {'error': 'slow_down'},
    {
      'access_token': 'mat_access',
      'refresh_token': 'mar_refresh',
      'token_type': 'Bearer',
      'expires_in': 300,
    },
  ];
  String? scopeDevice;
  String? whoamiDevice;
  Map<String, Object?> deviceResponse = {
    'device_code': 'secret-device-code',
    'user_code': 'ABCD-1234',
    'verification_uri': 'https://id.example/link',
    'verification_uri_complete': 'https://id.example/link?code=ABCD-1234',
    'expires_in': 600,
    'interval': 5,
  };

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    expect(request.followRedirects, isFalse);
    final url = request.url;
    final path = url.path;
    if (path == '/.well-known/matrix/client') {
      if (url.host == 'example.org' && wellKnownDelegates) {
        return _json({
          'm.homeserver': {'base_url': _hs},
        });
      }
      return _json({}, 404);
    }
    if (path == '/_matrix/client/versions') {
      return _json({
        'versions': ['v1.15'],
      });
    }
    if (path == '/_matrix/client/v1/auth_metadata') {
      return _json(metadata);
    }
    if (path.endsWith('/auth_metadata')) return _json({}, 404);
    if (path == '/oauth2/registration') {
      return _json({
        ...jsonDecode(request.body) as Map<String, dynamic>,
        'client_id': 'device-client',
      }, 201);
    }
    if (path == '/oauth2/device') {
      final scope = request.bodyFields['scope']!;
      scopeDevice = scope.split(' ').last.split(':').last;
      return _json(deviceResponse);
    }
    if (path == '/oauth2/token') {
      final reply = tokenReplies.removeAt(0);
      final error = reply is Map && reply.containsKey('error');
      return _json(reply, error ? 400 : 200);
    }
    if (path == '/_matrix/client/v3/account/whoami') {
      expect(request.headers['authorization'], 'Bearer mat_access');
      return _json({
        'user_id': '@sam:matrix.example',
        'device_id': whoamiDevice ?? scopeDevice,
      });
    }
    return _json({'errcode': 'M_UNRECOGNIZED'}, 404);
  });
}

class _Store implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Database implements matrix.DatabaseApi {
  Map<String, dynamic>? account;
  @override
  Future<Map<String, dynamic>?> getClient(String name) async => account;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends matrix.Client {
  _Client(http.Client httpClient)
    : super('qr-test', database: _Database(), httpClient: httpClient);
  String? currentUser;
  String? currentDevice;
  final inits = <Map<String, Object?>>[];
  Future<void> Function()? duringInit;

  @override
  String? get userID => currentUser;
  @override
  String? get deviceID => currentDevice;

  @override
  Future<void> init({
    String? newToken,
    DateTime? newTokenExpiresAt,
    String? newRefreshToken,
    Uri? newHomeserver,
    String? newUserID,
    String? newDeviceName,
    String? newDeviceID,
    String? newOlmAccount,
    String? newOidcClientId,
    bool waitForFirstSync = true,
    bool waitUntilLoadCompletedLoaded = true,
    void Function()? onMigration,
    void Function(matrix.InitState)? onInitStateChanged,
  }) async {
    inits.add({
      'token': newToken,
      'refresh': newRefreshToken,
      'homeserver': newHomeserver.toString(),
      'user': newUserID,
      'device': newDeviceID,
      'oidc': newOidcClientId,
      'olm': newOlmAccount,
      'expires': newTokenExpiresAt != null,
    });
    accessToken = newToken;
    homeserver = newHomeserver;
    currentUser = newUserID;
    currentDevice = newDeviceID;
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
    await duringInit?.call();
  }

  @override
  bool isLogged() => accessToken != null;
}

void main() {
  late _FakeMas mas;
  late _Client client;
  late _Store storage;
  late MatrixAuthService service;
  late List<Duration> waits;

  setUp(() {
    mas = _FakeMas();
    client = _Client(mas.client);
    storage = _Store();
    waits = [];
    service = MatrixAuthService(
      client,
      ownerCurrent: () => true,
      storage: storage,
    );
  });
  tearDown(() => service.dispose());

  Future<void> fastWait(Duration d) async => waits.add(d);

  test('registers, authorizes, polls and commits the session', () async {
    DeviceAuthorizationGrant? granted;
    await service.deviceAuthorizationLogin(
      _hs,
      delay: fastWait,
      onGrant: (grant) async => granted = grant,
    );
    // Dynamic registration includes the device-code grant (Element X).
    final registration = mas.requests.firstWhere(
      (r) => r.url.path == '/oauth2/registration',
    );
    final body = jsonDecode(registration.body) as Map;
    expect(body['grant_types'], [
      'authorization_code',
      'refresh_token',
      'urn:ietf:params:oauth:grant-type:device_code',
    ]);
    expect(body['application_type'], 'native');
    expect(body['token_endpoint_auth_method'], 'none');
    expect(body['redirect_uris'], ['net.samrusselltech.parallax:/auth']);
    expect(body['client_uri'], 'https://samrusselltech.net/');

    // Stable Matrix scopes bind a fresh device ID (matrix-rust-sdk).
    final authorization = mas.requests.firstWhere(
      (r) => r.url.path == '/oauth2/device',
    );
    expect(authorization.bodyFields['client_id'], 'device-client');
    expect(
      authorization.bodyFields['scope'],
      'urn:matrix:client:api:* urn:matrix:client:device:${mas.scopeDevice}',
    );

    // Only user-facing values are handed on, never the device code.
    expect(granted!.userCode, 'ABCD-1234');
    expect(granted!.deviceId, mas.scopeDevice);
    expect(granted!.verificationUri.toString(), 'https://id.example/link');
    expect(
      granted!.verificationUriComplete.toString(),
      'https://id.example/link?code=ABCD-1234',
    );

    // RFC 8628 polling: interval, then slow_down adds five seconds.
    final polls = mas.requests.where((r) => r.url.path == '/oauth2/token');
    expect(polls, hasLength(3));
    expect(polls.first.bodyFields, {
      'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      'device_code': 'secret-device-code',
      'client_id': 'device-client',
    });
    expect(waits, [
      const Duration(seconds: 5),
      const Duration(seconds: 5),
      const Duration(seconds: 10),
    ]);

    expect(client.inits.single, {
      'token': 'mat_access',
      'refresh': 'mar_refresh',
      'homeserver': _hs,
      'user': '@sam:matrix.example',
      'device': mas.scopeDevice,
      'oidc': 'device-client',
      'olm': null,
      'expires': true,
    });
    expect(storage.values.values, contains('device-client'));
  });

  test('reuses the cached device-grant registration', () async {
    await service.deviceAuthorizationLogin(
      _hs,
      delay: fastWait,
      onGrant: (_) async {},
    );
    client
      ..currentUser = null
      ..currentDevice = null
      ..accessToken = null;
    mas.tokenReplies = [
      {'access_token': 'mat_access', 'token_type': 'Bearer'},
    ];
    mas.requests.clear();
    await service.deviceAuthorizationLogin(
      _hs,
      delay: fastWait,
      onGrant: (_) async {},
    );
    expect(
      mas.requests.where((r) => r.url.path == '/oauth2/registration'),
      isEmpty,
    );
  });

  test('follows HTTPS well-known delegation from a server name', () async {
    mas.wellKnownDelegates = true;
    await service.deviceAuthorizationLogin(
      'example.org',
      delay: fastWait,
      onGrant: (_) async {},
    );
    expect(client.inits.single['homeserver'], _hs);
  });

  for (final (error, failure) in [
    ('access_denied', DeviceAuthorizationFailure.declined),
    ('expired_token', DeviceAuthorizationFailure.expired),
  ]) {
    test('$error maps to ${failure.name} and commits nothing', () async {
      mas.tokenReplies = [
        {'error': 'authorization_pending'},
        {'error': error},
      ];
      await expectLater(
        service.deviceAuthorizationLogin(
          _hs,
          delay: fastWait,
          onGrant: (_) async {},
        ),
        throwsA(
          isA<DeviceAuthorizationException>().having(
            (e) => e.failure,
            'failure',
            failure,
          ),
        ),
      );
      expect(client.inits, isEmpty);
    });
  }

  test('a provider without the device grant is unsupported', () async {
    mas.metadata = _metadata()..remove('device_authorization_endpoint');
    await expectLater(
      service.deviceAuthorizationLogin(_hs, onGrant: (_) async {}),
      throwsA(
        isA<DeviceAuthorizationException>().having(
          (e) => e.failure,
          'failure',
          DeviceAuthorizationFailure.unsupported,
        ),
      ),
    );
    mas.metadata = _metadata()
      ..['grant_types_supported'] = ['authorization_code'];
    await expectLater(
      service.deviceAuthorizationLogin(_hs, onGrant: (_) async {}),
      throwsA(isA<DeviceAuthorizationException>()),
    );
    expect(
      mas.requests.where((r) => r.url.path == '/oauth2/registration'),
      isEmpty,
    );
  });

  test('cancelling stops polling', () async {
    final cancel = Completer<void>();
    mas.tokenReplies = List.generate(
      10,
      (_) => {'error': 'authorization_pending'},
    );
    await expectLater(
      service.deviceAuthorizationLogin(
        _hs,
        cancelled: cancel.future,
        delay: (d) async {
          waits.add(d);
          if (waits.length == 2) cancel.complete();
        },
        onGrant: (_) async {},
      ),
      throwsA(
        isA<DeviceAuthorizationException>().having(
          (e) => e.failure,
          'failure',
          DeviceAuthorizationFailure.cancelled,
        ),
      ),
    );
    expect(client.inits, isEmpty);
  });

  test('a different device from whoami is refused', () async {
    mas.whoamiDevice = 'SOMEONEELSE';
    await expectLater(
      service.deviceAuthorizationLogin(
        _hs,
        delay: fastWait,
        onGrant: (_) async {},
      ),
      throwsStateError,
    );
    expect(client.inits, isEmpty);
  });

  test('insecure verification URLs are rejected', () async {
    mas.deviceResponse = {
      ...mas.deviceResponse,
      'verification_uri': 'http://id.example/link',
    };
    var granted = false;
    await expectLater(
      service.deviceAuthorizationLogin(
        _hs,
        delay: fastWait,
        onGrant: (_) async => granted = true,
      ),
      throwsFormatException,
    );
    expect(granted, isFalse);
  });

  test('an existing session must sign out first', () async {
    client
      ..currentUser = '@sam:matrix.example'
      ..currentDevice = 'OLD';
    client.homeserver = Uri.parse(_hs);
    await expectLater(
      service.deviceAuthorizationLogin(_hs, onGrant: (_) async {}),
      throwsA(anything),
    );
    expect(mas.requests.where((r) => r.url.path == '/oauth2/device'), isEmpty);
  });

  group('MatrixBackend hold', () {
    test(
      'keeps the sign-in UI until the secrets step finishes',
      () async {
        mas.deviceResponse = {...mas.deviceResponse, 'interval': 1};
        final backend = MatrixBackend.withClient(client, localStorage: storage);
        addTearDown(backend.dispose);
        expect(backend.connection, SessionStatus.signedOut);
        final inAfterCommit = Completer<void>();
        final release = Completer<void>();
        final login = backend.loginWithDeviceAuthorization(
          _hs,
          onGrant: (_) async {},
          afterCommit: () async {
            inAfterCommit.complete();
            await release.future;
          },
        );
        // The backend polls with real waits: keep the interval at 1 s.
        mas.tokenReplies = [
          {'access_token': 'mat_access', 'token_type': 'Bearer'},
        ];
        await inAfterCommit.future.timeout(const Duration(seconds: 20));
        expect(client.isLogged(), isTrue);
        expect(backend.connection, SessionStatus.signedOut);
        expect(backend.deviceAuthorizationLoginBusy, isTrue);
        // Nothing else may sign in or out meanwhile.
        expect(() => backend.discoverProvider(_hs), throwsStateError);
        await expectLater(backend.logout(), throwsStateError);
        release.complete();
        await login;
        expect(backend.connection, SessionStatus.ready);
        expect(backend.deviceAuthorizationLoginBusy, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('releases the UI when sign-in fails before commit', () async {
      final backend = MatrixBackend.withClient(client, localStorage: storage);
      addTearDown(backend.dispose);
      mas.metadata = _metadata()..remove('device_authorization_endpoint');
      await expectLater(
        backend.loginWithDeviceAuthorization(
          _hs,
          onGrant: (_) async {},
          afterCommit: () async {},
        ),
        throwsA(isA<DeviceAuthorizationException>()),
      );
      expect(backend.connection, SessionStatus.signedOut);
      expect(backend.deviceAuthorizationLoginBusy, isFalse);
    });
  });
}
