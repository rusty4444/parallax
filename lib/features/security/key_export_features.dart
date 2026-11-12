import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../matrix_backend.dart';
import 'key_export_format.dart';
import 'key_export_matrix.dart';

export 'key_export_format.dart'
    show
        KeyExportError,
        KeyExportFormatException,
        KeyImportPayload,
        keyExportDefaultRounds,
        keyExportFileName,
        keyExportMaxFileBytes;

/// Reports Megolm sessions processed so far.
typedef KeyCountProgress = void Function(int done, int total);

/// SDK side of room-key export/import. The Matrix implementation wraps
/// [MatrixBackend] (`key_export_matrix.dart`); tests implement it directly.
abstract interface class KeyExportFeatures {
  /// Identifies the signed-in device session, or null when signed out.
  String? get sessionKey;

  /// Every inbound Megolm session on this device as spec
  /// `ExportedSessionData` maps, each exported at its first known index.
  Future<List<Map<String, Object?>>> exportSessions({
    KeyCountProgress? onProgress,
  });

  /// Adds sanitised sessions as imported (forwarded) keys and returns how
  /// many were new or better than the copy already held. [onProgress]
  /// receives processed and imported counts so a caller can report partial
  /// progress when the import is interrupted.
  Future<int> importSessions(
    List<Map<String, Object?>> sessions, {
    void Function(int done, int total, int imported)? onProgress,
  });
}

final _cache = Expando<KeyExportFeatures>('parallax.keyExport');

/// Resolves the key export module for a backend, or null when unsupported.
KeyExportFeatures? keyExportFeaturesOf(ChatBackend backend) =>
    backend is KeyExportFeatures
    ? backend as KeyExportFeatures
    : backend is MatrixBackend
    ? _cache[backend] ??= MatrixKeyExport(backend)
    : null;

enum KeyTransferStage { collecting, encrypting, decrypting, importing }

@immutable
class KeyTransferProgress {
  const KeyTransferProgress(this.stage, {this.fraction, this.done, this.total});
  final KeyTransferStage stage;

  /// 0–1, or null when indeterminate.
  final double? fraction;
  final int? done;
  final int? total;
}

enum KeyTransferFailure {
  /// The file failed to parse, verify or decrypt; see [KeyTransferException.format].
  file,

  /// This device has no room keys to export.
  noKeys,

  /// Signed out or switched account part-way through.
  sessionChanged,

  /// Encryption is unavailable or another encryption task is running.
  unavailable,

  /// Import stopped part-way; [KeyTransferException.imported] keys were kept.
  interrupted,
}

class KeyTransferException implements Exception {
  const KeyTransferException(
    this.failure, {
    this.format,
    this.imported = 0,
    this.total = 0,
  });
  final KeyTransferFailure failure;
  final KeyExportError? format;
  final int imported;
  final int total;

  @override
  String toString() =>
      'KeyTransferException(${failure.name}'
      '${format == null ? '' : ', ${format!.name}'})';
}

@immutable
class KeyExportFile {
  const KeyExportFile({required this.bytes, required this.keyCount});

  /// The armoured, passphrase-encrypted file. Safe to keep in memory for a
  /// save retry: it reveals nothing without the passphrase.
  final Uint8List bytes;
  final int keyCount;
}

@immutable
class KeyImportResult {
  const KeyImportResult({required this.imported, required this.total});
  final int imported;
  final int total;
}

/// Encrypts/decrypts key export files. [IsolateKeyExportCipher] runs PBKDF2
/// off the UI isolate; tests can use [InlineKeyExportCipher].
abstract interface class KeyExportCipher {
  Future<Uint8List> encrypt(
    String plaintext,
    String passphrase, {
    required int rounds,
    KeyCryptoProgress? onProgress,
  });

  Future<KeyImportPayload> decrypt(
    Uint8List file,
    String passphrase, {
    KeyCryptoProgress? onProgress,
  });
}

/// Runs the whole codec (PBKDF2, AES-CTR, HMAC, JSON) in a short-lived
/// background isolate and streams progress back over a port.
class IsolateKeyExportCipher implements KeyExportCipher {
  const IsolateKeyExportCipher();

