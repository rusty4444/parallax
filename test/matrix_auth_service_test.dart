import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption.dart' as crypto;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/login_screen.dart';
import 'package:parallax/matrix_auth_service.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/secure_store.dart';

const _server = 'https://matrix.example';
const _callback = 'net.samrusselltech.parallax:/auth';
final _discovery = ProviderDiscovery(
  homeserver: Uri(scheme: 'https', host: 'matrix.example'),
  password: true,
  sso: true,
  oidc: true,
);

Map<String, Object?> _metadata({String token = 'https://id.example/token'}) => {
  'issuer': 'https://id.example',
  'authorization_endpoint': 'https://id.example/authorize',
  'token_endpoint': token,
  'registration_endpoint': 'https://id.example/register',
  'revocation_endpoint': 'https://id.example/revoke',
  'code_challenge_methods_supported': ['S256'],
  'grant_types_supported': ['authorization_code', 'refresh_token'],
  'response_types_supported': ['code'],
  'response_modes_supported': ['query', 'fragment'],
};

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

void main() {
  late _Database database;
  late _Client client;
  late _Store storage;
  late bool owner;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;
  late MatrixAuthService service;
  String? oidcDevice;

  setUp(() {
    database = _Database();
    storage = _Store();
    owner = true;
    requests = [];
    oidcDevice = null;
    respond = (r) async {
      if (r.url.path == '/.well-known/matrix/client') return _json({}, 404);
      if (r.url.path.endsWith('/versions')) {
        return _json({
          'versions': ['v1.15'],
        });
      }
      if (r.url.path.endsWith('/auth_metadata')) return _json(_metadata());
      if (r.method == 'GET' && r.url.path.endsWith('/login')) {
        return _json({
          'flows': [
            {'type': 'm.login.password'},
            {'type': 'm.login.sso'},
          ],
        });
      }
      if (r.url.path == '/register') {
        return _json({
          ...jsonDecode(r.body) as Map<String, dynamic>,
          'client_id': 'native-client',
        }, 201);
      }
      if (r.url.path.endsWith('/whoami')) {
        return _json({
          'user_id': '@sam:matrix.example',
          'device_id': oidcDevice ?? 'DEVICE',
        });
      }
      return _json({
        'access_token': 'new-token',
        'token_type': 'Bearer',
        'user_id': '@sam:matrix.example',
        'device_id': 'DEVICE',
        'expires_in': 3600,
        'expires_in_ms': 3600000,
      });
    };
    client = _Client(
      database,
      MockClient((r) async {
        requests.add(r);
        expect(r.followRedirects, isFalse);
        return respond(r);
      }),
    );
    service = MatrixAuthService(
      client,
      ownerCurrent: () => owner,
      storage: storage,
      authenticate: (url, scheme) async {
        expect(scheme, 'net.samrusselltech.parallax');
        final uri = Uri.parse(url);
        final redirect = uri.queryParameters['redirectUrl'];
        if (redirect != null) {
          return Uri.parse(redirect)
              .replace(
                queryParameters: {
                  ...Uri.parse(redirect).queryParameters,
                  'loginToken': 'single-use',
                },
              )
              .toString();
        }
        oidcDevice = uri.queryParameters['scope']!
            .split(' ')
            .last
            .split(':')
            .last;
        return Uri.parse(_callback)
            .replace(
              queryParameters: {
                'state': uri.queryParameters['state']!,
                'code': 'authorization-code',
              },
            )
            .toString();
      },
    );
  });

  tearDown(() => service.dispose());

  test(
    'fresh password login uses validated endpoint and shared commit lease, never SDK login',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      client.beforeInit = () => entered.complete();
      client.initBarrier = release.future;
      final backend = MatrixBackend.withClient(client, localStorage: storage);
      addTearDown(backend.dispose);
      final signingIn = service.passwordLogin(
        _discovery,
        'sam',
        'test-password',
      );
      await entered.future;
      expect(MatrixAuthService.isApplyingSession(client), isTrue);
      await expectLater(backend.logout(), throwsStateError);
      release.complete();
      await signingIn;
      expect(client.loginCalls, 0);
      expect(client.initCalls, 1);
      expect(
        requests.single.url.toString(),
        '$_server/_matrix/client/v3/login',
      );
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['refresh_token'], isTrue);
      expect(body['password'], 'test-password');
    },
  );

  test(
    'backend password discovery rejects HTTP delegation before versions or credentials',
    () async {
      respond = (_) async => _json({
        'm.homeserver': {'base_url': 'http://unsafe.example'},
      });
      final backend = MatrixBackend.withClient(client, localStorage: storage);
      addTearDown(backend.dispose);
      await expectLater(
        backend.login(
          homeserver: _server,
          username: 'sam',
          password: 'test-password',
        ),
        throwsFormatException,
      );
      expect(requests, hasLength(1));
      expect(requests.single.url.scheme, 'https');
      expect(requests.single.method, 'GET');
      expect(client.loginCalls, 0);
      expect(client.initCalls, 0);
    },
  );

  test(
    'fresh password callback after owner retirement cannot initialize a session',
    () async {
      respond = (_) async {
        owner = false;
        return _json({
          'access_token': 'test',
          'user_id': '@sam:matrix.example',
          'device_id': 'DEVICE',
        });
      };
      await expectLater(
        service.passwordLogin(_discovery, 'sam', 'test-password'),
        throwsStateError,
      );
      expect(client.initCalls, 0);
      expect(database.writes, 0);
    },
  );

  test(
    'fresh password login cannot replace an existing account device',
    () async {
      client.seed();
      await expectLater(
        service.passwordLogin(_discovery, 'sam', 'test-password'),
        throwsStateError,
      );
      expect(requests, isEmpty);
      expect(database.clears, 0);
    },
  );

  test(
    'provider parsing accepts MXIDs, IPv6, authority ports and URL paths',
    () {
      for (final entry in {
        '@sam:matrix.example:8448': 'https://matrix.example:8448',
        'matrix.example:8448': 'https://matrix.example:8448',
        '@sam:[2001:db8::1]:8448': 'https://[2001:db8::1]:8448',
        'https://matrix.example/prefix': 'https://matrix.example/prefix',
      }.entries) {
        expect(
          MatrixAuthService.providerUri(entry.key).toString(),
          entry.value,
        );
      }
    },
  );

  test('invalid providers fail before making requests', () async {
    for (final value in [
      'http://matrix.example',
      'https://user@matrix.example',
      'https://@matrix.example',
      'https://matrix.example?',
      'https://matrix.example#',
      '@:matrix.example',
      '@sam:bad/host',
      'matrix.example/path',
      'https://matrix.example:0',
      'https://matrix.example:65536',
      'sam@matrix.example',
    ]) {
      await expectLater(
        service.discover(value),
        throwsFormatException,
        reason: value,
      );
    }
    expect(requests, isEmpty);
  });

  test(
    'discovery returns advertised methods without mutating active client',
    () async {
      final result = await service.discover('@sam:matrix.example');
      expect(result.homeserver.toString(), _server);
      expect(result.password, isTrue);
      expect(result.sso, isTrue);
      expect(result.oidc, isTrue);
      expect(client.homeserver, isNull);
    },
  );

  test(
    'effective HTTP homeserver rejected before login or version request',
    () async {
      respond = (_) async => _json({
        'm.homeserver': {'base_url': 'http://unsafe.example'},
      });
      await expectLater(
        service.discover('matrix.example'),
        throwsFormatException,
      );
      expect(requests, hasLength(1));
    },
  );

  test(
    'SSO carries a nonce, requests refresh tokens and initializes SDK',
    () async {
      await service.browserLogin(_discovery, oidc: false);
      final login = requests.singleWhere((r) => r.method == 'POST');
      final body = jsonDecode(login.body) as Map<String, dynamic>;
      expect(body['type'], 'm.login.token');
      expect(body['token'], 'single-use');
      expect(body['refresh_token'], isTrue);
      expect(client.initCalls, 1);
      expect(client.accessToken, 'new-token');
    },
  );

  for (final bad in [
    'net.samrusselltech.parallax:/wrong?loginToken=stolen',
    'net.samrusselltech.parallax:/auth/path?loginToken=stolen',
    'net.samrusselltech.parallax:/auth?loginToken=stolen',
    'net.samrusselltech.parallax:/auth?state=wrong&loginToken=stolen',
  ]) {
    test('SSO rejects callback mismatch: $bad', () async {
      final auth = MatrixAuthService(
        client,
        ownerCurrent: () => owner,
        storage: storage,
        authenticate: (_, _) async => bad,
      );
      addTearDown(auth.dispose);
      await expectLater(
        auth.browserLogin(_discovery, oidc: false),
        throwsStateError,
      );
      expect(requests, isEmpty);
      expect(client.initCalls, 0);
    });
  }

  test(
    'OIDC registers native public client and exchanges PKCE/state',
    () async {
      await service.browserLogin(_discovery, oidc: true);
      final registration = requests.singleWhere(
        (r) => r.url.path == '/register',
      );
      final registrationBody = jsonDecode(registration.body) as Map;
      expect(registrationBody['redirect_uris'], [_callback]);
      expect(registrationBody['token_endpoint_auth_method'], 'none');
      expect(registrationBody['application_type'], 'native');
      final exchange = requests.singleWhere((r) => r.url.path == '/token');
      final body = Uri.splitQueryString(exchange.body);
      expect(body['grant_type'], 'authorization_code');
      expect(body['redirect_uri'], _callback);
      expect(body['code_verifier']!.length, greaterThanOrEqualTo(43));
      expect(client.lastOidcId, 'native-client');
      expect(client.initCalls, 1);
    },
  );

  test('OIDC PKCE challenge matches verifier', () async {
    String? challenge;
    final auth = MatrixAuthService(
      client,
      ownerCurrent: () => owner,
      storage: storage,
      authenticate: (url, _) async {
        final uri = Uri.parse(url);
        challenge = uri.queryParameters['code_challenge'];
        oidcDevice = uri.queryParameters['scope']!
            .split(' ')
            .last
            .split(':')
            .last;
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        return '$_callback?code=code&state=${uri.queryParameters['state']}';
      },
    );
    addTearDown(auth.dispose);
    await auth.browserLogin(_discovery, oidc: true);
    final exchange = requests.singleWhere((r) => r.url.path == '/token');
    final verifier = Uri.splitQueryString(exchange.body)['code_verifier']!;
    expect(
      challenge,
      base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', ''),
    );
  });

  test('OIDC rejects mismatched state before token exchange', () async {
    final auth = MatrixAuthService(
      client,
      ownerCurrent: () => owner,
      storage: storage,
      authenticate: (_, _) async => '$_callback?code=code&state=wrong',
    );
    addTearDown(auth.dispose);
    await expectLater(
      auth.browserLogin(_discovery, oidc: true),
      throwsStateError,
    );
    expect(requests.where((r) => r.url.path == '/token'), isEmpty);
  });

  test(
    'OIDC rejects insecure token metadata before sending any credential',
    () async {
      respond = (_) async => _json(_metadata(token: 'http://id.example/token'));
      await expectLater(
        service.browserLogin(_discovery, oidc: true),
        throwsFormatException,
      );
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test(
    'stale browser result cannot exchange token or initialize SDK',
    () async {
      final auth = MatrixAuthService(
        client,
        ownerCurrent: () => owner,
        storage: storage,
        authenticate: (url, _) async {
          owner = false;
          final redirect = Uri.parse(
            Uri.parse(url).queryParameters['redirectUrl']!,
          );
          return redirect
              .replace(
                queryParameters: {
                  ...redirect.queryParameters,
                  'loginToken': 'stale',
                },
              )
              .toString();
        },
      );
      addTearDown(auth.dispose);
      await expectLater(
        auth.browserLogin(_discovery, oidc: false),
        throwsStateError,
      );
      expect(requests, isEmpty);
      expect(client.initCalls, 0);
    },
  );

  test(
    'refresh omission retains old refresh token and device/crypto',
    () async {
      client.seed();
      await service.refresh();
      expect(database.account!['refresh_token'], 'old-refresh');
      expect(database.account!['device_id'], 'DEVICE');
      expect(database.account!['olm_account'], 'crypto-pickle');
      expect(client.accessToken, 'new-token');
      expect(client.loginCalls, 0);
    },
  );

  test('OIDC refresh omission retains old refresh token', () async {
    client.seed(oidc: true);
    await service.refresh();
    expect(database.account!['refresh_token'], 'old-refresh');
    expect(database.account!['oidc_client_id'], 'native-client');
    expect(requests.last.url.toString(), 'https://id.example/token');
  });

  test(
    'stale refresh after logout cannot initialize or store credentials',
    () async {
      client.seed();
      final started = Completer<void>();
      final result = Completer<http.Response>();
      respond = (_) {
        started.complete();
        return result.future;
      };
      final refresh = service.refresh();
      final expectation = expectLater(refresh, throwsStateError);
      await started.future;
      owner = false;
      client.signOut();
      result.complete(_json({'access_token': 'stale'}));
      await expectation;
      expect(client.initCalls, 0);
      expect(database.writes, 0);
      expect(client.accessToken, isNull);
    },
  );

  test(
    'account/device replacement during refresh is rejected even if owner true',
    () async {
      client.seed();
      respond = (_) async {
        client.currentDevice = 'REPLACEMENT';
        return _json({'access_token': 'stale'});
      };
      await expectLater(service.refresh(), throwsStateError);
      expect(database.writes, 0);
      expect(client.initCalls, 0);
    },
  );

  test(
    'metadata 503 is non-destructive and never escapes as MatrixException',
    () async {
      client.seed(oidc: true);
      respond = (_) async =>
          _json({'errcode': 'M_UNKNOWN', 'error': 'busy'}, 503);
      await expectLater(
        service.refresh(),
        throwsA(
          allOf(
            isA<MatrixAuthException>(),
            isNot(isA<matrix.MatrixException>()),
          ),
        ),
      );
      expect(database.writes, 0);
      expect(client.accessToken, 'old-token');
    },
  );

  test('token 503 is non-destructive for legacy and OIDC refresh', () async {
    for (final oidc in [false, true]) {
      client.seed(oidc: oidc);
      respond = (r) async => r.url.path.endsWith('/auth_metadata')
          ? _json(_metadata())
          : _json({'errcode': 'M_UNKNOWN', 'error': 'busy'}, 503);
      await expectLater(service.refresh(), throwsA(isA<MatrixAuthException>()));
      expect(database.writes, 0);
      expect(client.accessToken, 'old-token');
    }
  });

  test(
    'soft logout password reauthentication reuses device, never Client.login',
    () async {
      client.seed();
      await service.reauthenticatePassword('@sam:matrix.example', 'password');
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['device_id'], 'DEVICE');
      expect(body['identifier'], {
        'type': 'm.id.user',
        'user': '@sam:matrix.example',
      });
      expect(database.account!['olm_account'], 'crypto-pickle');
      expect(client.loginCalls, 0);
    },
  );

  test(
    'password reauthentication rejects different returned account or device',
    () async {
      client.seed();
      respond = (_) async => _json({
        'access_token': 'wrong',
        'user_id': '@other:matrix.example',
        'device_id': 'DEVICE',
      });
      await expectLater(
        service.reauthenticatePassword('@sam:matrix.example', 'password'),
        throwsStateError,
      );
      expect(client.initCalls, 0);
      expect(database.writes, 0);
    },
  );

  test('missing crypto cannot erase a retained device pickle', () async {
    client.seed();
    client.cryptoAvailable = false;
    await expectLater(service.refresh(), throwsA(isA<MatrixAuthException>()));
    expect(requests, isEmpty);
    expect(database.writes, 0);
    expect(database.account!['olm_account'], 'crypto-pickle');
  });

  test(
    'missing refresh token requests reauthentication without clearing data',
    () async {
      client.seed();
      database.account!.remove('refresh_token');
      await expectLater(
        service.refresh(),
        throwsA(isA<ReauthenticationRequired>()),
      );
      expect(client.accessToken, 'old-token');
      expect(requests, isEmpty);
      expect(database.writes, 0);
    },
  );

  test(
    'soft_logout token rejection is distinguishable and non-destructive',
    () async {
      client.seed();
      respond = (_) async =>
          _json({'errcode': 'M_UNKNOWN_TOKEN', 'soft_logout': true}, 401);
      await expectLater(
        service.refresh(),
        throwsA(isA<ReauthenticationRequired>()),
      );
      expect(client.accessToken, 'old-token');
      expect(database.writes, 0);
    },
  );

  test(
    'OIDC invalid_grant keeps the session for interactive reauthentication',
    () async {
      client.seed(oidc: true);
      respond = (r) async => r.url.path.endsWith('/auth_metadata')
          ? _json(_metadata())
          : _json({'error': 'invalid_grant'}, 400);
      await expectLater(
        service.refresh(),
        throwsA(isA<ReauthenticationRequired>()),
      );
      expect(client.deviceID, 'DEVICE');
      expect(database.account!['olm_account'], 'crypto-pickle');
    },
  );

  test('concurrent refresh calls share the same token rotation', () async {
    client.seed();
    final started = Completer<void>();
    final result = Completer<http.Response>();
    respond = (_) {
      started.complete();
      return result.future;
    };
    final first = service.refresh();
    final second = service.refresh();
    await started.future;
    result.complete(
      _json({'access_token': 'rotated', 'refresh_token': 'rotated-refresh'}),
    );
    await Future.wait([first, second]);
    expect(requests, hasLength(1));
    expect(database.writes, 1);
    expect(database.account!['refresh_token'], 'rotated-refresh');
  });

  test(
    'operation-scoped services share one refresh and commit lease per client',
    () async {
      client.seed();
      final entered = Completer<void>();
      final release = Completer<void>();
      client.beforeInit = () => entered.complete();
      client.initBarrier = release.future;
      final other = MatrixAuthService(
        client,
        ownerCurrent: () => owner,
        storage: storage,
      );
      addTearDown(other.dispose);
      final first = service.refresh();
      final second = other.refresh();
      await entered.future;
      expect(MatrixAuthService.isApplyingSession(client), isTrue);
      expect(other.applyingSession, isTrue);
      final backend = MatrixBackend.withClient(client, localStorage: storage);
      addTearDown(backend.dispose);
      await expectLater(backend.logout(), throwsStateError);
      await expectLater(
        backend.login(homeserver: _server, username: 'sam', password: 'test'),
        throwsStateError,
      );
      expect(database.clears, 0);
      release.complete();
      await Future.wait([first, second]);
      expect(MatrixAuthService.isApplyingSession(client), isFalse);
      expect(client.initCalls, 1);
      expect(requests, hasLength(1));
    },
  );

  test('stale metadata result cannot send a refresh token', () async {
    client.seed(oidc: true);
    respond = (_) async {
      owner = false;
      return _json(_metadata());
    };
    await expectLater(service.refresh(), throwsStateError);
    expect(requests, hasLength(1));
    expect(database.writes, 0);
  });

  test('stale database read cannot send a refresh token', () async {
    client.seed();
    database.afterRead = () {
      client.currentDevice = 'REPLACEMENT';
    };
    await expectLater(service.refresh(), throwsStateError);
    expect(requests, isEmpty);
    expect(database.writes, 0);
  });

  test('duplicate callback state is rejected before exchange', () async {
    final auth = MatrixAuthService(
      client,
      ownerCurrent: () => owner,
      storage: storage,
      authenticate: (url, _) async {
        final redirect = Uri.parse(
          Uri.parse(url).queryParameters['redirectUrl']!,
        );
        return '$redirect&state=duplicate&loginToken=token';
      },
    );
    addTearDown(auth.dispose);
    await expectLater(
      auth.browserLogin(_discovery, oidc: false),
      throwsStateError,
    );
    expect(requests, isEmpty);
  });

  test('browser reauthentication retains the existing SSO device', () async {
    client.seed();
    await service.browserLogin(_discovery, oidc: false);
    final body = jsonDecode(requests.single.body) as Map;
    expect(body['device_id'], 'DEVICE');
    expect(client.deviceID, 'DEVICE');
    expect(database.account!['olm_account'], 'crypto-pickle');
    expect(client.loginCalls, 0);
  });

  test('OIDC reauthentication retains device scope and crypto', () async {
    client.seed(oidc: true);
    await service.browserLogin(_discovery, oidc: true);
    expect(oidcDevice, 'DEVICE');
    expect(client.deviceID, 'DEVICE');
    expect(database.account!['olm_account'], 'crypto-pickle');
    expect(requests.where((r) => r.url.path == '/register'), isEmpty);
  });

  test(
    'real SDK 14.1 soft-init retains crypto object, device and token expiry',
    () async {
      client.seed();
      final sdk = _SdkClient(database, MockClient((r) async => respond(r)));
      sdk.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      await sdk.init(waitForFirstSync: false);
      final crypto = sdk.encryption;
      final auth = MatrixAuthService(
        sdk,
        ownerCurrent: () => true,
        storage: storage,
      );
      addTearDown(auth.dispose);
      sdk.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      await auth.refresh();
      expect(sdk.accessToken, 'new-token');
      expect(sdk.userID, '@sam:matrix.example');
      expect(sdk.deviceID, 'DEVICE');
      expect(sdk.encryption, same(crypto));
      expect(database.account!['olm_account'], 'crypto-pickle');
      expect(sdk.accessTokenExpiresAt, isNotNull);
      expect(sdk.onLoginStateChanged.value, matrix.LoginState.loggedIn);
    },
  );

  test(
    'real SDK soft-logout handler does not clear a metadata 503 session',
    () async {
      client.seed(oidc: true);
      database.account!['token_expires_at'] = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch
          .toString();
      final sdk = _SdkClient(
        database,
        MockClient(
          (_) async => _json({'errcode': 'M_UNKNOWN', 'error': 'busy'}, 503),
        ),
      );
      sdk.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      await sdk.init(waitForFirstSync: false);
      final auth = MatrixAuthService(
        sdk,
        ownerCurrent: () => true,
        storage: storage,
      );
      addTearDown(auth.dispose);
      sdk.onSoftLogout = (_) => auth.refresh();
      await sdk.ensureNotSoftLoggedOut();
      expect(database.clears, 0);
      expect(database.account!['refresh_token'], 'old-refresh');
      expect(database.account!['olm_account'], 'crypto-pickle');
      expect(sdk.accessToken, 'old-token');
      expect(sdk.onLoginStateChanged.value, matrix.LoginState.softLoggedOut);
    },
  );

  test(
    'transport-thrown MatrixException is translated out of destructive SDK type',
    () async {
      client.seed(oidc: true);
      respond = (_) async => throw matrix.MatrixException.fromJson({
        'errcode': 'M_UNKNOWN',
        'error': 'unavailable',
      });
      await expectLater(service.refresh(), throwsA(isA<MatrixAuthException>()));
      expect(database.writes, 0);
    },
  );

  test(
    'real SDK refresh-less password reauthentication persists without crypto reset',
    () async {
      client.seed();
      database.account!.remove('refresh_token');
      final sdk = _SdkClient(database, MockClient((r) async => respond(r)));
      sdk.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      await sdk.init(waitForFirstSync: false);
      final auth = MatrixAuthService(
        sdk,
        ownerCurrent: () => true,
        storage: storage,
      );
      addTearDown(auth.dispose);
      await auth.reauthenticatePassword('sam', 'password');
      expect(sdk.deviceID, 'DEVICE');
      expect(sdk.accessToken, 'new-token');
      expect(database.account!['token'], 'new-token');
      expect(database.account!['olm_account'], 'crypto-pickle');
      expect(database.clears, 0);
    },
  );

  for (final endpoint in [
    'http://id.example/token',
    'https://user@id.example/token',
    'https://@id.example/token',
    'https://id.example/token?',
    'https://id.example/token#',
  ]) {
    test('refresh rejects unsafe token endpoint $endpoint', () async {
      client.seed(oidc: true);
      respond = (_) async => _json(_metadata(token: endpoint));
      await expectLater(service.refresh(), throwsFormatException);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(database.writes, 0);
    });
  }

  testWidgets('feature UI advertises only discovered browser login buttons', (
    tester,
  ) async {
    final backend = _FeatureBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    expect(find.text('Continue with SSO'), findsNothing);
    await tester.ensureVisible(find.text('Find sign-in options'));
    await tester.tap(find.text('Find sign-in options'));
    await tester.pumpAndSettle();
    expect(find.text('Continue with SSO'), findsOneWidget);
    expect(find.text('Continue with OpenID Connect'), findsNothing);
    await tester.ensureVisible(find.text('Continue with SSO'));
    await tester.tap(find.text('Continue with SSO'));
    await tester.pumpAndSettle();
    expect(backend.browserLogins, [false]);
  });
}

