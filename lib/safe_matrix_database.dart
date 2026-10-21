import 'package:matrix/matrix.dart' as matrix;
import 'package:sqflite/sqflite.dart' as sqlite;

import 'matrix_send_guard.dart';

/// The SDK persists failed encrypted to-device messages without their room or
/// approved-recipient snapshot. Replaying them later could share an old Megolm
/// key with someone no longer approved, so never queue them on this client.
class SafeMatrixDatabase extends matrix.MatrixSdkDatabase {
  SafeMatrixDatabase(super.name, {required sqlite.Database database})
    : super.buildWithoutOpen(database: database);

  @override
  Future<int> insertIntoToDeviceQueue(
    String type,
    String txnId,
    String content,
  ) async {
    if (type == matrix.EventTypes.Encrypted) {
      MatrixSendGuard.invalidateCurrentSend();
      throw StateError('Encrypted to-device retry has no recipient snapshot');
    }
    return super.insertIntoToDeviceQueue(type, txnId, content);
  }

  Future<void> dropLegacyEncryptedQueue() async {
    final queued = await getToDeviceEventQueue();
    for (final entry in queued) {
      if (entry.type == matrix.EventTypes.Encrypted) {
        await deleteFromToDeviceQueue(entry.id);
      }
    }
  }
}
