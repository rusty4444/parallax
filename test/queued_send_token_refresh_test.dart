import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/pending_failure.dart';
import 'package:parallax/secure_store.dart';

// The SDK reports softLoggedOut while it renews an expiring access token
// (every few minutes with short-lived tokens, and right after the app comes
// back from the background). The account, device and keys are unchanged, so
// a message sent in that window must wait for the renewal, not fail.
void main() {
  MatrixBackend backendFor(_Client client) {
    final backend = MatrixBackend.withClient(
      client,
      localStorage: _Store(),
      undoSendDelay: () async => Duration.zero,
    );
    addTearDown(backend.dispose);
    return backend;
  }

  Future<void> settle(MatrixBackend backend, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a queued message waits for a token renewal instead of failing as an '
      'unavailable session', () async {
    final client = _Client();
    final backend = backendFor(client);
    client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);

    await backend.queueMessage(client.room.id, 'What am I looking at?');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final waiting = backend.pendingSends.single;
    expect(
      waiting.state,
      isNot(DeliveryState.failed),
      reason: 'failed with: ${waiting.error}',
    );
    expect(client.room.sends, isEmpty);

    client.onLoginStateChanged.add(matrix.LoginState.loggedIn);
    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    expect(client.room.sends, hasLength(1));
  });

  test('a message the server accepted while a renewal started is delivered '
      'once', () async {
    final client = _Client();
    final backend = backendFor(client);
    final held = client.room.hold = Completer<void>();

    await backend.queueMessage(client.room.id, 'Hello');
    await settle(backend, () => client.room.sends.isNotEmpty);
    expect(client.room.sends, hasLength(1));

    // The renewal begins before the server's answer is handled.
    client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
    client.room.hold = null;
    held.complete();
    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    expect(client.room.sends, hasLength(1));
  });

  test('a send refused during a renewal is retried with the same '
      'transaction ID', () async {
    final client = _Client();
    final backend = backendFor(client);
    client.room.refuseWhileRenewing = true;
    final held = client.room.hold = Completer<void>();

    await backend.queueMessage(client.room.id, 'Hello');
    await settle(backend, () => client.room.sends.isNotEmpty);
    expect(client.room.sends, hasLength(1));

    client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
    client.room.hold = null;
    held.complete();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final waiting = backend.pendingSends.single;
    expect(
      waiting.state,
      isNot(DeliveryState.failed),
      reason: 'failed with: ${waiting.error}',
    );

    client.onLoginStateChanged.add(matrix.LoginState.loggedIn);
    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    // Matrix deduplicates on the transaction ID, so the retry cannot post
    // the message twice.
    expect(client.room.sends, hasLength(2));
    expect(client.room.sends.toSet(), hasLength(1));
  });

  test('a token that expired in the background is renewed before the message '
      'goes out', () async {
    final client = _Client()..expired = true;
    final backend = backendFor(client);

    await backend.queueMessage(client.room.id, 'Hello');
    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    expect(client.renewals, 1);
    expect(client.room.sends, hasLength(1));
    expect(
      client.room.loginStatesAtSend,
      everyElement(matrix.LoginState.loggedIn),
    );
  });

  test('a renewal that keeps failing is tried again with growing pauses, '
      'then the message sends', () async {
    final client = _Client()
      ..expired = true
      ..failingRenewals = 3;
    final backend = backendFor(client);

    await backend.queueMessage(client.room.id, 'Hello');
    // Attempts at 0, 0.25 and 0.75 seconds; the fourth is due at 1.75.
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(client.renewals, 3);
    expect(backend.pendingSends.single.state, isNot(DeliveryState.failed));
    expect(client.room.sends, isEmpty);

    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    expect(client.renewals, 4);
    expect(client.room.sends, hasLength(1));
  });

  test('fails with a reason, and can be retried, if the account never '
      'reconnects', () async {
    final previous = MatrixBackend.tokenRefreshWait;
    MatrixBackend.tokenRefreshWait = const Duration(milliseconds: 300);
    addTearDown(() => MatrixBackend.tokenRefreshWait = previous);
    final client = _Client();
    final backend = backendFor(client);
    client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);

    await backend.queueMessage(client.room.id, 'Hello');
    await settle(
      backend,
      () => backend.pendingSends.single.state == DeliveryState.failed,
    );
    final failed = backend.pendingSends.single;
    expect(failed.state, DeliveryState.failed);
    expect(
      pendingFailureReason(failed.error),
      'still reconnecting to your account',
    );
    expect(client.room.sends, isEmpty);

    client.onLoginStateChanged.add(matrix.LoginState.loggedIn);
    await backend.retryPending(failed.id);
    await settle(backend, () => backend.pendingSends.isEmpty);
    expect(backend.pendingSends, isEmpty);
    expect(client.room.sends, [failed.id]);
  });

  test('a direct send (poll, location, reaction) also waits for the '
      'renewal', () async {
    final client = _Client();
    final backend = backendFor(client);
    client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);

    Object? error;
    String? sent;
    unawaited(
      backend
          .sendRoomEvent(client.room.id, 'm.room.message', {
            'msgtype': 'm.text',
            'body': 'Hello',
          })
          .then<void>((id) => sent = id, onError: (Object e) => error = e),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(error, isNull);
    expect(sent, isNull);

    client.onLoginStateChanged.add(matrix.LoginState.loggedIn);
    await settle(backend, () => sent != null || error != null);
    expect(error, isNull);
    expect(sent, r'$sent');
  });

  test('the old wording is explained if it is ever stored', () {
    expect(
      pendingFailureReason('Bad state: Send belongs to an unavailable session'),
      'the account was reconnecting',
    );
  });
}

