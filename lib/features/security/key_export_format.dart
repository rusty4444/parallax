import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart'
    show MacAlgorithm, SecretKeyData;
import 'package:cryptography/dart.dart' show DartAesCtr;

import 'key_export_pbkdf2.dart';

export 'key_export_pbkdf2.dart' show KeyCryptoProgress, pbkdf2HmacSha512;

/// Matrix "Key exports" file format (client-server spec, also used by
/// Element Web, Element X/matrix-rust-sdk and other clients):
///
///     0x01 | salt (16) | IV (16, bit 63 clear) | rounds (u32 BE) |
///     AES-256-CTR(JSON) | HMAC-SHA-256(all of the above)
///
/// The AES and HMAC keys are the two halves of
/// PBKDF2-HMAC-SHA-512(passphrase, salt, rounds, 64 bytes). The result is
/// base64, wrapped between [keyExportHeader] and [keyExportTrailer].
const keyExportHeader = '-----BEGIN MEGOLM SESSION DATA-----';
const keyExportTrailer = '-----END MEGOLM SESSION DATA-----';

/// Element Web's default; the spec asks for at least 100,000.
const keyExportDefaultRounds = 500000;

/// Imported files choose their own round count. Bound it so a crafted file
/// cannot pin the CPU for hours (2^32 rounds); 20x Element's default.
const keyExportMaxRounds = 10000000;

/// Larger than any realistic export (roughly 1 KB per session); bounds the
/// memory a picked file can claim before it is even decrypted.
const keyExportMaxFileBytes = 64 * 1024 * 1024;
const keyExportMaxSessions = 250000;

/// Base64 characters per line in files we write. Any wrapping is accepted.
const keyExportLineLength = 96;

/// Suggested file name, matching Element.
const keyExportFileName = 'element-keys.txt';

const megolmAlgorithm = 'm.megolm.v1.aes-sha2';

const _versionLength = 1;
const _saltLength = 16;
const _ivLength = 16;
const _roundsLength = 4;
const _macLength = 32;
const _headerLength = _versionLength + _saltLength + _ivLength + _roundsLength;

enum KeyExportError {
  /// No `BEGIN MEGOLM SESSION DATA` line: not a key export at all.
  notKeyFile,

  /// Missing trailer, bad base64 or too short: truncated or corrupted.
  damaged,

  /// Unknown version byte.
  unsupportedVersion,

  /// Zero rounds or more than [keyExportMaxRounds].
  unsupportedRounds,

  /// HMAC mismatch: wrong passphrase, or the file was modified.
  badPassphrase,

  /// Decrypted, but not UTF-8 JSON in the export format.
  invalidContent,

  /// Over [keyExportMaxFileBytes] or [keyExportMaxSessions].
  tooLarge,
}

class KeyExportFormatException implements Exception {
  const KeyExportFormatException(this.error, [this.detail = '']);
  final KeyExportError error;
  final String detail;

  @override
  String toString() =>
      'KeyExportFormatException(${error.name}'
      '${detail.isEmpty ? '' : ': $detail'})';
}

