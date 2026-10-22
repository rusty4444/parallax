import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/matrix_auth_service.dart';
import 'package:matrixpress/matrix_backend.dart';
import 'package:matrixpress/push_notifications.dart';
import 'package:matrixpress/secure_store.dart';
import 'package:matrixpress/send_cancellation.dart';

void main() {
  test(
    'outboxes are device-scoped while draft account identity is stable',
    () async {
      final store = _Store();
      final firstClient = _Client('FIRST');
      final first = MatrixBackend.withClient(firstClient, localStorage: store);
      await first.queueMessage('!room:matrix.example', 'first');
      final oldId = first.pendingSends.single.id;
      final draftAccount = first.accountKey;
      first.dispose();
      final second = MatrixBackend.withClient(
        _Client('SECOND'),
        localStorage: store,
      );
      addTearDown(second.dispose);
      await second.queueMessage('!room:matrix.example', 'second');
      expect(second.accountKey, draftAccount);
      expect(second.pendingSends, hasLength(1));
      expect(second.pendingSends.single.id, isNot(oldId));
      final restored = MatrixBackend.withClient(
        _Client('FIRST'),
        localStorage: store,
      );
      addTearDown(restored.dispose);
      await restored.queueMessage('!room:matrix.example', 'third');
      expect(restored.pendingSends.map((s) => s.id), contains(oldId));
      expect(restored.pendingSends, hasLength(2));
    },
  );

  test(
    'device replacement during a held restore cannot retarget a draft',
    () async {
      final store = _Store()..readGate = Completer<void>();
      final client = _Client('FIRST');
      final backend = MatrixBackend.withClient(client, localStorage: store);
      addTearDown(backend.dispose);
      final queued = backend.queueMessage(
        '!room:matrix.example',
        'private draft',
      );
      final assertion = expectLater(queued, throwsA(isA<SendCancelled>()));
      await store.readStarted.future;
      client.currentDevice = 'REPLACEMENT';
      store.readGate!.complete();
      await assertion;
      expect(store.values, isEmpty);
      expect(backend.pendingSends, isEmpty);
    },
  );

  test(
    'failed restore can be retried without replacing unread outbox data',
    () async {
      final store = _Store()..failRead = true;
      final backend = MatrixBackend.withClient(
        _Client('DEVICE'),
        localStorage: store,
      );
      addTearDown(backend.dispose);
      await expectLater(
        backend.queueMessage('!room:matrix.example', 'saved'),
        throwsStateError,
      );
      expect(store.values, isEmpty);
      store.failRead = false;
      await backend.queueMessage('!room:matrix.example', 'saved');
      expect(backend.pendingSends, hasLength(1));
    },
  );

  test(
    'logout joins push cleanup and blocks queue/auth before clearing credentials',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final client = _Client('DEVICE');
      final backend = MatrixBackend.withClient(
        client,
        localStorage: _Store(),
        beforeLogout: () async {
          entered.complete();
          await release.future;
        },
      );
      addTearDown(backend.dispose);
      final leaving = backend.logout();
      await entered.future;
      expect(client.logoutCalls, 0);
      expect(client.userID, '@sam:matrix.example');
      expect(backend.pushSessionKey, isNull);
      await expectLater(
        backend.queueMessage('!room:matrix.example', 'too late'),
        throwsStateError,
      );
      expect(
        () => backend.discoverProvider('matrix.example'),
        throwsStateError,
      );
      await expectLater(backend.logout(), throwsStateError);
      release.complete();
      await leaving;
      expect(client.logoutCalls, 1);
      expect(backend.connection, SessionStatus.signedOut);
    },
  );

  test(
    'failed push cleanup preserves SDK credentials for explicit retry',
    () async {
      final client = _Client('DEVICE');
      var fail = true;
      final backend = MatrixBackend.withClient(
        client,
        localStorage: _Store(),
        beforeLogout: () async {
          if (fail) throw StateError('cleanup failed');
        },
      );
      addTearDown(backend.dispose);
      await expectLater(backend.logout(), throwsStateError);
      expect(client.logoutCalls, 0);
      expect(backend.connection, SessionStatus.ready);
      expect(backend.pushSessionKey, isNotNull);
      fail = false;
      await backend.logout();
      expect(client.logoutCalls, 1);
    },
  );

  test('password discovery cannot overlap logout or another login', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final client = _Client(
      'DEVICE',
      respond: (_) async {
        started.complete();
        await release.future;
        return http.Response('{}', 500);
      },
    )..signOut();
    final backend = MatrixBackend.withClient(client, localStorage: _Store());
    addTearDown(backend.dispose);
    final signingIn = backend.login(
      homeserver: 'https://matrix.example',
      username: 'sam',
      password: 'test',
    );
    final assertion = expectLater(
      signingIn,
      throwsA(isA<MatrixAuthException>()),
    );
    await started.future;
    await expectLater(backend.logout(), throwsStateError);
    await expectLater(
      backend.login(
        homeserver: 'https://matrix.example',
        username: 'other',
        password: 'test',
      ),
      throwsStateError,
    );
    expect(client.logoutCalls, 0);
    release.complete();
    await assertion;
  });

  test(
    'refresh reauthentication requirement preserves device and shows sign-in',
    () async {
      final client = _Client('DEVICE');
      client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      final backend = MatrixBackend.withClient(client, localStorage: _Store());
      addTearDown(backend.dispose);
      await expectLater(
        client.onSoftLogout!(client),
        throwsA(isA<ReauthenticationRequired>()),
      );
      expect(backend.connection, SessionStatus.signedOut);
      expect(client.currentDevice, 'DEVICE');
      expect(client.userID, '@sam:matrix.example');
      expect(client.logoutCalls, 0);
    },
  );

  test(
    'pusher writes are read back and old callbacks cannot borrow new credentials',
    () async {
      final client = _Client('DEVICE');
      final backend = MatrixBackend.withClient(client, localStorage: _Store());
      addTearDown(backend.dispose);
      final session = backend.createPushSession((_) async {})!;
      final registration = PushRegistration(
        configuration: PushConfiguration(
          gatewayUrl: Uri.parse('https://push.example/_matrix/push/v1/notify'),
          appId: 'net.example.app',
        ),
        userId: session.userId,
        deviceId: session.deviceId,
        token: 'test-push-token',
        registrationId: 'test-registration',
      );
      await session.registerPusher(registration);
      expect(client.append, isFalse);
      expect(client.pusherReads, 1);
      await session.removePusher(registration);
      expect(client.pushers, isEmpty);
      expect(client.pusherReads, 2);
      client.acceptPusher = false;
      await expectLater(session.registerPusher(registration), throwsStateError);
      client.currentDevice = 'NEW';
      final writes = client.pusherWrites;
      await expectLater(session.registerPusher(registration), throwsStateError);
      await expectLater(session.removePusher(registration), throwsStateError);
      expect(client.pusherWrites, writes);
    },
  );
}