  @override
  Future<Uint8List> encrypt(
    String plaintext,
    String passphrase, {
    required int rounds,
    KeyCryptoProgress? onProgress,
  }) => _withProgress(
    onProgress,
    (port) => _encryptInIsolate(plaintext, passphrase, rounds, port),
  );

  @override
  Future<KeyImportPayload> decrypt(
    Uint8List file,
    String passphrase, {
    KeyCryptoProgress? onProgress,
  }) => _withProgress(
    onProgress,
    (port) => _decryptInIsolate(file, passphrase, port),
  );

  static Future<T> _withProgress<T>(
    KeyCryptoProgress? onProgress,
    Future<T> Function(SendPort port) run,
  ) async {
    final port = ReceivePort();
    final subscription = port.listen((message) {
      if (message is double) onProgress?.call(message);
    });
    try {
      return await run(port.sendPort);
    } finally {
      await subscription.cancel();
      port.close();
    }
  }
}

// Top-level so the isolate closures capture only sendable arguments (never
// a widget, state object or the caller's progress callback).
Future<Uint8List> _encryptInIsolate(
  String plaintext,
  String passphrase,
  int rounds,
  SendPort progress,
) => Isolate.run(
  () => encryptKeyExport(
    plaintext,
    passphrase,
    rounds: rounds,
    onProgress: progress.send,
  ),
  debugName: 'parallax.keyExport.encrypt',
);

Future<KeyImportPayload> _decryptInIsolate(
  Uint8List file,
  String passphrase,
  SendPort progress,
) => Isolate.run(
  () => decryptKeyExportPayload(file, passphrase, onProgress: progress.send),
  debugName: 'parallax.keyExport.decrypt',
);

/// Same codec on the calling isolate. For tests and tiny round counts only.
class InlineKeyExportCipher implements KeyExportCipher {
  const InlineKeyExportCipher();

  @override
  Future<Uint8List> encrypt(
    String plaintext,
    String passphrase, {
    required int rounds,
    KeyCryptoProgress? onProgress,
  }) async => encryptKeyExport(
    plaintext,
    passphrase,
    rounds: rounds,
    onProgress: onProgress,
  );

  @override
  Future<KeyImportPayload> decrypt(
    Uint8List file,
    String passphrase, {
    KeyCryptoProgress? onProgress,
  }) async => decryptKeyExportPayload(file, passphrase, onProgress: onProgress);
}

/// A file chosen for import.
@immutable
class PickedKeyFile {
  const PickedKeyFile({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

/// Saving and picking key files (system file picker in the app).
abstract interface class KeyFileAccess {
  /// Returns false when the user cancelled.
  Future<bool> save(String fileName, Uint8List bytes);

  /// Returns null when the user cancelled. Throws a
  /// [KeyExportFormatException] ([KeyExportError.tooLarge]) for files over
  /// [keyExportMaxFileBytes].
  Future<PickedKeyFile?> pick();
}

class PlatformKeyFileAccess implements KeyFileAccess {
  const PlatformKeyFileAccess();

  @override
  Future<bool> save(String fileName, Uint8List bytes) async =>
      await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'text/plain',
      ) !=
      null;

  @override
  Future<PickedKeyFile?> pick() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose a room key file',
    );
    if (file == null) return null;
    final length = await file.length();
    if (length != null && length > keyExportMaxFileBytes) {
      throw const KeyExportFormatException(KeyExportError.tooLarge);
    }
    // Stream with a cap: a provider may not report the size up front.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.xFile.openRead()) {
      bytes.add(chunk);
      if (bytes.length > keyExportMaxFileBytes) {
        throw const KeyExportFormatException(KeyExportError.tooLarge);
      }
    }
    return PickedKeyFile(name: file.name, bytes: bytes.takeBytes());
  }
}

/// Export/import use cases: collects sessions through [keys], encrypts or
/// decrypts with [cipher] and guards against the session changing between
/// steps. File I/O goes through [files].
class RoomKeyTransfer {
  RoomKeyTransfer(
    this.keys, {
    this.cipher = const IsolateKeyExportCipher(),
    this.files = const PlatformKeyFileAccess(),
    this.rounds = keyExportDefaultRounds,
  });

