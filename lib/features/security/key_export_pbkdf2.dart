import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Reports work done as a fraction between 0 and 1.
typedef KeyCryptoProgress = void Function(double fraction);

/// PBKDF2 with HMAC-SHA-512 (RFC 8018), as required by Matrix key exports.
///
/// vodozemac's `CryptoUtils.pbkdf2` is fixed to a 32-byte output, but a key
/// export needs all 64 bytes (AES key + HMAC key), so this is a pure-Dart
/// implementation. It keeps the HMAC inner/outer pad states and the working
/// block as 64-bit words, so each iteration costs two SHA-512 compressions
/// and no allocations: about seven times faster than looping over
/// `package:crypto`'s HMAC, which matters at 500,000 rounds on a phone.
/// Relies on 64-bit integers (Dart VM/AOT), which every Parallax target has.
Uint8List pbkdf2HmacSha512(
  List<int> password,
  List<int> salt,
  int iterations, {
  int length = 64,
  KeyCryptoProgress? onProgress,
}) {
  if (iterations < 1) throw ArgumentError.value(iterations, 'iterations');
  if (length < 1) throw ArgumentError.value(length, 'length');
  // HMAC keys longer than the SHA-512 block are hashed first.
  final key = password.length > 128
      ? crypto.sha512.convert(password).bytes
      : password;
  final scratch = Int64List(80);
  final inner = _padState(key, 0x36, scratch);
  final outer = _padState(key, 0x5c, scratch);
  final firstMac = crypto.Hmac(crypto.sha512, key);
  final blocks = (length + 63) ~/ 64;
  final output = Uint8List(blocks * 64);
  final outputView = ByteData.sublistView(output);
  final total = blocks * iterations;
  final reportEvery = total ~/ 100 < 1 ? 1 : total ~/ 100;
  var done = 0;

  final message = Int64List(16);
  final digest = Int64List(8);
  final sum = Int64List(8);
  for (var blockIndex = 1; blockIndex <= blocks; blockIndex++) {
    final first = Uint8List(salt.length + 4)..setAll(0, salt);
    ByteData.sublistView(first).setUint32(salt.length, blockIndex);
    final u1 = ByteData.sublistView(
      Uint8List.fromList(firstMac.convert(first).bytes),
    );
    for (var i = 0; i < 8; i++) {
      message[i] = u1.getInt64(i * 8);
      sum[i] = message[i];
    }
    // SHA-512 padding for a 64-byte message after one 128-byte pad block.
    message[8] = 0x80 << 56;
    for (var i = 9; i < 15; i++) {
      message[i] = 0;
    }
    message[15] = (128 + 64) * 8;
    done++;
    for (var round = 1; round < iterations; round++) {
      _compress(inner, message, digest, scratch);
      for (var i = 0; i < 8; i++) {
        message[i] = digest[i];
      }
      _compress(outer, message, digest, scratch);
      for (var i = 0; i < 8; i++) {
        message[i] = digest[i];
        sum[i] ^= digest[i];
      }
      if (++done % reportEvery == 0) onProgress?.call(done / total);
    }
    for (var i = 0; i < 8; i++) {
      outputView.setInt64((blockIndex - 1) * 64 + i * 8, sum[i]);
    }
  }
  onProgress?.call(1);
  if (output.length == length) return output;
  final result = Uint8List.fromList(output.sublist(0, length));
  output.fillRange(0, output.length, 0);
  return result;
}

Int64List _padState(List<int> key, int pad, Int64List scratch) {
  final bytes = Uint8List(128)..fillRange(0, 128, pad);
  for (var i = 0; i < key.length; i++) {
    bytes[i] ^= key[i];
  }
  final view = ByteData.sublistView(bytes);
  final block = Int64List(16);
  for (var i = 0; i < 16; i++) {
    block[i] = view.getInt64(i * 8);
  }
  final state = Int64List(8);
  _compress(_initialHash, block, state, scratch);
  bytes.fillRange(0, 128, 0);
  return state;
}

int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

/// One SHA-512 compression of [block] (16 words) from [state] into [out].
void _compress(Int64List state, Int64List block, Int64List out, Int64List w) {
  for (var i = 0; i < 16; i++) {
    w[i] = block[i];
  }
  for (var i = 16; i < 80; i++) {
    final x = w[i - 15];
    final y = w[i - 2];
    final s0 = _rotr(x, 1) ^ _rotr(x, 8) ^ (x >>> 7);
    final s1 = _rotr(y, 19) ^ _rotr(y, 61) ^ (y >>> 6);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  for (var i = 0; i < 80; i++) {
    final s1 = _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41);
    final ch = (e & f) ^ (~e & g);
    final t1 = h + s1 + ch + _roundConstants[i] + w[i];
    final s0 = _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  out[0] = state[0] + a;
  out[1] = state[1] + b;
  out[2] = state[2] + c;
  out[3] = state[3] + d;
  out[4] = state[4] + e;
  out[5] = state[5] + f;
  out[6] = state[6] + g;
  out[7] = state[7] + h;
}

/// Builds 64-bit words from big-endian 32-bit halves (FIPS 180-4 tables).
Int64List _words(List<int> halves) {
  final words = Int64List(halves.length ~/ 2);
  for (var i = 0; i < words.length; i++) {
    words[i] = (halves[i * 2] << 32) | halves[i * 2 + 1];
  }
  return words;
}

final _initialHash = _words(const [
  0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, //
  0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
  0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f,
  0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
]);

final _roundConstants = _words(const [
  0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, //
  0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
  0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019,
  0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
  0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe,
  0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
  0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1,
  0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
  0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3,
  0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
  0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483,
  0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
  0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210,
  0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
  0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725,
  0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
  0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926,
  0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
  0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8,
  0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
  0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001,
  0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
  0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910,
  0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
  0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53,
  0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
  0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb,
  0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
  0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60,
  0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
  0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9,
  0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
  0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207,
  0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
  0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6,
  0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
  0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493,
  0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
  0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a,
  0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
]);