class _Store implements SecureValueStore {
  final values = <String, String>{};
  final readStarted = Completer<void>();
  Completer<void>? readGate;
  bool failRead = false;
  @override
  Future<String?> read(String key) async {
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    if (failRead) throw StateError('secure storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<Map<String, dynamic>?> getClient(String name) async => {
    'homeserver_url': 'https://matrix.example',
    'token': 'test-token',
    'user_id': '@sam:matrix.example',
    'device_id': 'DEVICE',
  };
}

class _Client extends matrix.Client {
  _Client(
    this.currentDevice, {
    Future<http.Response> Function(http.Request)? respond,
  }) : super(
         'test',
         database: _Database(),
         httpClient: MockClient(
           respond ?? ((_) async => http.Response('{}', 500)),
         ),
       ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
  String? currentUser = '@sam:matrix.example';
  String? currentDevice;
  int logoutCalls = 0;
  int pusherReads = 0;
  int pusherWrites = 0;
  bool? append;
  bool acceptPusher = true;
  final pushers = <matrix.Pusher>[];
  @override
  String? get userID => currentUser;
  @override
  String? get deviceID => currentDevice;
  void signOut() {
    accessToken = null;
    currentUser = null;
    currentDevice = null;
    onLoginStateChanged.add(matrix.LoginState.loggedOut);
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    signOut();
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
  @override
  Future<List<matrix.Pusher>?> getPushers() async {
    pusherReads++;
    return List.of(pushers);
  }

  @override
  Future<void> postPusher(matrix.Pusher pusher, {bool? append}) async {
    this.append = append;
    pusherWrites++;
    if (acceptPusher) pushers.add(pusher);
  }

  @override
  Future<void> deletePusher(matrix.PusherId id) async => pushers.removeWhere(
    (p) => p.appId == id.appId && p.pushkey == id.pushkey,
  );
}
