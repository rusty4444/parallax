// Matrix SDK 14.1 implementation of the QR login module.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../matrix_auth_service.dart';
import '../../matrix_backend.dart';
import '../security/security_ui.dart' show openExternalHttpsUrl;
import 'qr_code_data.dart' show decodeUnpaddedBase64, encodeUnpaddedBase64;
import 'qr_grant_flow.dart';
import 'qr_login_features.dart';
import 'qr_login_flow.dart';
import 'qr_messages.dart';
import 'qr_secrets.dart';
import 'rendezvous.dart';

class MatrixQrLogin implements QrLoginFeatures, QrLoginAccount {
  MatrixQrLogin(this.backend);
  final MatrixBackend backend;

  matrix.Client? get _client => backend.sdkClient;

  @override
  bool get canSignInWithQrCode {
    final client = _client;
    return client != null &&
        backend.connection == SessionStatus.signedOut &&
        !client.isLogged() &&
        client.userID == null &&
        !backend.deviceAuthorizationLoginBusy;
  }

  @override
  QrLoginAccount get loginAccount => this;

  @override
  http.Client newRendezvousClient() => http.Client();

  @override
  Future<void> signInWithDeviceAuthorization(
    String serverNameOrUrl, {
    required Future<void> Function(DeviceAuthorizationGrant grant) onGrant,
    required Future<void> Function() afterCommit,
    required QrCancellation cancellation,
  }) => backend.loginWithDeviceAuthorization(
    serverNameOrUrl,
    onGrant: onGrant,
    afterCommit: afterCommit,
    cancelled: cancellation.whenCancelled,
  );

  @override
  Future<void> importSecrets(QrSecretsBundle bundle) =>
      backend.runCryptoMaintenance(
        (client, current) => importQrSecretsBundle(client, bundle, current),
      );

  // --- Link new device ----------------------------------------------------

  @override
  bool get canLinkNewDevice {
    final client = _client;
    return client != null &&
        backend.connection == SessionStatus.ready &&
        client.isLogged() &&
        client.encryptionEnabled &&
        client.homeserver != null;
  }

  @override
  Future<QrSecretsBundle> exportSecrets(String recoveryKeyOrPassphrase) =>
      exportQrSecretsBundle(backend, recoveryKeyOrPassphrase);

  @override
  QrGrantAccount? grantAccount() {
    final client = _client;
    final homeserver = client?.homeserver;
    if (client == null || homeserver == null || !canLinkNewDevice) {
      return null;
    }
    return _MatrixGrantAccount(backend, client, homeserver);
  }
}

class _MatrixGrantAccount implements QrGrantAccount {
  _MatrixGrantAccount(this.backend, this.client, this.homeserver)
    : user = client.userID;
  final MatrixBackend backend;
  final matrix.Client client;
  @override
  final Uri homeserver;
  final String? user;

  void _check() {
    if (!backend.isSessionCurrent(client) || client.userID != user) {
      throw StateError('Matrix session changed');
    }
  }

