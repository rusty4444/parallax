// QR code payloads for "Sign in with QR code" (MSC4108, plus detection of the
// newer MSC4388 layout).
//
// Byte layouts follow matrix-rust-sdk (matrix-sdk-crypto types/qr_login) at
// the revision shipped in Element X 26.11 (sdk-android 26.11.05):
//
// MSC4108: "MATRIX" | 0x02 | intent (0x03 login, 0x04 reciprocate) |
//   32-byte Curve25519 key | u16be len | rendezvous URL |
//   (reciprocate only) u16be len | server name or homeserver URL
//
// MSC4388 (unstable): "IO_ELEMENT_MSC4388" | 0x03 | intent (0x00 login,
//   0x01 reciprocate) | 32-byte key | u8 len | rendezvous ID | u8 len |
//   homeserver base URL
import 'dart:convert';
import 'dart:typed_data';

enum QrCodeIntent {
  /// The device showing the code wants to sign in (a new device).
  login,

  /// The device showing the code is signed in and offers to sign another
  /// device in.
  reciprocate,
}

enum QrCodeFormat { msc4108, msc4388 }

enum QrCodeDecodeError {
  notEnoughData,
  invalidPrefix,
  invalidVersion,
  invalidIntent,
  notUtf8,
  urlParse,
  tooLarge,
}

class QrCodeDecodeException implements Exception {
  const QrCodeDecodeException(this.error);
  final QrCodeDecodeError error;
  @override
  String toString() => 'QrCodeDecodeException(${error.name})';
}

/// Decoded QR code login data. Raw strings are kept so that re-encoding is
/// byte-exact (URL parsers normalise).
class QrCodeData {
  QrCodeData.msc4108({
    required Uint8List publicKey,
    required this.rendezvousUrl,
    this.serverName,
  }) : format = QrCodeFormat.msc4108,
       intent = serverName == null
           ? QrCodeIntent.login
           : QrCodeIntent.reciprocate,
       publicKey = _key(publicKey),
       rendezvousId = null,
       baseUrl = null;

  QrCodeData.msc4388({
    required Uint8List publicKey,
    required this.intent,
    required String this.rendezvousId,
    required String this.baseUrl,
  }) : format = QrCodeFormat.msc4388,
       publicKey = _key(publicKey),
       rendezvousUrl = null,
       serverName = null;

  static const msc4108Prefix = 'MATRIX';
  static const msc4388Prefix = 'IO_ELEMENT_MSC4388';
  static const msc4108Version = 0x02;
  static const msc4388Type = 0x03;

  /// QR codes hold at most ~3 KB; anything larger is not ours.
  static const maxBytes = 4096;

  final QrCodeFormat format;
  final QrCodeIntent intent;

  /// The ephemeral Curve25519 public key of the device showing the code.
  final Uint8List publicKey;

  /// MSC4108: where the rendezvous session lives.
  final String? rendezvousUrl;

  /// MSC4108 reciprocate: the homeserver to sign in to. The MSC calls this a
  /// server name; Rust/Element X send a homeserver URL, Element Web sends the
  /// server name. Both are accepted.
  final String? serverName;

  /// MSC4388 only.
  final String? rendezvousId;
  final String? baseUrl;

