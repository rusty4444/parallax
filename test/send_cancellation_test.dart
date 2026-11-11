import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
// This regression intentionally exercises the resolved SDK's HTTP decorator.
// ignore: implementation_imports
import 'package:matrix/src/utils/http_timeout.dart' as sdk_http;
import 'package:parallax/matrix_send_guard.dart';
import 'package:parallax/send_cancellation.dart';

void main() {
  test('cancellation is idempotent and check rejects cancelled work', () async {
    final cancellation = SendCancellation();
    cancellation.check();
    cancellation.cancel();
    cancellation.cancel();
    await cancellation.whenCancelled;
    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.check, throwsA(isA<SendCancelled>()));
  });

  test('cancelled sends stop SDK retry before any HTTP dispatch', () async {
    final inner = _RecordingClient();
    final guard = MatrixSendGuard(
      inner,
      encryptionAvailable: () => true,
      isEncryptedRoom: (_) => false,
    );
    final token = SendCancellation()..cancel();
    await expectLater(
      MatrixSendGuard.cancellable(
        token,
        () => guard.send(
          http.Request('PUT', Uri.parse('https://matrix.example/send')),
        ),
      ),
      throwsA(
        isA<matrix.MatrixException>().having(
          (e) => e.errcode,
          'SDK nonretryable outcome',
          'M_FORBIDDEN',
        ),
      ),
    );
    expect(inner.requests, 0);
  });

  test(
    'cancellation while checking recipients stops the final request',
    () async {
      final inner = _RecordingClient();
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (_) => true,
      );
      final token = SendCancellation();
      final checking = Completer<void>();
      final checked = Completer<void>();
      final request = MatrixSendGuard.cancellable(
        token,
        () => guard.protect(
          '!room:example',
          () => guard.send(
            http.Request(
              'PUT',
              Uri.parse(
                'https://matrix.example/_matrix/client/v3/rooms/%21room%3Aexample/send/m.room.encrypted/txn',
              ),
            ),
          ),
          ownerCurrent: () => true,
          validateRecipients: () async {
            checking.complete();
            await checked.future;
          },
        ),
      );
      final assertion = expectLater(
        request,
        throwsA(isA<matrix.MatrixException>()),
      );
      await checking.future;
      token.cancel();
      checked.complete();
      await assertion;
      expect(inner.requests, 0);
    },
  );

  for (final useSdkTimeout in [false, true]) {
    for (final useOriginalAbort in [false, true]) {
      test(
        'real HTTP aborts stalled headers (SDK timeout: $useSdkTimeout, original abort: $useOriginalAbort)',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final received = Completer<void>();
          server.listen((request) {
            unawaited(request.drain<void>().catchError((Object _) {}));
            if (!received.isCompleted) received.complete();
            // Deliberately do not send response headers. Cancellation must abort the
            // HTTP operation, not merely hide a loading indicator.
          });
          final guard = MatrixSendGuard(
            http.Client(),
            encryptionAvailable: () => true,
            isEncryptedRoom: (_) => false,
          );
          final token = SendCancellation();
          final originalAbort = Completer<void>();
          final http.Client transport = useSdkTimeout
              ? sdk_http.FixedTimeoutHttpClient(
                  guard,
                  const Duration(seconds: 30),
                )
              : guard;
          try {
            final request = MatrixSendGuard.cancellable(
              token,
              () => transport.send(
                http.AbortableRequest(
                  'POST',
                  Uri.parse('http://127.0.0.1:${server.port}/upload'),
                  abortTrigger: originalAbort.future,
                )..body = 'test body',
              ),
            );
            final assertion = expectLater(
              request,
              throwsA(isA<http.RequestAbortedException>()),
            );
            await received.future.timeout(const Duration(seconds: 5));
            if (useOriginalAbort) {
              originalAbort.complete();
            } else {
              token.cancel();
            }
            await assertion.timeout(const Duration(seconds: 5));
            expect(token.isCancelled, !useOriginalAbort);
          } finally {
            guard.close();
            await server.close(force: true);
          }
        },
      );
    }
  }
}

class _RecordingClient extends http.BaseClient {
  int requests = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}