class _Database extends Fake implements matrix.DatabaseApi {}

class _Store implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Client extends matrix.Client {
  _Client()
    : super(
        'refresh-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
    room = _Room(this);
  }
  late final _Room room;

  /// The access token ran out while the app was in the background; the SDK
  /// has not noticed yet (it still reports loggedIn).
  bool expired = false;
  int renewals = 0;

  /// Renewals that fail first (no network yet): the SDK keeps the error to
  /// itself and stays softLoggedOut.
  int failingRenewals = 0;

  @override
  DateTime? get accessTokenExpiresAt =>
      expired ? DateTime.now().subtract(const Duration(minutes: 10)) : null;

  @override
  String? get userID => '@sam:matrix.example';
  @override
  String? get deviceID => 'DEVICE';
  @override
  matrix.Room? getRoomById(String id) => room.id == id ? room : null;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}

  @override
  Future<void> ensureNotSoftLoggedOut([
    Duration expiresIn = const Duration(minutes: 1),
  ]) async {
    if (!expired) return;
    renewals++;
    onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
    if (failingRenewals > 0) {
      failingRenewals--;
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expired = false;
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
}

class _Room extends Fake implements matrix.Room {
  _Room(this._client);
  final _Client _client;

  /// Transaction ID of every send attempt, in order.
  final sends = <String?>[];
  final loginStatesAtSend = <matrix.LoginState?>[];
  Completer<void>? hold;

  /// Answer like the SDK does when the server rejects the old token: no
  /// event ID.
  bool refuseWhileRenewing = false;

  @override
  String get id => '!room:matrix.example';
  @override
  bool get encrypted => false;
  @override
  matrix.Membership get membership => matrix.Membership.join;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sendEvent) {
      sends.add(invocation.namedArguments[#txid] as String?);
      loginStatesAtSend.add(_client.onLoginStateChanged.value);
      final held = hold;
      String? answer() =>
          refuseWhileRenewing &&
              _client.onLoginStateChanged.value != matrix.LoginState.loggedIn
          ? null
          : r'$sent';
      return held == null
          ? Future<String?>.value(answer())
          : held.future.then<String?>((_) => answer());
    }
    return super.noSuchMethod(invocation);
  }
}
