import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A salted PBKDF2-HMAC-SHA256 PIN verifier, stored as JSON in secure storage.
/// The plaintext PIN is never stored.
class PinHash {
  const PinHash({
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  final Uint8List salt;
  final Uint8List hash;
  final int iterations;

  static const defaultIterations = 120000;

  static PinHash create(String pin, {int iterations = defaultIterations}) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    return PinHash(
      salt: salt,
      hash: pbkdf2(utf8.encode(pin), salt, iterations),
      iterations: iterations,
    );
  }

  /// Constant-time comparison of a candidate PIN.
  bool verify(String pin) {
    final candidate = pbkdf2(utf8.encode(pin), salt, iterations);
    if (candidate.length != hash.length) return false;
    var diff = 0;
    for (var i = 0; i < hash.length; i++) {
      diff |= candidate[i] ^ hash[i];
    }
    return diff == 0;
  }

  String encode() => jsonEncode({
    'v': 1,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
    'iterations': iterations,
  });

  /// Returns null for malformed or tampered records.
  static PinHash? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value);
      if (json is! Map || json['v'] != 1) return null;
      final iterations = json['iterations'];
      final salt = base64Decode(json['salt'] as String);
      final hash = base64Decode(json['hash'] as String);
      if (iterations is! int ||
          iterations < 1 ||
          iterations > 10000000 ||
          salt.length < 8 ||
          hash.length != 32) {
        return null;
      }
      return PinHash(salt: salt, hash: hash, iterations: iterations);
    } catch (_) {
      return null;
    }
  }
}

/// PBKDF2 with HMAC-SHA256 producing one 32-byte block (RFC 8018).
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (var i = 1; i < iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return result;
}
