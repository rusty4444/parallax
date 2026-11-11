import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parallax/matrix_send_guard.dart';

void main() {
  final plain = Uri.parse(
    'https://matrix.example/_matrix/client/v3/rooms/%21room%3Aexample/send/m.room.message/txn',
  );
  final encrypted = Uri.parse(
    'https://matrix.example/_matrix/client/v3/rooms/%21room%3Aexample/send/m.room.encrypted/txn',
  );
  final upload = Uri.parse('https://matrix.example/_matrix/media/v3/upload');
  final toDevice = Uri.parse(
    'https://matrix.example/_matrix/client/v3/sendToDevice/m.room.encrypted/txn',
  );

  test(
    'blocks plaintext in an encrypted room even outside a protected zone',
    () async {
      final inner = _RecordingClient();
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (id) => id == '!room:example',
      );
      await expectLater(
        guard.send(http.Request('PUT', plain)),
        throwsStateError,
      );
      expect(inner.requests, isEmpty);
      await guard.send(http.Request('PUT', encrypted));
      expect(inner.requests, hasLength(1));
    },
  );

  test('blocks SDK plaintext fallback during a protected send', () async {
    final inner = _RecordingClient();
    final guard = MatrixSendGuard(
      inner,
      encryptionAvailable: () => true,
      isEncryptedRoom: (_) => false,
    );
    await expectLater(
      guard.protect(
        '!room:example',
        () => guard.send(http.Request('PUT', plain)),
        ownerCurrent: () => true,
        validateRecipients: () async {},
      ),
      throwsStateError,
    );
    expect(inner.requests, isEmpty);
  });

  test('encryption loss during an SDK await blocks media upload', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final inner = _RecordingClient();
    var available = true;
    final guard = MatrixSendGuard(
      inner,
      encryptionAvailable: () => available,
      isEncryptedRoom: (_) => false,
    );
    final pending = guard.protect(
      '!room:example',
      () async {
        started.complete();
        await gate.future;
        return guard.send(http.Request('POST', upload));
      },
      ownerCurrent: () => true,
      validateRecipients: () async {},
    );
    await started.future;
    available = false;
    gate.complete();
    await expectLater(pending, throwsStateError);
    expect(inner.requests, isEmpty);
  });

  test('session replacement during an SDK await blocks transmission', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final inner = _RecordingClient();
    var ownerCurrent = true;
    final guard = MatrixSendGuard(
      inner,
      encryptionAvailable: () => true,
      isEncryptedRoom: (_) => false,
    );
    final pending = guard.protect(
      '!room:example',
      () async {
        started.complete();
        await gate.future;
        return guard.send(http.Request('PUT', encrypted));
      },
      ownerCurrent: () => ownerCurrent,
      validateRecipients: () async {},
    );
    await started.future;
    ownerCurrent = false;
    gate.complete();
    await expectLater(pending, throwsStateError);
    expect(inner.requests, isEmpty);
  });

  test(
    'recipient change blocks Megolm key distribution and final event',
    () async {
      final inner = _RecordingClient();
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (_) => false,
      );
      var current = false;
      Future<void> check() async {
        if (!current) throw StateError('roster changed');
      }

      await expectLater(
        guard.protect(
          '!room:example',
          () => guard.send(http.Request('PUT', toDevice)),
          ownerCurrent: () => true,
          validateRecipients: check,
        ),
        throwsStateError,
      );
      await expectLater(
        guard.protect(
          '!room:example',
          () => guard.send(http.Request('PUT', encrypted)),
          ownerCurrent: () => true,
          validateRecipients: check,
        ),
        throwsStateError,
      );
      expect(inner.requests, isEmpty);
      current = true;
      await guard.protect(
        '!room:example',
        () => guard.send(http.Request('PUT', encrypted)),
        ownerCurrent: () => true,
        validateRecipients: check,
      );
      expect(inner.requests, hasLength(1));
    },
  );
}

class _RecordingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value(<int>[]), 200);
  }
}