/// Encrypts [plaintext] (the JSON array) into an armoured key export file.
/// [salt] and [iv] are for deterministic tests only.
Uint8List encryptKeyExport(
  String plaintext,
  String passphrase, {
  int rounds = keyExportDefaultRounds,
  List<int>? salt,
  List<int>? iv,
  KeyCryptoProgress? onProgress,
}) {
  if (passphrase.isEmpty) {
    throw ArgumentError.value('', 'passphrase', 'A passphrase is required');
  }
  if (rounds < 1 || rounds > 0xffffffff) {
    throw ArgumentError.value(rounds, 'rounds');
  }
  final saltBytes = Uint8List.fromList(salt ?? _randomBytes(_saltLength));
  final ivBytes = Uint8List.fromList(iv ?? _randomBytes(_ivLength));
  if (saltBytes.length != _saltLength || ivBytes.length != _ivLength) {
    throw ArgumentError('Salt and IV must be 16 bytes');
  }
  // Clear bit 63 so 64-bit (WebCrypto) and 128-bit (Rust) counters agree.
  ivBytes[8] &= 0x7f;

  final keys = pbkdf2HmacSha512(
    utf8.encode(passphrase),
    saltBytes,
    rounds,
    onProgress: onProgress == null ? null : (f) => onProgress(f * 0.95),
  );
  try {
    final ciphertext = _aesCtr(utf8.encode(plaintext), keys, ivBytes);
    final body = Uint8List(_headerLength + ciphertext.length + _macLength);
    body[0] = 1;
    body.setAll(_versionLength, saltBytes);
    body.setAll(_versionLength + _saltLength, ivBytes);
    ByteData.sublistView(
      body,
    ).setUint32(_versionLength + _saltLength + _ivLength, rounds);
    body.setAll(_headerLength, ciphertext);
    final signed = Uint8List.sublistView(body, 0, body.length - _macLength);
    body.setAll(signed.length, _hmac(keys, signed));
    onProgress?.call(1);
    return armourKeyExport(body);
  } finally {
    keys.fillRange(0, keys.length, 0);
  }
}

/// Verifies and decrypts an armoured key export, returning the UTF-8 text.
Uint8List decryptKeyExportBytes(
  List<int> file,
  String passphrase, {
  int maxRounds = keyExportMaxRounds,
  KeyCryptoProgress? onProgress,
}) {
  final body = unarmourKeyExport(file);
  if (body.isEmpty) {
    throw const KeyExportFormatException(KeyExportError.damaged, 'empty');
  }
  if (body[0] != 1) {
    throw KeyExportFormatException(
      KeyExportError.unsupportedVersion,
      'version ${body[0]}',
    );
  }
  if (body.length < _headerLength + _macLength) {
    throw const KeyExportFormatException(KeyExportError.damaged, 'too short');
  }
  final salt = Uint8List.sublistView(body, 1, 1 + _saltLength);
  final iv = Uint8List.sublistView(body, 17, 17 + _ivLength);
  final rounds = ByteData.sublistView(body, 33, 37).getUint32(0);
  if (rounds < 1 || rounds > maxRounds) {
    throw KeyExportFormatException(
      KeyExportError.unsupportedRounds,
      '$rounds rounds',
    );
  }
  final keys = pbkdf2HmacSha512(
    utf8.encode(passphrase),
    salt,
    rounds,
    onProgress: onProgress == null ? null : (f) => onProgress(f * 0.95),
  );
  try {
    final signed = Uint8List.sublistView(body, 0, body.length - _macLength);
    final mac = Uint8List.sublistView(body, body.length - _macLength);
    if (!_constantTimeEquals(_hmac(keys, signed), mac)) {
      throw const KeyExportFormatException(KeyExportError.badPassphrase);
    }
    final ciphertext = Uint8List.sublistView(
      body,
      _headerLength,
      body.length - _macLength,
    );
    final plaintext = _aesCtr(ciphertext, keys, iv);
    onProgress?.call(1);
    return plaintext;
  } finally {
    keys.fillRange(0, keys.length, 0);
  }
}

/// [decryptKeyExportBytes] decoded as UTF-8.
String decryptKeyExport(
  List<int> file,
  String passphrase, {
  int maxRounds = keyExportMaxRounds,
  KeyCryptoProgress? onProgress,
}) {
  final plaintext = decryptKeyExportBytes(
    file,
    passphrase,
    maxRounds: maxRounds,
    onProgress: onProgress,
  );
  try {
    return utf8.decode(plaintext);
  } on FormatException {
    throw const KeyExportFormatException(
      KeyExportError.invalidContent,
      'not UTF-8',
    );
  }
}

/// Base64 between the header and trailer lines, [keyExportLineLength] wide.
Uint8List armourKeyExport(List<int> body) {
  final encoded = base64.encode(body);
  final out = StringBuffer()..write('$keyExportHeader\n');
  for (var i = 0; i < encoded.length; i += keyExportLineLength) {
    out
      ..write(
        encoded.substring(i, min(i + keyExportLineLength, encoded.length)),
      )
      ..write('\n');
  }
  out.write('$keyExportTrailer\n');
  return ascii.encode(out.toString());
}

