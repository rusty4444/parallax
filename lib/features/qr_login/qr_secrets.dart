// Verification and signing for the `m.login.secrets` bundle.
//
// Pure Dart (package:cryptography) so the checks are testable without the
// native vodozemac library: Ed25519 public keys derived from the private
// cross-signing seeds must match the server's identity, the self-signing
// and user-signing keys must carry the master key's signature, and this
// device's keys are then signed with the self-signing key exactly as
// matrix-rust-sdk does after `import_secrets_bundle`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'qr_code_data.dart' show decodeUnpaddedBase64, encodeUnpaddedBase64;

class QrSecretsException implements Exception {
  const QrSecretsException(this.message);
  final String message;
  @override
  String toString() => 'QrSecretsException: $message';
}

/// Matrix canonical JSON (sorted keys, no whitespace, integers only).
String canonicalJson(Object? value) {
  final out = StringBuffer();
  void write(Object? v) {
    switch (v) {
      case null:
        out.write('null');
      case bool():
        out.write(v ? 'true' : 'false');
      case int():
        out.write(v);
      case String():
        out.write(jsonEncode(v));
      case List():
        out.write('[');
        for (var i = 0; i < v.length; i++) {
          if (i > 0) out.write(',');
          write(v[i]);
        }
        out.write(']');
      case Map():
        final keys = v.keys.map((k) => k as String).toList()..sort();
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          out
            ..write(jsonEncode(keys[i]))
            ..write(':');
          write(v[keys[i]]);
        }
        out.write('}');
      default:
        throw const QrSecretsException('Not canonical JSON');
    }
  }

  write(value);
  return out.toString();
}

/// The JSON that is signed: everything but `signatures` and `unsigned`.
String signingContent(Map<String, Object?> json) => canonicalJson({
  for (final entry in json.entries)
    if (entry.key != 'signatures' && entry.key != 'unsigned')
      entry.key: entry.value,
});

final _ed25519 = Ed25519();

Uint8List _seed(String base64Key) {
  final Uint8List bytes;
  try {
    bytes = decodeUnpaddedBase64(base64Key);
  } on FormatException {
    throw const QrSecretsException('Invalid key encoding');
  }
  if (bytes.length != 32) throw const QrSecretsException('Invalid key');
  return bytes;
}

/// Ed25519 public key (unpadded base64) of a cross-signing private seed.
Future<String> ed25519PublicKey(String privateSeed) async {
  final pair = await _ed25519.newKeyPairFromSeed(_seed(privateSeed));
  return encodeUnpaddedBase64((await pair.extractPublicKey()).bytes);
}

/// Curve25519 public key of the megolm backup private key.
Future<String> curve25519PublicKey(String privateKey) async {
  final pair = await X25519().newKeyPairFromSeed(_seed(privateKey));
  return encodeUnpaddedBase64((await pair.extractPublicKey()).bytes);
}

Future<String> signJson(Map<String, Object?> json, String privateSeed) async {
  final pair = await _ed25519.newKeyPairFromSeed(_seed(privateSeed));
  final signature = await _ed25519.sign(
    utf8.encode(signingContent(json)),
    keyPair: pair,
  );
  return encodeUnpaddedBase64(signature.bytes);
}

Future<bool> verifyJsonSignature(
  Map<String, Object?> json, {
  required String userId,
  required String publicKey,
}) async {
  final signatures = json['signatures'];
  final mine = signatures is Map ? signatures[userId] : null;
  final signature = mine is Map ? mine['ed25519:$publicKey'] : null;
  if (signature is! String) return false;
  try {
    return await _ed25519.verify(
      utf8.encode(signingContent(json)),
      signature: Signature(
        decodeUnpaddedBase64(signature),
        publicKey: SimplePublicKey(
          decodeUnpaddedBase64(publicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
  } catch (_) {
    return false;
  }
}

/// The single Ed25519 public key in a cross-signing key object.
String? crossSigningPublicKey(Map<String, Object?> key) {
  final keys = key['keys'];
  if (keys is! Map || keys.length != 1) return null;
  final value = keys.values.single;
  return value is String ? value : null;
}

/// Server identity the bundle must match (from an authoritative
/// `/keys/query`).
class QrServerIdentity {
  const QrServerIdentity({
    required this.userId,
    required this.masterKey,
    required this.selfSigningKey,
    required this.userSigningKey,
  });
  final String userId;
  final Map<String, Object?> masterKey;
  final Map<String, Object?> selfSigningKey;
  final Map<String, Object?> userSigningKey;
}

/// Checks the received private keys against the account's published
/// identity before anything is trusted or stored.
Future<void> verifyCrossSigningSecrets({
  required QrServerIdentity identity,
  required String masterPrivate,
  required String selfSigningPrivate,
  required String userSigningPrivate,
}) async {
  final master = crossSigningPublicKey(identity.masterKey);
  final selfSigning = crossSigningPublicKey(identity.selfSigningKey);
  final userSigning = crossSigningPublicKey(identity.userSigningKey);
  if (master == null || selfSigning == null || userSigning == null) {
    throw const QrSecretsException('The account has no complete identity');
  }
  if (await ed25519PublicKey(masterPrivate) != master ||
      await ed25519PublicKey(selfSigningPrivate) != selfSigning ||
      await ed25519PublicKey(userSigningPrivate) != userSigning) {
    throw const QrSecretsException('The secrets do not match this account');
  }
  for (final subkey in [identity.selfSigningKey, identity.userSigningKey]) {
    if (!await verifyJsonSignature(
      subkey,
      userId: identity.userId,
      publicKey: master,
    )) {
      throw const QrSecretsException('The signing chain is not valid');
    }
  }
}

/// The `/keys/signatures/upload` body that signs [deviceKeys] with the
/// self-signing key.
Future<Map<String, Map<String, Map<String, Object?>>>> deviceSignaturePayload({
  required String userId,
  required String deviceId,
  required Map<String, Object?> deviceKeys,
  required String selfSigningPrivate,
}) async {
  final selfSigningPublic = await ed25519PublicKey(selfSigningPrivate);
  final signature = await signJson(deviceKeys, selfSigningPrivate);
  final signed = Map<String, Object?>.of(deviceKeys)..remove('unsigned');
  signed['signatures'] = {
    userId: {'ed25519:$selfSigningPublic': signature},
  };
  return {
    userId: {deviceId: signed},
  };
}