  @override
  Future<bool> deviceExists(String deviceId) async {
    _check();
    try {
      await client.getDevice(deviceId);
      _check();
      return true;
    } on matrix.MatrixException catch (e) {
      _check();
      if (e.response?.statusCode == 404 ||
          e.error == matrix.MatrixError.M_NOT_FOUND) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<bool> openVerificationUri(Uri uri) => openExternalHttpsUrl(uri);

  /// The approval URL comes from the new device. Only accept it on this
  /// account's own authorization server, so a malicious device cannot send
  /// the user to a look-alike page.
  @override
  Future<bool> trustsVerificationUri(Uri uri) async {
    _check();
    Map<String, Object?>? metadata;
    for (final path in [
      '/client/v1/auth_metadata',
      '/client/unstable/org.matrix.msc2965/auth_metadata',
    ]) {
      try {
        metadata = await client.request(matrix.RequestType.GET, path);
        break;
      } on matrix.MatrixException {
        continue;
      }
    }
    _check();
    final trusted = [
      for (final field in [
        'issuer',
        'authorization_endpoint',
        'device_authorization_endpoint',
      ])
        if (Uri.tryParse('${metadata?[field]}') case final Uri parsed
            when parsed.scheme == 'https' && parsed.host.isNotEmpty)
          parsed,
    ];
    return isTrustedVerificationUri(uri, trusted);
  }
}

/// The device authorization URL must be HTTPS on the account provider's
/// own host (its issuer or OAuth endpoints).
bool isTrustedVerificationUri(Uri uri, List<Uri> provider) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.fragment.isEmpty &&
    provider.any(
      (trusted) =>
          trusted.host.toLowerCase() == uri.host.toLowerCase() &&
          trusted.port == uri.port,
    );

/// Exports the cross-signing and backup secrets for `m.login.secrets`. The
/// SDK keeps only the self/user-signing keys cached, so secret storage is
/// unlocked with the recovery key to read the master key; every secret is
/// checked against the server identity before it leaves this device.
Future<QrSecretsBundle> exportQrSecretsBundle(
  MatrixBackend backend,
  String recoveryKeyOrPassphrase,
) => backend.runCryptoMaintenance((client, current) async {
  final userId = client.userID!;
  final ssss = client.encryption!.ssss;
  final keyId = ssss.defaultKeyId;
  if (keyId == null) throw const QrSecretsException('No secret storage');
  // Every secret read below is checked against the server identity
  // (verifyCrossSigningSecrets, backup public key) before it is shared.
  final open = ssss.open(keyId);
  await open.unlock(
    keyOrPassphrase: recoveryKeyOrPassphrase,
    postUnlock: false,
  );
  Future<String> stored(String type) async =>
      encodeUnpaddedBase64(decodeUnpaddedBase64(await open.getStored(type)));
  final master = await stored(matrix.EventTypes.CrossSigningMasterKey);
  final selfSigning = await stored(matrix.EventTypes.CrossSigningSelfSigning);
  final userSigning = await stored(matrix.EventTypes.CrossSigningUserSigning);
  if (!current()) throw StateError('Matrix session changed');
  final identity = await _serverIdentity(client, userId);
  await verifyCrossSigningSecrets(
    identity: identity,
    masterPrivate: master,
    selfSigningPrivate: selfSigning,
    userSigningPrivate: userSigning,
  );
  QrBackupSecret? backup;
  if (ssss.isSecret(matrix.EventTypes.MegolmBackup)) {
    final key = await stored(matrix.EventTypes.MegolmBackup);
    final version = await client.getRoomKeysVersionCurrent();
    if (!current()) throw StateError('Matrix session changed');
    if (version.algorithm ==
            matrix.BackupAlgorithm.mMegolmBackupV1Curve25519AesSha2 &&
        version.authData['public_key'] == await curve25519PublicKey(key)) {
      backup = QrBackupSecret(key: key, version: version.version);
    }
  }
  return QrSecretsBundle(
    masterKey: master,
    selfSigningKey: selfSigning,
    userSigningKey: userSigning,
    backup: backup,
  );
});

Future<QrServerIdentity> _serverIdentity(
  matrix.Client client,
  String userId,
) async =>
    _identityFrom(await client.queryKeys({userId: []}, timeout: 10000), userId);

QrServerIdentity _identityFrom(matrix.QueryKeysResponse keys, String userId) {
  final master = keys.masterKeys?[userId];
  final selfSigning = keys.selfSigningKeys?[userId];
  final userSigning = keys.userSigningKeys?[userId];
  if (keys.failures?.isNotEmpty == true ||
      master == null ||
      selfSigning == null ||
      userSigning == null) {
    throw const QrSecretsException('Could not read the account identity');
  }
  Map<String, Object?> copy(Object json) =>
      jsonDecode(jsonEncode(json)) as Map<String, Object?>;
  return QrServerIdentity(
    userId: userId,
    masterKey: copy(master.toJson()),
    selfSigningKey: copy(selfSigning.toJson()),
    userSigningKey: copy(userSigning.toJson()),
  );
}

/// Imports `m.login.secrets` on the new device (matrix-rust-sdk
/// `import_secrets_bundle` + device key signing): verifies the keys against
/// the published identity, signs this device with the self-signing key,
/// trusts our master key locally and caches the secrets so the SDK can
/// cross-sign and read the key backup.
Future<void> importQrSecretsBundle(
  matrix.Client client,
  QrSecretsBundle bundle,
  bool Function() current,
) async {
  void check() {
    if (!current()) throw StateError('Matrix session changed');
  }

  final userId = client.userID!;
  final deviceId = client.deviceID!;
  // Account data (secret storage) arrives with the first sync.
  await client
      .oneShotSync(timeout: Duration.zero)
      .timeout(const Duration(seconds: 60));
  await client.accountDataLoading;
  check();

  // Our device keys are uploaded during Client.init; allow for lag.
  matrix.MatrixDeviceKeys? ownKeys;
  QrServerIdentity? identity;
  for (var attempt = 0; attempt < 5 && ownKeys == null; attempt++) {
    if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 1));
    final keys = await client.queryKeys({userId: []}, timeout: 10000);
    check();
    ownKeys = keys.deviceKeys?[userId]?[deviceId];
    identity = _identityFrom(keys, userId);
  }
  if (ownKeys == null ||
      ownKeys.keys['ed25519:$deviceId'] != client.fingerprintKey ||
      ownKeys.keys['curve25519:$deviceId'] != client.identityKey) {
    throw const QrSecretsException('This device has not published its keys');
  }
  await verifyCrossSigningSecrets(
    identity: identity!,
    masterPrivate: bundle.masterKey,
    selfSigningPrivate: bundle.selfSigningKey,
    userSigningPrivate: bundle.userSigningKey,
  );
  check();

