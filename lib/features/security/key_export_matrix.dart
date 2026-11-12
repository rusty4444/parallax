import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:vodozemac/vodozemac.dart' as vod;

import '../../matrix_backend.dart';
import 'key_export_features.dart';
import 'key_export_format.dart';

/// [KeyExportFeatures] over the live SDK client.
///
/// Both directions run inside [MatrixBackend.runCryptoMaintenance], so sign
/// out, sign in and sends wait while SDK key material is read or written
/// (SDK 14.1 pickles sessions with the mutable `client.userID`). Imports
/// take the lock per batch so queued sends can run in between; every batch
/// must see the same client and passes the session check after each await.
class MatrixKeyExport implements KeyExportFeatures {
  MatrixKeyExport(this._backend);

  final MatrixBackend _backend;

  static const _importBatch = 200;
  static const _yieldEvery = 50;

  matrix.Client? get _client {
    final client = _backend.sdkClient;
    if (client == null ||
        client.userID == null ||
        !_backend.isSessionCurrent(client)) {
      return null;
    }
    return client;
  }

  @override
  String? get sessionKey {
    final client = _client;
    return client == null
        ? null
        : '${client.homeserver}|${client.userID}|${client.deviceID}';
  }

  @override
  Future<List<Map<String, Object?>>> exportSessions({
    KeyCountProgress? onProgress,
  }) => _backend.runCryptoMaintenance((client, isCurrent) async {
    final keyManager = _keyManager(client);
    final userId = client.userID!;
    final rows = await client.database.getAllInboundGroupSessions();
    if (!isCurrent()) throw StateError('Matrix session changed');
    final pickleKey = _pickleKey(userId);
    final sessions = <Map<String, Object?>>[];
    for (var i = 0; i < rows.length; i++) {
      if (i % _yieldEvery == 0) {
        onProgress?.call(i, rows.length);
        await Future<void>.delayed(Duration.zero);
        if (!isCurrent()) throw StateError('Matrix session changed');
      }
      final row = rows[i];
      final entry = _exportOne(
        keyManager,
        roomId: row.roomId,
        sessionId: row.sessionId,
        senderKey: row.senderKey,
        pickle: row.pickle,
        contentJson: row.content,
        claimedKeysJson: row.senderClaimedKeys,
        pickleKey: pickleKey,
        userId: userId,
      );
      if (entry != null) sessions.add(entry);
    }
    onProgress?.call(rows.length, rows.length);
    return sessions;
  });

  @override
  Future<int> importSessions(
    List<Map<String, Object?>> sessions, {
    void Function(int done, int total, int imported)? onProgress,
  }) async {
    matrix.Client? owner;
    var imported = 0;
    for (var start = 0; start < sessions.length; start += _importBatch) {
      final end = min(start + _importBatch, sessions.length);
      await _backend.runCryptoMaintenance((client, isCurrent) async {
        owner ??= client;
        if (!identical(owner, client)) {
          throw StateError('Matrix session changed');
        }
        final keyManager = _keyManager(client);
        for (var i = start; i < end; i++) {
          if (!isCurrent()) throw StateError('Matrix session changed');
          if (await _importOne(keyManager, sessions[i], isCurrent)) {
            imported++;
          }
          // Every item, so an interruption reports an exact partial count.
          onProgress?.call(i + 1, sessions.length, imported);
        }
      });
      // Let queued sends and sync work run between batches.
      await Future<void>.delayed(Duration.zero);
    }
    return imported;
  }

  encryption.KeyManager _keyManager(matrix.Client client) {
    final crypto = client.encryption;
    if (crypto == null || !client.encryptionEnabled) {
      throw StateError('Encryption is unavailable');
    }
    return crypto.keyManager;
  }