/// Extracts the binary body between the armour lines. Tolerates CRLF, a
/// byte-order mark, surrounding text and any line wrapping.
Uint8List unarmourKeyExport(List<int> file) {
  if (file.length > keyExportMaxFileBytes) {
    throw const KeyExportFormatException(KeyExportError.tooLarge);
  }
  final String text;
  try {
    text = utf8.decode(file);
  } on FormatException {
    throw const KeyExportFormatException(KeyExportError.notKeyFile);
  }
  final lines = const LineSplitter().convert(text);
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    if (_armourLine(lines[i]) == keyExportHeader) {
      start = i + 1;
      break;
    }
  }
  if (start < 0) {
    throw const KeyExportFormatException(KeyExportError.notKeyFile);
  }
  final data = StringBuffer();
  var ended = false;
  for (var i = start; i < lines.length; i++) {
    if (_armourLine(lines[i]) == keyExportTrailer) {
      ended = true;
      break;
    }
    data.write(lines[i]);
  }
  if (!ended) {
    throw const KeyExportFormatException(
      KeyExportError.damaged,
      'trailer line not found',
    );
  }
  final compact = data.toString().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) {
    throw const KeyExportFormatException(KeyExportError.damaged, 'empty');
  }
  try {
    return base64.decode(base64.normalize(compact));
  } on FormatException {
    throw const KeyExportFormatException(KeyExportError.damaged, 'base64');
  }
}

String _armourLine(String line) => line.replaceAll('\uFEFF', '').trim();

/// Valid, sanitised sessions from a decrypted export, plus how many entries
/// the file contained (for "Imported N of M keys").
class KeyImportPayload {
  const KeyImportPayload({required this.sessions, required this.total});
  final List<Map<String, Object?>> sessions;
  final int total;
}

/// Parses the decrypted JSON array. Entries that are not valid Megolm
/// session exports are dropped but still counted in [KeyImportPayload.total].
KeyImportPayload parseKeyExportJson(String text) {
  final Object? decoded;
  try {
    decoded = json.decode(text);
  } on FormatException {
    throw const KeyExportFormatException(
      KeyExportError.invalidContent,
      'not JSON',
    );
  }
  if (decoded is! List) {
    throw const KeyExportFormatException(
      KeyExportError.invalidContent,
      'not a JSON array',
    );
  }
  if (decoded.length > keyExportMaxSessions) {
    throw const KeyExportFormatException(KeyExportError.tooLarge);
  }
  return KeyImportPayload(
    sessions: [for (final entry in decoded) ?sanitiseExportedSession(entry)],
    total: decoded.length,
  );
}

/// Decrypts and parses in one step (what the import worker runs).
KeyImportPayload decryptKeyExportPayload(
  List<int> file,
  String passphrase, {
  int maxRounds = keyExportMaxRounds,
  KeyCryptoProgress? onProgress,
}) => parseKeyExportJson(
  decryptKeyExport(
    file,
    passphrase,
    maxRounds: maxRounds,
    onProgress: onProgress,
  ),
);