  final KeyExportFeatures keys;
  final KeyExportCipher cipher;
  final KeyFileAccess files;
  final int rounds;

  static RoomKeyTransfer? of(ChatBackend backend) {
    final keys = keyExportFeaturesOf(backend);
    return keys == null ? null : RoomKeyTransfer(keys);
  }

  /// Collects every room key and encrypts it with [passphrase].
  Future<KeyExportFile> export(
    String passphrase, {
    void Function(KeyTransferProgress progress)? onProgress,
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError.value('', 'passphrase', 'A passphrase is required');
    }
    final session = _requireSession();
    onProgress?.call(const KeyTransferProgress(KeyTransferStage.collecting));
    final List<Map<String, Object?>> sessions;
    try {
      sessions = await keys.exportSessions(
        onProgress: (done, total) => onProgress?.call(
          KeyTransferProgress(
            KeyTransferStage.collecting,
            fraction: total == 0 ? null : done / total,
            done: done,
            total: total,
          ),
        ),
      );
    } on KeyTransferException {
      rethrow;
    } catch (_) {
      _checkSession(session);
      throw const KeyTransferException(KeyTransferFailure.unavailable);
    }
    _checkSession(session);
    if (sessions.isEmpty) {
      throw const KeyTransferException(KeyTransferFailure.noKeys);
    }
    onProgress?.call(
      const KeyTransferProgress(KeyTransferStage.encrypting, fraction: 0),
    );
    final bytes = await cipher.encrypt(
      jsonEncode(sessions),
      passphrase,
      rounds: rounds,
      onProgress: (fraction) => onProgress?.call(
        KeyTransferProgress(KeyTransferStage.encrypting, fraction: fraction),
      ),
    );
    // A file for an account that signed out meanwhile is not offered.
    _checkSession(session);
    return KeyExportFile(bytes: bytes, keyCount: sessions.length);
  }

  /// Verifies and decrypts [file], then adds its sessions as imported keys.
  Future<KeyImportResult> import(
    Uint8List file,
    String passphrase, {
    void Function(KeyTransferProgress progress)? onProgress,
  }) async {
    final session = _requireSession();
    if (file.length > keyExportMaxFileBytes) {
      throw const KeyTransferException(
        KeyTransferFailure.file,
        format: KeyExportError.tooLarge,
      );
    }
    onProgress?.call(
      const KeyTransferProgress(KeyTransferStage.decrypting, fraction: 0),
    );
    final KeyImportPayload payload;
    try {
      payload = await cipher.decrypt(
        file,
        passphrase,
        onProgress: (fraction) => onProgress?.call(
          KeyTransferProgress(KeyTransferStage.decrypting, fraction: fraction),
        ),
      );
    } on KeyExportFormatException catch (error) {
      throw KeyTransferException(KeyTransferFailure.file, format: error.error);
    }
    _checkSession(session);
    if (payload.sessions.isEmpty) {
      return KeyImportResult(imported: 0, total: payload.total);
    }
    var imported = 0;
    void report(int done, int total, int count) {
      imported = count;
      onProgress?.call(
        KeyTransferProgress(
          KeyTransferStage.importing,
          fraction: total == 0 ? null : done / total,
          done: done,
          total: total,
        ),
      );
    }

    report(0, payload.sessions.length, 0);
    try {
      imported = await keys.importSessions(
        payload.sessions,
        onProgress: report,
      );
    } catch (_) {
      if (keys.sessionKey != session) {
        throw KeyTransferException(
          KeyTransferFailure.sessionChanged,
          imported: imported,
          total: payload.total,
        );
      }
      throw KeyTransferException(
        KeyTransferFailure.interrupted,
        imported: imported,
        total: payload.total,
      );
    }
    _checkSession(session);
    return KeyImportResult(imported: imported, total: payload.total);
  }

  String _requireSession() =>
      keys.sessionKey ??
      (throw const KeyTransferException(KeyTransferFailure.unavailable));

  void _checkSession(String session) {
    if (keys.sessionKey != session) {
      throw const KeyTransferException(KeyTransferFailure.sessionChanged);
    }
  }
}