  // Cache the secrets the SDK keeps (self/user-signing, backup), keyed to the
  // current secret-storage ciphertexts like an SSSS secret share.
  final ssss = client.encryption!.ssss;
  Future<void> cache(String type, String secret) async {
    final keyId = ssss.keyIdFromType(type);
    final encrypted = client.accountData[type]?.content['encrypted'];
    final entry = encrypted is Map && keyId != null ? encrypted[keyId] : null;
    final ciphertext = entry is Map ? entry['ciphertext'] : null;
    if (keyId == null || ciphertext is! String) return;
    await client.database.storeSSSSCache(type, keyId, ciphertext, secret);
  }

  await cache(matrix.EventTypes.CrossSigningSelfSigning, bundle.selfSigningKey);
  await cache(matrix.EventTypes.CrossSigningUserSigning, bundle.userSigningKey);
  final backup = bundle.backup;
  if (backup != null) {
    try {
      final version = await client.getRoomKeysVersionCurrent();
      check();
      if (version.version == backup.version &&
          version.algorithm ==
              matrix.BackupAlgorithm.mMegolmBackupV1Curve25519AesSha2 &&
          version.authData['public_key'] ==
              await curve25519PublicKey(backup.key)) {
        await cache(matrix.EventTypes.MegolmBackup, backup.key);
      }
    } on matrix.MatrixException {
      // No server backup: nothing to connect to.
    }
  }
  check();

  // Sign this device with the self-signing key (as Rust's device key
  // upload does once the private key is known).
  final payload = await deviceSignaturePayload(
    userId: userId,
    deviceId: deviceId,
    deviceKeys:
        jsonDecode(jsonEncode(ownKeys.toJson())) as Map<String, Object?>,
    selfSigningPrivate: bundle.selfSigningKey,
  );
  check();
  final failures = await client.uploadCrossSigningSignatures(payload);
  check();
  if (failures?[userId]?.containsKey(deviceId) == true) {
    throw const QrSecretsException('The server rejected the signature');
  }

  // Trust our own identity locally and refresh the cached keys so the app
  // sees this device as verified right away.
  final ownList = client.userDeviceKeys[userId];
  if (ownList != null) ownList.outdated = true;
  await client.updateUserDeviceKeys();
  check();
  final masterKey = client.userDeviceKeys[userId]?.masterKey;
  if (masterKey != null &&
      masterKey.ed25519Key == crossSigningPublicKey(identity.masterKey)) {
    await masterKey.setVerified(true, false);
  }
}
