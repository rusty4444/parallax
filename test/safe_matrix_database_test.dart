import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/matrix_send_guard.dart';
import 'package:matrixpress/safe_matrix_database.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

void main() {
  test(
    'failed encrypted to-device delivery is never queued for later replay',
    () async {
      final database = SafeMatrixDatabase('test', database: _UnusedDatabase());
      var wireRequests = 0;
      final guard = MatrixSendGuard(
        _RecordingClient(() => wireRequests++),
        encryptionAvailable: () => true,
        isEncryptedRoom: (_) => true,
      );
      final send = guard.protect(
        '!room:example.org',
        () async {
          try {
            await database.insertIntoToDeviceQueue(
              matrix.EventTypes.Encrypted,
              'txn',
              '{}',
            );
          } on StateError {
            // The SDK can swallow a key-delivery failure; final send still fails.
          }
          return guard.send(
            http.Request(
              'PUT',
              Uri.parse(
                'https://matrix.example/_matrix/client/v3/rooms/%21room%3Aexample.org/send/m.room.encrypted/txn',
              ),
            ),
          );
        },
        ownerCurrent: () => true,
        validateRecipients: () async {},
      );
      await expectLater(send, throwsStateError);
      expect(wireRequests, 0);
    },
  );
}

class _UnusedDatabase implements sqlite.Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.record);
  final void Function() record;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    record();
    return http.StreamedResponse(Stream.value(<int>[]), 200);
  }
}