/// Returns a spec-shaped copy of one `ExportedSessionData` entry with only
/// known fields, or null when it is not a usable Megolm session.
Map<String, Object?>? sanitiseExportedSession(Object? raw) {
  if (raw is! Map) return null;
  String? text(String key, int maxLength) {
    final value = raw[key];
    return value is String && value.isNotEmpty && value.length <= maxLength
        ? value
        : null;
  }

  if (raw['algorithm'] != megolmAlgorithm) return null;
  final roomId = text('room_id', 255);
  final sessionId = text('session_id', 128);
  final senderKey = text('sender_key', 128);
  final sessionKey = text('session_key', 8192);
  if (roomId == null ||
      !roomId.startsWith('!') ||
      sessionId == null ||
      senderKey == null ||
      sessionKey == null) {
    return null;
  }
  final claimedRaw = raw['sender_claimed_keys'];
  final claimed = <String, String>{};
  if (claimedRaw is Map) {
    for (final MapEntry(:key, :value) in claimedRaw.entries) {
      if (claimed.length >= 8) break;
      if (key is String &&
          key.length <= 64 &&
          value is String &&
          value.isNotEmpty &&
          value.length <= 128) {
        claimed[key] = value;
      }
    }
  } else if (claimedRaw != null) {
    return null;
  }
  final chainRaw = raw['forwarding_curve25519_key_chain'];
  final chain = <String>[];
  if (chainRaw is List) {
    if (chainRaw.length > 64) return null;
    for (final key in chainRaw) {
      if (key is! String || key.isEmpty || key.length > 128) return null;
      chain.add(key);
    }
  } else if (chainRaw != null) {
    return null;
  }
  final shared = raw['shared_history'];
  return {
    'algorithm': megolmAlgorithm,
    'room_id': roomId,
    'session_id': sessionId,
    'sender_key': senderKey,
    'session_key': sessionKey,
    'sender_claimed_keys': claimed,
    'forwarding_curve25519_key_chain': chain,
    if (shared is bool) 'shared_history': shared,
  };
}

/// Builds the export entry for one stored session. [content] is the SDK's
/// stored room-key content (for the forwarding chain and shared-history
/// flag); [sessionKey] must be `exportAt(firstKnownIndex)`.
Map<String, Object?>? exportedSessionEntry({
  required String roomId,
  required String sessionId,
  required String senderKey,
  required String sessionKey,
  Map<String, String> senderClaimedKeys = const {},
  Map<String, Object?> content = const {},
}) => sanitiseExportedSession({
  'algorithm': content['algorithm'] ?? megolmAlgorithm,
  'room_id': roomId,
  'session_id': sessionId,
  'sender_key': senderKey,
  'session_key': sessionKey,
  'sender_claimed_keys': senderClaimedKeys,
  'forwarding_curve25519_key_chain':
      content['forwarding_curve25519_key_chain'] ?? const <String>[],
  if (content['shared_history'] is bool)
    'shared_history': content['shared_history'],
});

/// AES-256-CTR with a 64-bit counter in the low half of the IV, like
/// WebCrypto's `{name: 'AES-CTR', length: 64}` in Element Web: the counter
/// wraps without carrying into the high half. `DartAesCtr` increments all
/// 128 bits, so a message that crosses the wrap (only possible when IV bit
/// 63 is set, which compliant writers avoid) is processed in two segments.
Uint8List _aesCtr(List<int> input, Uint8List keys, Uint8List iv) {
  const cipher = DartAesCtr.with256bits(macAlgorithm: MacAlgorithm.empty);
  final secretKey = SecretKeyData(Uint8List.sublistView(keys, 0, 32));
  List<int> run(List<int> data, List<int> nonce) =>
      cipher.encryptSync(data, secretKey: secretKey, nonce: nonce).cipherText;

  final view = ByteData.sublistView(iv);
  final low =
      (BigInt.from(view.getUint32(8)) << 32) | BigInt.from(view.getUint32(12));
  final blocksBeforeWrap = (BigInt.one << 64) - low;
  final blocks = (input.length + 15) ~/ 16;
  if (BigInt.from(blocks) <= blocksBeforeWrap) {
    return Uint8List.fromList(run(input, iv));
  }
  final split = blocksBeforeWrap.toInt() * 16;
  final wrapped = Uint8List.fromList(iv)..fillRange(8, 16, 0);
  return Uint8List.fromList([
    ...run(input.sublist(0, split), iv),
    ...run(input.sublist(split), wrapped),
  ]);
}

List<int> _hmac(Uint8List keys, List<int> input) => crypto.Hmac(
  crypto.sha256,
  Uint8List.sublistView(keys, 32, 64),
).convert(input).bytes;

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}
