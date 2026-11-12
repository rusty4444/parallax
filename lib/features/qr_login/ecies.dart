// ECIES secure channel used by MSC4108 QR code login.
//
// A byte-exact port of vodozemac 0.11.2 `src/ecies` (the version used by
// matrix-rust-sdk in Element X 26.11): X25519 key agreement, HKDF-SHA-512
// (no salt) with role-bound info strings, ChaCha20-Poly1305 with a 12-byte
// little-endian message counter as the nonce, and a two-digit check code.
//
// Device S ("initiator") scans the QR code; device G ("recipient") shows it.
// Info strings always list G's key first:
//   MATRIX_QR_CODE_LOGIN_ENCKEY_S|<Gp>|<Sp>  (key S encrypts with)
//   MATRIX_QR_CODE_LOGIN_ENCKEY_G|<Gp>|<Sp>  (key G encrypts with)
//   MATRIX_QR_CODE_LOGIN_CHECKCODE|<Gp>|<Sp> (2 bytes)
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'qr_code_data.dart' show decodeUnpaddedBase64, encodeUnpaddedBase64;

const eciesQrLoginInfo = 'MATRIX_QR_CODE_LOGIN';

class EciesException implements Exception {
  const EciesException(this.message);
  final String message;
  @override
  String toString() => 'EciesException: $message';
}

/// The out-of-band confirmation code (vodozemac `CheckCode`).
class CheckCode {
  CheckCode(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 2) throw ArgumentError('A check code has two bytes');
  }
  final Uint8List bytes;

  /// `to_digit(DigitMode::AllowLeadingZero)`, which MSC4108/ECIES uses.
  int get digits => (bytes[0] % 10) * 10 + bytes[1] % 10;

  /// Shown to people with a leading zero, like Element X and Element Web.
  String get display => digits.toString().padLeft(2, '0');

  @override
  bool operator ==(Object other) =>
      other is CheckCode &&
      other.bytes[0] == bytes[0] &&
      other.bytes[1] == bytes[1];
  @override
  int get hashCode => Object.hash(bytes[0], bytes[1]);
}

/// The first message S sends: ciphertext and S's ephemeral public key.
class EciesInitialMessage {
  EciesInitialMessage({required List<int> publicKey, required this.ciphertext})
    : publicKey = Uint8List.fromList(publicKey);
  final Uint8List publicKey;
  final Uint8List ciphertext;

  /// `base64(ciphertext)|base64(public key)`, both unpadded.
  String encode() =>
      '${encodeUnpaddedBase64(ciphertext)}|${encodeUnpaddedBase64(publicKey)}';

  static EciesInitialMessage decode(String value) {
    final separator = value.indexOf('|');
    if (separator < 0) throw const EciesException('Missing separator');
    try {
      final key = decodeUnpaddedBase64(value.substring(separator + 1));
      if (key.length != 32) throw const EciesException('Invalid public key');
      return EciesInitialMessage(
        publicKey: key,
        ciphertext: decodeUnpaddedBase64(value.substring(0, separator)),
      );
    } on FormatException {
      throw const EciesException('Invalid base64');
    }
  }
}

class EciesMessage {
  EciesMessage(this.ciphertext);
  final Uint8List ciphertext;
  String encode() => encodeUnpaddedBase64(ciphertext);
  static EciesMessage decode(String value) {
    try {
      return EciesMessage(decodeUnpaddedBase64(value.trim()));
    } on FormatException {
      throw const EciesException('Invalid base64');
    }
  }
}

enum EciesRole { initiator, recipient }

/// An unestablished ECIES session holding an ephemeral X25519 key pair.
class Ecies {
  Ecies._(this._keyPair, this.publicKey, this.info);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;
  final String info;

  static final _x25519 = X25519();

  /// A fresh random key pair. [seed] is only for deterministic tests.
  static Future<Ecies> create({
    List<int>? seed,
    String info = eciesQrLoginInfo,
  }) async {
    final keyPair = seed == null
        ? await _x25519.newKeyPair()
        : await _x25519.newKeyPairFromSeed(seed);
    final public = await keyPair.extractPublicKey();
    return Ecies._(keyPair, Uint8List.fromList(public.bytes), info);
  }

