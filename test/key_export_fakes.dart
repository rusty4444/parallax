import 'dart:async';
import 'dart:typed_data';

import 'package:parallax/features/security/key_export_features.dart';
import 'package:parallax/features/security/key_export_format.dart';

Map<String, Object?> fakeSession(
  String id, {
  String room = '!room:example.org',
  String key = 'AQAAAAAclzWVMeWBKH+B/WMowa3rb4ma3jEl6n5W4GCs9ue65Cru',
}) => {
  'algorithm': megolmAlgorithm,
  'room_id': room,
  'session_id': id,
  'sender_key': 'RF3s+E7RkTQTGF2d8Deol0FkQvgII2aJDf3/Jp5mxVU',
  'session_key': '$key$id',
  'sender_claimed_keys': {
    'ed25519': 'aj40p+aw64yPIdsxoog8jhPu9i7l7NcFRecuOQblE3Y',
  },
  'forwarding_curve25519_key_chain': <String>[],
};

/// In-memory key store standing in for the SDK's KeyManager.
class FakeKeyStore implements KeyExportFeatures {
  FakeKeyStore([Iterable<Map<String, Object?>> sessions = const []]) {
    for (final s in sessions) {
      stored[s['session_id']! as String] = s;
    }
  }

  String? session = 'session-1';
  final stored = <String, Map<String, Object?>>{};
  Object? exportError;
  int? failImportAt;
  Completer<void>? exportGate;
  int exports = 0;
  int imports = 0;

  @override
  String? get sessionKey => session;

  @override
  Future<List<Map<String, Object?>>> exportSessions({
    KeyCountProgress? onProgress,
  }) async {
    exports++;
    onProgress?.call(0, stored.length);
    await exportGate?.future;
    if (exportError != null) throw exportError!;
    onProgress?.call(stored.length, stored.length);
    return [for (final s in stored.values) Map.of(s)];
  }

  @override
  Future<int> importSessions(
    List<Map<String, Object?>> sessions, {
    void Function(int done, int total, int imported)? onProgress,
  }) async {
    imports++;
    var imported = 0;
    for (var i = 0; i < sessions.length; i++) {
      await Future<void>.delayed(Duration.zero);
      if (failImportAt == i) throw StateError('interrupted');
      final s = sessions[i];
      final id = s['session_id']! as String;
      // Like the SDK: keep an existing copy that is at least as good.
      if (!stored.containsKey(id)) {
        stored[id] = s;
        imported++;
      }
      onProgress?.call(i + 1, sessions.length, imported);
    }
    return imported;
  }
}

/// Saves into memory; pick returns [next].
class FakeKeyFiles implements KeyFileAccess {
  final saved = <String, Uint8List>{};
  bool cancelSave = false;
  int saves = 0;
  PickedKeyFile? next;
  Object? pickError;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    saves++;
    if (cancelSave) return false;
    saved[fileName] = bytes;
    return true;
  }

  @override
  Future<PickedKeyFile?> pick() async {
    if (pickError != null) throw pickError!;
    return next;
  }
}

/// Wraps a cipher so a test can act between steps.
class HookedCipher implements KeyExportCipher {
  HookedCipher({this.beforeResult});
  final void Function()? beforeResult;
  final _inner = const InlineKeyExportCipher();

  @override
  Future<Uint8List> encrypt(
    String plaintext,
    String passphrase, {
    required int rounds,
    KeyCryptoProgress? onProgress,
  }) async {
    final bytes = await _inner.encrypt(
      plaintext,
      passphrase,
      rounds: rounds,
      onProgress: onProgress,
    );
    beforeResult?.call();
    return bytes;
  }

  @override
  Future<KeyImportPayload> decrypt(
    Uint8List file,
    String passphrase, {
    KeyCryptoProgress? onProgress,
  }) async {
    final payload = await _inner.decrypt(
      file,
      passphrase,
      onProgress: onProgress,
    );
    beforeResult?.call();
    return payload;
  }
}