  static Uint8List _key(Uint8List key) {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'publicKey', 'must be 32 bytes');
    }
    return Uint8List.fromList(key);
  }

  static QrCodeData decode(List<int> input) {
    if (input.length > maxBytes) {
      throw const QrCodeDecodeException(QrCodeDecodeError.tooLarge);
    }
    final reader = _Reader(Uint8List.fromList(input));
    if (_startsWith(input, ascii.encode(msc4108Prefix))) {
      reader.take(msc4108Prefix.length);
      final version = reader.byte();
      if (version != msc4108Version) {
        throw const QrCodeDecodeException(QrCodeDecodeError.invalidVersion);
      }
      final intent = switch (reader.byte()) {
        0x03 => QrCodeIntent.login,
        0x04 => QrCodeIntent.reciprocate,
        _ => throw const QrCodeDecodeException(QrCodeDecodeError.invalidIntent),
      };
      final key = reader.take(32);
      final url = reader.utf8String(reader.u16());
      _checkUrl(url);
      String? server;
      if (intent == QrCodeIntent.reciprocate) {
        server = reader.utf8String(reader.u16());
      }
      return QrCodeData.msc4108(
        publicKey: key,
        rendezvousUrl: url,
        serverName: server,
      );
    }
    if (_startsWith(input, ascii.encode(msc4388Prefix))) {
      reader.take(msc4388Prefix.length);
      if (reader.byte() != msc4388Type) {
        throw const QrCodeDecodeException(QrCodeDecodeError.invalidVersion);
      }
      final intent = switch (reader.byte()) {
        0x00 => QrCodeIntent.login,
        0x01 => QrCodeIntent.reciprocate,
        _ => throw const QrCodeDecodeException(QrCodeDecodeError.invalidIntent),
      };
      final key = reader.take(32);
      final id = reader.utf8String(reader.byte());
      final base = reader.utf8String(reader.byte());
      _checkUrl(base);
      return QrCodeData.msc4388(
        publicKey: key,
        intent: intent,
        rendezvousId: id,
        baseUrl: base,
      );
    }
    // Too short to even hold a prefix is "not enough data", like Rust.
    if (input.length < msc4108Prefix.length) {
      throw const QrCodeDecodeException(QrCodeDecodeError.notEnoughData);
    }
    throw const QrCodeDecodeException(QrCodeDecodeError.invalidPrefix);
  }

  /// Decodes bytes from a camera scanner. Scanners normally hand over the
  /// decoded byte segment; some return the raw QR data codewords instead
  /// (4-bit byte-mode indicator, 8- or 16-bit length, nibble-shifted data),
  /// which is unwrapped here as a fallback.
  static QrCodeData decodeScanned(List<int> scanned) {
    try {
      return decode(scanned);
    } on QrCodeDecodeException catch (e) {
      if (e.error != QrCodeDecodeError.invalidPrefix) rethrow;
      for (final countBits in [8, 16]) {
        final payload = unwrapQrByteSegment(scanned, countBits: countBits);
        if (payload == null) continue;
        try {
          return decode(payload);
        } on QrCodeDecodeException {
          continue;
        }
      }
      rethrow;
    }
  }

  static QrCodeData decodeBase64(String value) {
    final Uint8List bytes;
    try {
      bytes = decodeUnpaddedBase64(value.trim());
    } on FormatException {
      throw const QrCodeDecodeException(QrCodeDecodeError.invalidPrefix);
    }
    return decode(bytes);
  }

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    switch (format) {
      case QrCodeFormat.msc4108:
        out
          ..add(ascii.encode(msc4108Prefix))
          ..addByte(msc4108Version)
          ..addByte(intent == QrCodeIntent.login ? 0x03 : 0x04)
          ..add(publicKey);
        _addU16String(out, rendezvousUrl!);
        if (intent == QrCodeIntent.reciprocate) {
          _addU16String(out, serverName!);
        }
      case QrCodeFormat.msc4388:
        out
          ..add(ascii.encode(msc4388Prefix))
          ..addByte(msc4388Type)
          ..addByte(intent == QrCodeIntent.login ? 0x00 : 0x01)
          ..add(publicKey);
        _addU8String(out, rendezvousId!);
        _addU8String(out, baseUrl!);
    }
    return out.toBytes();
  }

  String encodeBase64() => encodeUnpaddedBase64(encode());

  static void _addU16String(BytesBuilder out, String value) {
    final bytes = utf8.encode(value);
    if (bytes.length > 0xffff) throw ArgumentError('Value too long');
    out
      ..addByte(bytes.length >> 8)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
  }

  static void _addU8String(BytesBuilder out, String value) {
    final bytes = utf8.encode(value);
    if (bytes.length > 0xff) throw ArgumentError('Value too long');
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }

  static bool _startsWith(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (data[i] != prefix[i]) return false;
    }
    return true;
  }

  static void _checkUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const QrCodeDecodeException(QrCodeDecodeError.urlParse);
    }
  }
}

class _Reader {
  _Reader(this.data);
  final Uint8List data;
  int offset = 0;

  Uint8List take(int count) {
    if (offset + count > data.length) {
      throw const QrCodeDecodeException(QrCodeDecodeError.notEnoughData);
    }
    final out = Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return Uint8List.fromList(out);
  }

  int byte() => take(1)[0];
  int u16() {
    final b = take(2);
    return (b[0] << 8) | b[1];
  }

  String utf8String(int length) {
    try {
      return utf8.decode(take(length));
    } on FormatException {
      throw const QrCodeDecodeException(QrCodeDecodeError.notUtf8);
    }
  }
}

/// Unpadded standard base64, as vodozemac encodes keys and ciphertexts.
String encodeUnpaddedBase64(List<int> bytes) =>
    base64.encode(bytes).replaceAll('=', '');

/// Accepts padded or unpadded standard base64.
Uint8List decodeUnpaddedBase64(String value) {
  if (value.isEmpty) return Uint8List(0);
  if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(value)) {
    throw const FormatException('Invalid base64');
  }
  final trimmed = value.replaceAll('=', '');
  final remainder = trimmed.length % 4;
  if (remainder == 1) throw const FormatException('Invalid base64 length');
  final padded = remainder == 0 ? trimmed : trimmed + '=' * (4 - remainder);
  return base64.decode(padded);
}

/// Extracts the data of a single byte-mode segment from raw QR codewords:
/// mode 0b0100, a [countBits]-bit length, then the data bytes, all packed
/// MSB first. Returns null when the codewords are not of that shape.
Uint8List? unwrapQrByteSegment(List<int> raw, {required int countBits}) {
  if (raw.isEmpty || raw[0] >> 4 != 0x4) return null;
  int bit(int index) => (raw[index >> 3] >> (7 - (index & 7))) & 1;
  int read(int offset, int bits) {
    var value = 0;
    for (var i = 0; i < bits; i++) {
      value = (value << 1) | bit(offset + i);
    }
    return value;
  }

  final totalBits = raw.length * 8;
  if (4 + countBits > totalBits) return null;
  final count = read(4, countBits);
  final start = 4 + countBits;
  if (count == 0 || start + count * 8 > totalBits) return null;
  return Uint8List.fromList([
    for (var i = 0; i < count; i++) read(start + i * 8, 8),
  ]);
}