  Future<Uint8List> _sharedSecret(List<int> theirPublicKey) async {
    if (theirPublicKey.length != 32) {
      throw const EciesException('Invalid public key');
    }
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(
        List<int>.of(theirPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final bytes = Uint8List.fromList(await shared.extractBytes());
    // x25519-dalek `was_contributory`: reject low-order points.
    if (bytes.every((b) => b == 0)) {
      throw const EciesException('Non-contributory key');
    }
    return bytes;
  }

  /// S: establish towards G's public key from the QR code and encrypt the
  /// initial plaintext (nonce 0).
  Future<(EstablishedEcies, EciesInitialMessage)> establishOutbound(
    List<int> theirPublicKey,
    List<int> initialPlaintext,
  ) async {
    final secret = await _sharedSecret(theirPublicKey);
    final channel = await EstablishedEcies._derive(
      secret,
      ourPublicKey: publicKey,
      theirPublicKey: Uint8List.fromList(theirPublicKey),
      info: info,
      role: EciesRole.initiator,
    );
    final message = await channel.encrypt(initialPlaintext);
    return (
      channel,
      EciesInitialMessage(publicKey: publicKey, ciphertext: message.ciphertext),
    );
  }

  /// G: establish from S's initial message and decrypt it.
  Future<(EstablishedEcies, Uint8List)> establishInbound(
    EciesInitialMessage message,
  ) async {
    final secret = await _sharedSecret(message.publicKey);
    final channel = await EstablishedEcies._derive(
      secret,
      ourPublicKey: publicKey,
      theirPublicKey: message.publicKey,
      info: info,
      role: EciesRole.recipient,
    );
    final plaintext = await channel.decrypt(EciesMessage(message.ciphertext));
    return (channel, plaintext);
  }
}

/// An established ECIES session (vodozemac `EstablishedEcies`).
class EstablishedEcies {
  EstablishedEcies._(
    this._encryptionKey,
    this._decryptionKey, {
    required this.ourPublicKey,
    required this.theirPublicKey,
    required this.role,
    required this.checkCode,
  });

  final Uint8List ourPublicKey;
  final Uint8List theirPublicKey;
  final EciesRole role;
  final CheckCode checkCode;
  final SecretKey _encryptionKey;
  final SecretKey _decryptionKey;
  BigInt _encryptionCounter = BigInt.zero;
  BigInt _decryptionCounter = BigInt.zero;

  static final _aead = Chacha20.poly1305Aead();

  /// HKDF salt "None" in RustCrypto is HashLen (64) zero bytes.
  static final _zeroSalt = Uint8List(64);

  static Future<Uint8List> _expand(
    Uint8List secret,
    String info,
    int length,
  ) async {
    final hkdf = Hkdf(hmac: Hmac.sha512(), outputLength: length);
    final key = await hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: _zeroSalt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// `partial|Gp|Sp` with unpadded base64 keys (G is always first).
  static String infoString(
    String partial,
    EciesRole role,
    List<int> ourPublicKey,
    List<int> theirPublicKey,
  ) {
    final ours = encodeUnpaddedBase64(ourPublicKey);
    final theirs = encodeUnpaddedBase64(theirPublicKey);
    return role == EciesRole.recipient
        ? '$partial|$ours|$theirs'
        : '$partial|$theirs|$ours';
  }

  static Future<EstablishedEcies> _derive(
    Uint8List secret, {
    required Uint8List ourPublicKey,
    required Uint8List theirPublicKey,
    required String info,
    required EciesRole role,
  }) async {
    final initiator = role == EciesRole.initiator;
    String full(String partial) =>
        infoString(partial, role, ourPublicKey, theirPublicKey);
    final encryption = await _expand(
      secret,
      full(initiator ? '${info}_ENCKEY_S' : '${info}_ENCKEY_G'),
      32,
    );
    final decryption = await _expand(
      secret,
      full(initiator ? '${info}_ENCKEY_G' : '${info}_ENCKEY_S'),
      32,
    );
    final check = await _expand(secret, full('${info}_CHECKCODE'), 2);
    return EstablishedEcies._(
      SecretKey(encryption),
      SecretKey(decryption),
      ourPublicKey: ourPublicKey,
      theirPublicKey: theirPublicKey,
      role: role,
      checkCode: CheckCode(check),
    );
  }

  /// 12-byte nonce: the first 12 bytes of the u128 counter, little-endian.
  static Uint8List nonceFor(BigInt counter) {
    final nonce = Uint8List(12);
    var value = counter;
    for (var i = 0; i < 12; i++) {
      nonce[i] = (value & BigInt.from(0xff)).toInt();
      value = value >> 8;
    }
    return nonce;
  }

  Future<EciesMessage> encrypt(List<int> plaintext) async {
    final nonce = nonceFor(_encryptionCounter);
    _encryptionCounter += BigInt.one;
    final box = await _aead.encrypt(
      plaintext,
      secretKey: _encryptionKey,
      nonce: nonce,
    );
    return EciesMessage(
      Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }

  Future<Uint8List> decrypt(EciesMessage message) async {
    // vodozemac advances the counter even when decryption fails.
    final nonce = nonceFor(_decryptionCounter);
    _decryptionCounter += BigInt.one;
    final data = message.ciphertext;
    if (data.length < 16) throw const EciesException('Failed decrypting');
    try {
      final clear = await _aead.decrypt(
        SecretBox(
          data.sublist(0, data.length - 16),
          nonce: nonce,
          mac: Mac(data.sublist(data.length - 16)),
        ),
        secretKey: _decryptionKey,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const EciesException('Failed decrypting');
    }
  }
}
