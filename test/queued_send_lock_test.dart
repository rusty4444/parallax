import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/pending_failure.dart';
import 'package:parallax/secure_store.dart';

void main() {
  test('a queued message waits for a photo gallery upload instead of '
      'failing as busy', () async {
    final client = _Client();
    final backend = MatrixBackend.withClient(
      client,
      localStorage: _Store(),
      undoSendDelay: () async => Duration.zero,
    );
    addTearDown(backend.dispose);

    // "Send a photo gallery" holds the send lock for its whole upload.
    final photo = _HeldFile();
    final gallery = backend.sendImages(client.room.id, [photo]);
    await photo.started.future;
    expect(backend.sending, isTrue);

    // A message falls due meanwhile (undo-send hold over, or sent with Off).
    await backend.queueMessage(client.room.id, 'Hello Quinn');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final waiting = backend.pendingSends.single;
    expect(
      waiting.state,
      isNot(DeliveryState.failed),
      reason: 'failed with: ${waiting.error}',
    );
    expect(client.room.textSends, 0);

    photo.release.complete();
    await gallery;
    for (var i = 0; i < 50 && backend.pendingSends.isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(backend.pendingSends, isEmpty);
    expect(client.room.textSends, 1);
    expect(client.room.fileSends, 1);
  });

  test('still fails, with a reason, if the lock is never released', () async {
    final previous = MatrixBackend.queuedSendLockWait;
    MatrixBackend.queuedSendLockWait = const Duration(milliseconds: 300);
    addTearDown(() => MatrixBackend.queuedSendLockWait = previous);
    final client = _Client();
    final backend = MatrixBackend.withClient(
      client,
      localStorage: _Store(),
      undoSendDelay: () async => Duration.zero,
    );
    final photo = _HeldFile();
    final gallery = backend.sendImages(client.room.id, [photo]);
    await photo.started.future;

    await backend.queueMessage(client.room.id, 'Hello');
    for (var i = 0; i < 30; i++) {
      if (backend.pendingSends.single.state == DeliveryState.failed) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final failed = backend.pendingSends.single;
    expect(failed.state, DeliveryState.failed);
    expect(
      pendingFailureReason(failed.error),
      'another message was still sending',
    );
    photo.release.complete();
    await gallery;
    backend.dispose();
  });

  test('failure reasons are short and specific', () {
    expect(pendingFailureReason(null), 'unknown error');
    expect(
      pendingFailureReason('Bad state: Reply target is unavailable'),
      'the message you replied to isn’t available',
    );
    expect(
      pendingFailureReason(
        'Bad state: Recipient encryption keys changed or are stale',
      ),
      'couldn’t confirm who can read it (encryption)',
    );
    expect(
      pendingFailureReason('ClientException: Connection reset by peer'),
      'no connection to the server',
    );
    expect(
      pendingFailureReason('MatrixException: M_TOO_LARGE: Upload too big'),
      'too large for the server',
    );
    expect(
      pendingFailureReason('Bad state: Something new happened'),
      'Something new happened',
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
        'lock-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
  final room = _Room();
  @override
  String? get userID => '@sam:matrix.example';
  @override
  String? get deviceID => 'DEVICE';
  @override
  matrix.Room? getRoomById(String id) => room.id == id ? room : null;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Room extends Fake implements matrix.Room {
  int textSends = 0;
  int fileSends = 0;
  @override
  String get id => '!room:matrix.example';
  @override
  bool get encrypted => false;
  @override
  matrix.Membership get membership => matrix.Membership.join;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sendFileEvent) {
      fileSends++;
      return Future<String?>.value(r'$file');
    }
    if (invocation.memberName == #sendEvent) {
      textSends++;
      return Future<String?>.value(r'$text');
    }
    return super.noSuchMethod(invocation);
  }
}

class _HeldFile extends XFile {
  _HeldFile() : super('photo.jpg');
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> length() async => 1;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    if (!started.isCompleted) started.complete();
    await release.future;
    yield Uint8List.fromList([0xFF, 0xD8, 0xFF]);
  }
}
