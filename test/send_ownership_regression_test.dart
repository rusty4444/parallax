import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/matrix_backend.dart';
import 'package:matrixpress/matrix_send_guard.dart';
import 'package:matrixpress/secure_store.dart';

void main() {
  for (final images in [false, true]) {
    test(
      'legacy media cannot adopt replacement credentials (gallery: $images)',
      () async {
        final client = _Client();
        final backend = MatrixBackend.withClient(
          client,
          localStorage: _Store(),
        );
        addTearDown(backend.dispose);
        final file = _HeldFile();
        final sending = images
            ? backend.sendImages(client.room.id, [file])
            : backend.sendAttachment(client.room.id, file);
        final assertion = expectLater(sending, throwsStateError);
        await file.started.future;
        await backend.logout();
        client.currentUser = '@replacement:matrix.example';
        client.currentDevice = 'REPLACEMENT';
        client.accessToken = 'replacement-token';
        client.onLoginStateChanged.add(matrix.LoginState.loggedIn);
        file.release.complete();
        await assertion;
        expect(client.room.sends, 0);
      },
    );
  }

  test(
    'actual streamed bytes are bounded despite small declared file size',
    () async {
      final client = _Client();
      final backend = MatrixBackend.withClient(client, localStorage: _Store());
      addTearDown(backend.dispose);
      final file = _HeldFile(bytes: Uint8List(20 * 1024 * 1024 + 1));
      file.release.complete();
      await expectLater(
        backend.sendAttachment(client.room.id, file),
        throwsArgumentError,
      );
      expect(client.room.sends, 0);
    },
  );

  for (final upload in [false, true]) {
    test(
      'plaintext final HTTP boundary checks ownership (upload: $upload)',
      () async {
        var calls = 0;
        var current = true;
        final gate = Completer<void>();
        final started = Completer<void>();
        final guard = MatrixSendGuard(
          MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
          encryptionAvailable: () => false,
          isEncryptedRoom: (_) => false,
        );
        addTearDown(guard.close);
        final sending = MatrixSendGuard.owned(() => current, () async {
          started.complete();
          await gate.future;
          await guard.send(
            http.Request(
              'POST',
              Uri.parse(
                upload
                    ? 'https://matrix.example/_matrix/media/v3/upload'
                    : 'https://matrix.example/_matrix/client/v3/rooms/room/send/m.room.message/txn',
              ),
            ),
          );
        });
        final assertion = expectLater(sending, throwsStateError);
        await started.future;
        current = false;
        gate.complete();
        await assertion;
        expect(calls, 0);
      },
    );
  }
}

class _Database extends Fake implements matrix.DatabaseApi {}

class _Store implements SecureValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _Client extends matrix.Client {
  _Client()
    : super(
        'test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
  String? currentUser = '@sam:matrix.example';
  String? currentDevice = 'DEVICE';
  final room = _Room();
  @override
  String? get userID => currentUser;
  @override
  String? get deviceID => currentDevice;
  @override
  matrix.Room? getRoomById(String id) => room.id == id ? room : null;
  @override
  Future<void> logout() async {
    accessToken = null;
    currentUser = currentDevice = null;
    onLoginStateChanged.add(matrix.LoginState.loggedOut);
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Room extends Fake implements matrix.Room {
  int sends = 0;
  @override
  String get id => '!room:matrix.example';
  @override
  bool get encrypted => false;
  @override
  matrix.Membership get membership => matrix.Membership.join;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sendFileEvent) {
      sends++;
      return Future<String?>.value(r'$sent');
    }
    return super.noSuchMethod(invocation);
  }
}

class _HeldFile extends XFile {
  _HeldFile({Uint8List? bytes})
    : bytes = bytes ?? Uint8List.fromList([1]),
      super('held.dat');
  final Uint8List bytes;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<int> length() async => 1;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    started.complete();
    await release.future;
    yield bytes;
  }
}