class _Store implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Database implements matrix.DatabaseApi {
  Map<String, dynamic>? account;
  void Function()? afterRead;
  int writes = 0;
  int clears = 0;
  @override
  Future<void> clear() async {
    clears++;
    account = null;
  }

  @override
  Future<Map<String, dynamic>?> getClient(String name) async {
    final result = account == null ? null : Map<String, dynamic>.of(account!);
    afterRead?.call();
    return result;
  }

  @override
  Future<void> storeClient({
    required String homeserverUrl,
    required String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    required String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
    String? oidcClientId,
  }) async {
    writes++;
    account = {
      'homeserver_url': homeserverUrl,
      'token': token,
      'refresh_token': refreshToken,
      'user_id': userId,
      'device_id': deviceId,
      'device_name': deviceName,
      'prev_batch': prevBatch,
      'olm_account': olmAccount,
      'oidc_client_id': oidcClientId,
      'token_expires_at': tokenExpiresAt?.millisecondsSinceEpoch.toString(),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SdkClient extends matrix.Client {
  _SdkClient(_Database db, http.Client httpClient)
    : super('test', database: db, httpClient: httpClient);
  final _crypto = _Crypto();
  @override
  crypto.Encryption get encryption => _crypto;
}

class _Crypto implements crypto.Encryption {
  @override
  String get pickledOlmAccount => 'crypto-pickle';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends matrix.Client {
  _Client(_Database db, http.Client httpClient)
    : super('test', database: db, httpClient: httpClient);
  String? currentUser;
  String? currentDevice;
  int initCalls = 0;
  int loginCalls = 0;
  String? lastOidcId;
  bool cryptoAvailable = true;
  final _crypto = _Crypto();
  void Function()? beforeInit;
  Future<void>? initBarrier;
  @override
  crypto.Encryption? get encryption =>
      cryptoAvailable && currentUser != null ? _crypto : null;
  @override
  String? get userID => currentUser;
  @override
  String? get deviceID => currentDevice;
  void seed({bool oidc = false}) {
    homeserver = Uri.parse(_server);
    accessToken = 'old-token';
    currentUser = '@sam:matrix.example';
    currentDevice = 'DEVICE';
    onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
    (database as _Database).account = {
      'homeserver_url': _server,
      'token': 'old-token',
      'user_id': currentUser,
      'device_id': currentDevice,
      'refresh_token': 'old-refresh',
      'device_name': 'phone',
      'prev_batch': 'batch',
      'olm_account': 'crypto-pickle',
      if (oidc) 'oidc_client_id': 'native-client',
    };
  }

  void signOut() {
    accessToken = null;
    currentUser = null;
    currentDevice = null;
    (database as _Database).account = null;
    onLoginStateChanged.add(matrix.LoginState.loggedOut);
  }

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
    initCalls++;
    beforeInit?.call();
    await initBarrier;
    accessToken = newToken;
    homeserver = newHomeserver;
    currentUser = newUserID;
    currentDevice = newDeviceID;
    lastOidcId = newOidcClientId;
    await database.storeClient(
      homeserverUrl: newHomeserver.toString(),
      token: newToken!,
      tokenExpiresAt: newTokenExpiresAt,
      refreshToken: newRefreshToken,
      userId: newUserID!,
      deviceId: newDeviceID,
      deviceName: newDeviceName,
      prevBatch: 'batch',
      olmAccount: newOlmAccount,
      oidcClientId: newOidcClientId,
    );
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  @override
  Future<matrix.LoginResponse> login(
    String type, {
    matrix.AuthenticationIdentifier? identifier,
    String? password,
    String? token,
    String? deviceId,
    String? initialDeviceDisplayName,
    bool? refreshToken,
    String? user,
    String? medium,
    String? address,
    void Function(matrix.InitState)? onInitStateChanged,
  }) async {
    loginCalls++;
    throw StateError('Client.login must not be used for reauthentication');
  }
}

class _FeatureBackend extends ChatBackend implements MessagingFeatures {
  final browserLogins = <bool>[];
  @override
  Future<ProviderDiscovery> discoverProvider(String input) async =>
      ProviderDiscovery(
        homeserver: Uri.parse(_server),
        password: true,
        sso: true,
        oidc: false,
      );
  @override
  Future<void> loginWithBrowser(
    ProviderDiscovery discovery, {
    required bool oidc,
  }) async {
    browserLogins.add(oidc);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