  Map<String, Object?>? _exportOne(
    encryption.KeyManager keyManager, {
    required String roomId,
    required String sessionId,
    required String senderKey,
    required String pickle,
    required String contentJson,
    required String claimedKeysJson,
    required Uint8List pickleKey,
    required String userId,
  }) {
    try {
      // A session updated in memory may be newer than its database row.
      final live = keyManager.getInboundGroupSession(roomId, sessionId);
      final liveSession = live?.inboundGroupSession;
      final session = liveSession ?? _unpickle(pickle, pickleKey, userId);
      if (session == null || session.sessionId != sessionId) return null;
      final exported = session.exportAt(session.firstKnownIndex);
      if (exported == null) return null;
      final content = live != null && liveSession != null
          ? Map<String, Object?>.of(live.content)
          : _jsonMap(contentJson);
      final claimed = live != null && liveSession != null
          ? live.senderClaimedKeys
          : _claimedKeys(_jsonMap(claimedKeysJson), content);
      return exportedSessionEntry(
        roomId: roomId,
        sessionId: sessionId,
        senderKey: live != null && liveSession != null
            ? live.senderKey
            : senderKey,
        sessionKey: exported,
        senderClaimedKeys: claimed,
        content: content,
      );
    } catch (_) {
      // One unreadable session must not stop the rest of the export.
      return null;
    }
  }

  /// Mirrors the SDK's online-backup restore (`KeyManager.loadFromResponse`):
  /// the session is added as a forwarded key with its claimed sender keys,
  /// never marked verified, and left for the backup uploader to back up.
  Future<bool> _importOne(
    encryption.KeyManager keyManager,
    Map<String, Object?> entry,
    bool Function() isCurrent,
  ) async {
    final roomId = entry['room_id'] as String;
    final sessionId = entry['session_id'] as String;
    final senderKey = entry['sender_key'] as String;
    final sessionKey = entry['session_key'] as String;
    try {
      // The SDK stores a session under whatever ID it is given; refuse a
      // key that does not belong to the claimed session.
      if (vod.InboundGroupSession.import(sessionKey).sessionId != sessionId) {
        return false;
      }
    } catch (_) {
      return false;
    }
    final before = await keyManager.loadInboundGroupSession(roomId, sessionId);
    if (!isCurrent()) throw StateError('Matrix session changed');
    final claimed = entry['sender_claimed_keys'];
    await keyManager.setInboundGroupSession(
      roomId,
      sessionId,
      senderKey,
      Map<String, dynamic>.of(entry),
      forwarded: true,
      senderClaimedKeys: {
        if (claimed is Map)
          for (final MapEntry(:key, :value) in claimed.entries)
            if (key is String && value is String) key: value,
      },
      uploaded: false,
    );
    if (!isCurrent()) throw StateError('Matrix session changed');
    // setInboundGroupSession keeps an existing copy that is as good or
    // better; only a replaced entry counts as imported. Re-decryption of
    // the open timeline and room preview follows from the SDK's
    // `room.onSessionKeyReceived` event.
    final after = keyManager.getInboundGroupSession(roomId, sessionId);
    return after != null && after.isValid && !identical(after, before);
  }
}

/// SDK 14.1 pickle key (`PickleKeyStringExtension.toPickleKey`, not
/// exported): the user ID's code units, zero-padded or cut to 32 bytes.
Uint8List _pickleKey(String userId) {
  final bytes = Uint8List(32);
  final units = userId.codeUnits;
  for (var i = 0; i < units.length && i < 32; i++) {
    bytes[i] = units[i];
  }
  return bytes;
}

vod.InboundGroupSession? _unpickle(
  String pickle,
  Uint8List pickleKey,
  String userId,
) {
  try {
    return vod.InboundGroupSession.fromPickleEncrypted(
      pickle: pickle,
      pickleKey: pickleKey,
    );
  } catch (_) {
    try {
      // Legacy libolm pickles, as SessionKey.fromDb falls back to.
      return vod.InboundGroupSession.fromOlmPickleEncrypted(
        pickle: pickle,
        pickleKey: Uint8List.fromList(utf8.encode(userId)),
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, Object?> _jsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
  } catch (_) {
    return const {};
  }
}

Map<String, String> _claimedKeys(
  Map<String, Object?> stored,
  Map<String, Object?> content,
) {
  final source = stored.isNotEmpty
      ? stored
      : content['sender_claimed_keys'] is Map
      ? Map<String, Object?>.from(content['sender_claimed_keys'] as Map)
      : content['sender_claimed_ed25519_key'] is String
      ? {'ed25519': content['sender_claimed_ed25519_key']}
      : const <String, Object?>{};
  return {
    for (final MapEntry(:key, :value) in source.entries)
      if (value is String) key: value,
  };
}
