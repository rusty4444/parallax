// m.login.secrets checks: derived public keys must match the server's
// identity, subkeys must be signed by the master key, and this device is
// signed with the self-signing key.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';
import 'package:parallax/features/qr_login/qr_secrets.dart';

List<int> _hex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _seed(int fill) => encodeUnpaddedBase64(List.filled(32, fill));

Future<Map<String, Object?>> _crossSigningKey(
  String userId,
  String usage,
  String private, {
  String? signedBy,
}) async {
  final public = await ed25519PublicKey(private);
  final key = <String, Object?>{
    'user_id': userId,
    'usage': [usage],
    'keys': {'ed25519:$public': public},
  };
  if (signedBy != null) {
    final signer = await ed25519PublicKey(signedBy);
    key['signatures'] = {
      userId: {'ed25519:$signer': await signJson(key, signedBy)},
    };
  }
  return key;
}

void main() {
  const user = '@sam:matrix.example';
  final master = _seed(1), selfSigning = _seed(2), userSigning = _seed(3);

  Future<QrServerIdentity> identity({
    String? masterPrivate,
    String? selfSigningSigner,
  }) async => QrServerIdentity(
    userId: user,
    masterKey: await _crossSigningKey(user, 'master', masterPrivate ?? master),
    selfSigningKey: await _crossSigningKey(
      user,
      'self_signing',
      selfSigning,
      signedBy: selfSigningSigner ?? master,
    ),
    userSigningKey: await _crossSigningKey(
      user,
      'user_signing',
      userSigning,
      signedBy: master,
    ),
  );

  test('Ed25519 from a seed matches RFC 8032 test 1', () async {
    final seed = encodeUnpaddedBase64(
      _hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'),
    );
    expect(
      _toHex(decodeUnpaddedBase64(await ed25519PublicKey(seed))),
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    );
  });

  test('canonical JSON sorts keys and drops whitespace', () {
    expect(
      canonicalJson({
        'b': 1,
        'a': [true, null, 'x/é'],
        'c': {'z': 0, 'y': '"'},
      }),
      '{"a":[true,null,"x/é"],"b":1,"c":{"y":"\\"","z":0}}',
    );
    expect(
      signingContent({
        'a': 1,
        'signatures': {'x': 1},
        'unsigned': {'y': 2},
      }),
      '{"a":1}',
    );
    expect(() => canonicalJson({'a': 1.5}), throwsA(isA<QrSecretsException>()));
  });

  test('accepts secrets that match the published identity', () async {
    await verifyCrossSigningSecrets(
      identity: await identity(),
      masterPrivate: master,
      selfSigningPrivate: selfSigning,
      userSigningPrivate: userSigning,
    );
  });

  test('rejects secrets for another identity', () async {
    await expectLater(
      verifyCrossSigningSecrets(
        identity: await identity(masterPrivate: _seed(9)),
        masterPrivate: master,
        selfSigningPrivate: selfSigning,
        userSigningPrivate: userSigning,
      ),
      throwsA(isA<QrSecretsException>()),
    );
    await expectLater(
      verifyCrossSigningSecrets(
        identity: await identity(),
        masterPrivate: master,
        selfSigningPrivate: userSigning,
        userSigningPrivate: selfSigning,
      ),
      throwsA(isA<QrSecretsException>()),
    );
  });

  test('rejects a subkey not signed by the current master', () async {
    await expectLater(
      verifyCrossSigningSecrets(
        identity: await identity(selfSigningSigner: _seed(7)),
        masterPrivate: master,
        selfSigningPrivate: selfSigning,
        userSigningPrivate: userSigning,
      ),
      throwsA(isA<QrSecretsException>()),
    );
  });

  test('signs this device with the self-signing key', () async {
    final device = <String, Object?>{
      'user_id': user,
      'device_id': 'NEWDEVICE',
      'algorithms': ['m.olm.v1.curve25519-aes-sha2', 'm.megolm.v1.aes-sha2'],
      'keys': {'curve25519:NEWDEVICE': 'curve', 'ed25519:NEWDEVICE': 'edkey'},
      'signatures': {
        user: {'ed25519:NEWDEVICE': 'self-signature'},
      },
      'unsigned': {'device_display_name': 'Parallax'},
    };
    final payload = await deviceSignaturePayload(
      userId: user,
      deviceId: 'NEWDEVICE',
      deviceKeys: device,
      selfSigningPrivate: selfSigning,
    );
    final signed = payload[user]!['NEWDEVICE']!;
    expect(signed.containsKey('unsigned'), isFalse);
    expect(
      await verifyJsonSignature(
        signed,
        userId: user,
        publicKey: await ed25519PublicKey(selfSigning),
      ),
      isTrue,
    );
    // The signed content is the device keys without signatures/unsigned.
    expect(signingContent(signed), signingContent(device));
    expect(jsonEncode(payload), isNot(contains(selfSigning)));
  });

  test('backup public key derivation is X25519', () async {
    // The all-zero private scalar (Rust test bundle) has a fixed public key.
    final public = await curve25519PublicKey(
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(decodeUnpaddedBase64(public), hasLength(32));
    expect(
      await curve25519PublicKey(_seed(5)),
      isNot(await curve25519PublicKey(_seed(6))),
    );
  });
}
