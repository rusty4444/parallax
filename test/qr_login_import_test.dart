// Importing m.login.secrets into the Matrix SDK 14.1 client: everything is
// verified against /keys/query before secrets are cached or this device is
// signed. The SDK boundaries (keys query, signature upload, SSSS cache
// writes, backup version) are faked; native crypto is not involved.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart' as crypto;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/qr_login/matrix_qr_login.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';
import 'package:parallax/features/qr_login/qr_messages.dart';
import 'package:parallax/features/qr_login/qr_secrets.dart';

const _user = '@sam:matrix.example';
const _device = 'NEWDEVICE';

String _seed(int fill) => encodeUnpaddedBase64(List.filled(32, fill));

class _Database implements matrix.DatabaseApi {
  final cached = <String, (String, String, String)>{};
  @override
  Future<void> storeSSSSCache(
    String type,
    String keyId,
    String ciphertext,
    String content,
  ) async => cached[type] = (keyId, ciphertext, content);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ssss implements crypto.SSSS {
  @override
  String? keyIdFromType(String type) => 'KEY';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Encryption implements crypto.Encryption {
  @override
  final crypto.SSSS ssss = _Ssss();
  @override
  String get fingerprintKey => 'ed-key';
  @override
  String get identityKey => 'curve-key';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends matrix.Client {
  _Client(this.db)
    : super(
        'import-test',
        database: db,
        httpClient: MockClient((_) async => http.Response('{}', 404)),
      );
  final _Database db;
  final _crypto = _Encryption();
  late Map<String, Object?> keys;
  Map<String, Object?>? backup;
  final uploads = <Map<String, Map<String, Map<String, Object?>>>>[];
  int keyUpdates = 0;

  @override
  String? get userID => _user;
  @override
  String? get deviceID => _device;
  @override
  crypto.Encryption? get encryption => _crypto;
  @override
  Future<void> oneShotSync({Duration? timeout}) async {}
  @override
  Future<matrix.QueryKeysResponse> queryKeys(
    Map<String, List<String>> deviceKeys, {
    int? timeout,
  }) async => matrix.QueryKeysResponse.fromJson(
    jsonDecode(jsonEncode(keys)) as Map<String, Object?>,
  );
  @override
  Future<matrix.GetRoomKeysVersionCurrentResponse>
  getRoomKeysVersionCurrent() async {
    if (backup == null) {
      throw matrix.MatrixException.fromJson({
        'errcode': 'M_NOT_FOUND',
        'error': 'No backup',
      });
    }
    return matrix.GetRoomKeysVersionCurrentResponse.fromJson(backup!);
  }

  @override
  Future<Map<String, Map<String, Map<String, Object?>>>?>
  uploadCrossSigningSignatures(
    Map<String, Map<String, Map<String, Object?>>> body,
  ) async {
    uploads.add(body);
    return {};
  }

  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    keyUpdates++;
  }
}

Future<Map<String, Object?>> _signingKey(
  String usage,
  String private, {
  String? signedBy,
}) async {
  final public = await ed25519PublicKey(private);
  final key = <String, Object?>{
    'user_id': _user,
    'usage': [usage],
    'keys': {'ed25519:$public': public},
  };
  if (signedBy != null) {
    key['signatures'] = {
      _user: {
        'ed25519:${await ed25519PublicKey(signedBy)}': await signJson(
          key,
          signedBy,
        ),
      },
    };
  }
  return key;
}

void main() {
  final master = _seed(1), selfSigning = _seed(2), userSigning = _seed(3);
  final backupKey = _seed(4);
  late _Database db;
  late _Client client;

  final deviceKeys = <String, Object?>{
    'user_id': _user,
    'device_id': _device,
    'algorithms': ['m.olm.v1.curve25519-aes-sha2', 'm.megolm.v1.aes-sha2'],
    'keys': {'curve25519:$_device': 'curve-key', 'ed25519:$_device': 'ed-key'},
    'signatures': {
      _user: {'ed25519:$_device': 'device-self-signature'},
    },
  };

  setUp(() async {
    db = _Database();
    client = _Client(db);
    client.keys = {
      'device_keys': {
        _user: {_device: deviceKeys},
      },
      'master_keys': {_user: await _signingKey('master', master)},
      'self_signing_keys': {
        _user: await _signingKey('self_signing', selfSigning, signedBy: master),
      },
      'user_signing_keys': {
        _user: await _signingKey('user_signing', userSigning, signedBy: master),
      },
      'failures': <String, Object?>{},
    };
    client.backup = {
      'algorithm': 'm.megolm_backup.v1.curve25519-aes-sha2',
      'auth_data': {'public_key': await curve25519PublicKey(backupKey)},
      'count': 3,
      'etag': '1',
      'version': '7',
    };
    for (final type in [
      matrix.EventTypes.CrossSigningSelfSigning,
      matrix.EventTypes.CrossSigningUserSigning,
      matrix.EventTypes.MegolmBackup,
    ]) {
      client.accountData[type] = matrix.BasicEvent(
        type: type,
        content: {
          'encrypted': {
            'KEY': {'ciphertext': 'ct-$type', 'iv': 'iv', 'mac': 'mac'},
          },
        },
      );
    }
  });

  QrSecretsBundle bundle({String? masterKey, String version = '7'}) =>
      QrSecretsBundle(
        masterKey: masterKey ?? master,
        selfSigningKey: selfSigning,
        userSigningKey: userSigning,
        backup: QrBackupSecret(key: backupKey, version: version),
      );

  test('verifies, caches secrets and signs this device', () async {
    await importQrSecretsBundle(client, bundle(), () => true);
    expect(db.cached[matrix.EventTypes.CrossSigningSelfSigning], (
      'KEY',
      'ct-${matrix.EventTypes.CrossSigningSelfSigning}',
      selfSigning,
    ));
    expect(
      db.cached[matrix.EventTypes.CrossSigningUserSigning]!.$3,
      userSigning,
    );
    expect(db.cached[matrix.EventTypes.MegolmBackup]!.$3, backupKey);
    // The master key itself is never cached (the SDK does not either).
    expect(db.cached.keys, hasLength(3));

    final signed = client.uploads.single[_user]![_device]!;
    expect(
      await verifyJsonSignature(
        signed,
        userId: _user,
        publicKey: await ed25519PublicKey(selfSigning),
      ),
      isTrue,
    );
    expect(jsonEncode(client.uploads), isNot(contains(selfSigning)));
    expect(client.keyUpdates, 1);
  });

  test('a backup key for another version is not cached', () async {
    await importQrSecretsBundle(client, bundle(version: '6'), () => true);
    expect(db.cached.containsKey(matrix.EventTypes.MegolmBackup), isFalse);
    expect(client.uploads, hasLength(1));
  });

  test('secrets for another identity are refused before any write', () async {
    await expectLater(
      importQrSecretsBundle(client, bundle(masterKey: _seed(9)), () => true),
      throwsA(isA<QrSecretsException>()),
    );
    expect(db.cached, isEmpty);
    expect(client.uploads, isEmpty);
  });

  test('a server device key that is not ours is never signed', () async {
    (((client.keys['device_keys'] as Map)[_user] as Map)[_device]
        as Map)['keys'] = {
      'curve25519:$_device': 'curve-key',
      'ed25519:$_device': 'other',
    };
    await expectLater(
      importQrSecretsBundle(client, bundle(), () => true),
      throwsA(isA<QrSecretsException>()),
    );
    expect(client.uploads, isEmpty);
  });

  test('stops when the session changes', () async {
    var calls = 0;
    await expectLater(
      importQrSecretsBundle(client, bundle(), () => ++calls < 2),
      throwsStateError,
    );
    expect(client.uploads, isEmpty);
  });
}
