import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;

import '../../crypto_setup_policy.dart';
import '../../matrix_backend.dart';
import 'identity_trust.dart';
import 'recovery_key_rotation.dart';
import 'security_features.dart';
import 'security_policy.dart';

/// [SecurityFeatures] over the live SDK client. Reads use `sdkClient` and
/// re-check `isSessionCurrent` after every await; writes that touch the
/// encryption identity run inside [MatrixBackend.runCryptoMaintenance] so
/// sign-out, sign-in and sends wait for them.
class MatrixSecurity extends ChangeNotifier implements SecurityFeatures {
  MatrixSecurity(this._backend, {IdentityPinStorage? storage})
    : _storage = storage ?? const SharedPreferencesPinStorage();

  final MatrixBackend _backend;
  final IdentityPinStorage _storage;
  final _deferred = Expando<bool>('parallax.security.deferred');
  IdentityPinBook? _book;
  DateTime? _lastObservation;

  static const _maxRoomMembers = 500;
  static const _identityTypes = {
    matrix.EventTypes.CrossSigningMasterKey,
    matrix.EventTypes.CrossSigningSelfSigning,
    matrix.EventTypes.CrossSigningUserSigning,
  };

  @override
  Listenable get securityChanges => this;

  matrix.Client? get _client {
    final client = _backend.sdkClient;
    if (client == null ||
        client.userID == null ||
        !_backend.isSessionCurrent(client)) {
      return null;
    }
    return client;
  }

  matrix.Client _requireClient() =>
      _client ?? (throw StateError('Matrix session unavailable'));

  void _requireCurrent(matrix.Client client) {
    if (!_backend.isSessionCurrent(client)) {
      throw StateError('Matrix session changed');
    }
  }

  @override
  String? get sessionKey {
    final client = _client;
    return client == null
        ? null
        : '${client.homeserver}|${client.userID}|${client.deviceID}';
  }

  @override
  bool get encryptionAvailable {
    final client = _client;
    return client != null &&
        client.encryptionEnabled &&
        client.encryption != null;
  }

  @override
  bool get thisDeviceVerified {
    final client = _client;
    if (client == null || !client.encryptionEnabled) return false;
    try {
      return client.encryption?.crossSigning.isSelfSigned ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get verificationDeferred {
    final client = _client;
    return client != null && _deferred[client] == true;
  }

  @override
  void deferVerification() {
    final client = _client;
    if (client == null) return;
    _deferred[client] = true;
    notifyListeners();
  }

  // --- Session verification gate -------------------------------------------

  @override
  Future<SessionSecurityState> loadSessionState() async {
    final client = _client;
    if (client == null || !encryptionAvailable) {
      return const SessionSecurityState.unavailable();
    }
    final status = await _backend.cryptoStatus();
    _requireCurrent(client);
    final userId = client.userID!;
    final remote = await client.queryKeys({userId: []}, timeout: 10000);
    _requireCurrent(client);
    final remoteDevices = remote.deviceKeys?[userId];
    if (remote.failures?.isNotEmpty == true || remoteDevices == null) {
      throw StateError('Could not check this account’s identity');
    }
    // Best effort: refresh the local cache that signature chains use.
    await client.updateUserDeviceKeys(additionalUsers: {userId});
    _requireCurrent(client);
    final own = client.userDeviceKeys[userId];
    final verifiedOthers = remoteDevices.keys.where(
      (id) =>
          id != client.deviceID &&
          own?.deviceKeys[id]?.hasValidSignatureChain(
                verifiedByTheirMasterKey: true,
              ) ==
              true,
    );
    return SessionSecurityState(
      encryptionAvailable: true,
      accountHasIdentity: remote.masterKeys?.containsKey(userId) == true,
      deviceVerified: thisDeviceVerified,
      canUseAnotherDevice: verifiedOthers.isNotEmpty,
      canUseRecoveryKey: switch (status.setupAvailability) {
        CryptoSetupAvailability.restore ||
        CryptoSetupAvailability.repair ||
        CryptoSetupAvailability.connected => true,
        _ => false,
      },
      setupAvailability: status.setupAvailability,
    );
  }

  @override
  Future<void> startSelfVerification() async {
    final userId = _requireClient().userID!;
    await _backend.startVerification(userId);
  }

  @override
  Future<void> confirmWithRecoveryKey(String keyOrPassphrase) async {
    if (keyOrPassphrase.trim().isEmpty) {
      throw ArgumentError('Recovery key required');
    }
    final client = _requireClient();
    final status = await _backend.cryptoStatus();
    _requireCurrent(client);
    switch (status.setupAvailability) {
      case CryptoSetupAvailability.restore:
        await _backend.restoreCryptoIdentity(keyOrPassphrase);
      case CryptoSetupAvailability.repair:
        await _backend.repairCryptoIdentity(keyOrPassphrase);
      case CryptoSetupAvailability.connected:
        // Secrets are cached but this device is not signed (for example after
        // another device rotated the self-signing key). Prove the credential
        // matches the server identity before signing ourselves with it.
        await _backend.runCryptoMaintenance((client, current) async {
          await _backend.verifyRecoveryCredential(keyOrPassphrase);
          if (!current()) throw StateError('Matrix session changed');
          await client.encryption!.crossSigning.selfSign(
            keyOrPassphrase: keyOrPassphrase,
          );
        });
      case CryptoSetupAvailability.create ||
          CryptoSetupAvailability.needsSingleDevice ||
          CryptoSetupAvailability.blocked:
        throw StateError('Recovery is not available for this account');
    }
    _requireCurrent(client);
    notifyListeners();
  }

  // --- Identity pinning (TOFU) ---------------------------------------------

  IdentityPinBook? _bookFor(matrix.Client client) {
    final account = '${client.homeserver}|${client.userID}';
    var book = _book;
    if (book == null || book.account != account) {
      book?.close();
      book?.removeListener(notifyListeners);
      book = _book = IdentityPinBook(account, _storage)
        ..addListener(notifyListeners);
    }
    book.ensureLoaded();
    return book;
  }

  IdentitySnapshot _snapshot(matrix.Client client, String userId) {
    final key = client.userDeviceKeys[userId]?.masterKey;
    if (key == null || !key.isValid || key.blocked) {
      return const IdentitySnapshot(masterKey: null);
    }
    return IdentitySnapshot(
      masterKey: key.publicKey,
      verified: key.verified,
      pinned: key.trustOnFirstUseSince != null,
    );
  }

  @override
  void observeKnownIdentities() {
    final client = _client;
    if (client == null || !client.encryptionEnabled) return;
    final now = DateTime.now();
    final last = _lastObservation;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastObservation = now;
    final book = _bookFor(client);
    if (book == null) return;
    for (final userId in client.userDeviceKeys.keys.toList()) {
      if (userId == client.userID) continue;
      book.observe(userId, _snapshot(client, userId));
    }
  }

  @override
  UserTrust trustOf(String userId) {
    final client = _client;
    if (client == null || !client.encryptionEnabled) {
      return UserTrust(userId: userId, level: UserTrustLevel.unknown);
    }
    final current = _snapshot(client, userId);
    if (userId == client.userID) {
      return UserTrust(
        userId: userId,
        level: classifyIdentity(current, null),
        masterKey: current.masterKey,
      );
    }
    final book = _bookFor(client);
    final record = book?[userId];
    final level = classifyIdentity(current, record);
    book?.observe(userId, current);
    return UserTrust(
      userId: userId,
      level: level,
      masterKey: current.masterKey,
      previousMasterKey:
          level == UserTrustLevel.pinViolation ||
              level == UserTrustLevel.verificationViolation
          ? record?.masterKey
          : null,
    );
  }

  @override
  List<IdentityChange> identityChanges(String roomId) {
    final client = _client;
    if (client == null || !client.encryptionEnabled) return const [];
    final room = client.getRoomById(roomId);
    if (room == null || !room.encrypted) return const [];
    final book = _bookFor(client);
    if (book == null || !book.loaded) return const [];
    final changes = <IdentityChange>[];
    final members = room.getParticipants([
      matrix.Membership.join,
      matrix.Membership.invite,
    ]);
    for (final member in members.take(_maxRoomMembers)) {
      if (member.id == client.userID) continue;
      final trust = trustOf(member.id);
      if (!trust.isViolation) continue;
      changes.add(
        IdentityChange(
          userId: member.id,
          displayName: member.calcDisplayname(),
          trust: trust,
        ),
      );
    }
    changes.sort((a, b) {
      final critical =
          (b.trust.level == UserTrustLevel.verificationViolation ? 1 : 0) -
          (a.trust.level == UserTrustLevel.verificationViolation ? 1 : 0);
      return critical != 0 ? critical : a.userId.compareTo(b.userId);
    });
    return List.unmodifiable(changes);
  }

  @override
  Future<void> acknowledgeIdentityChange(
    String userId,
    String masterKey,
  ) async {
    final client = _requireClient();
    final key = client.userDeviceKeys[userId]?.masterKey;
    if (key == null || key.publicKey != masterKey) {
      throw StateError('This identity changed again. Review it first.');
    }
    await key.trustOnFirstUse();
    _requireCurrent(client);
    _bookFor(client)?.accept(userId, PinRecord(masterKey));
    notifyListeners();
  }

  @override
  Future<void> verifyUser(String userId) => _backend.startVerification(userId);

  // --- Key storage, recovery and reset -------------------------------------

  Future<bool> _serverBackupExists(matrix.Client client) async {
    try {
      await client.getRoomKeysVersionCurrent();
      return true;
    } on matrix.MatrixException catch (error) {
      if (error.error == matrix.MatrixError.M_NOT_FOUND) return false;
      rethrow;
    }
  }

  @override
  Future<SecurityOverview> loadOverview() async {
    final client = _requireClient();
    final status = await _backend.cryptoStatus();
    _requireCurrent(client);
    final serverBackup = await _serverBackupExists(client);
    _requireCurrent(client);
    final ssss = client.encryption?.ssss;
    final backupSecret =
        ssss?.isSecret(matrix.EventTypes.MegolmBackup) ?? false;
    return SecurityOverview(
      deviceVerified: thisDeviceVerified,
      keyStorage: serverBackup && backupSecret
          ? KeyStorageState.on
          : !serverBackup && !backupSecret
          ? KeyStorageState.off
          : KeyStorageState.incomplete,
      setupAvailability: status.setupAvailability,
      recoverySetUp: status.crossSigningEnabled,
    );
  }

  @override
  Future<void> enableKeyStorage(String keyOrPassphrase) async {
    final client = _requireClient();
    final status = await _backend.cryptoStatus();
    _requireCurrent(client);
    if (status.setupAvailability != CryptoSetupAvailability.repair) {
      throw StateError('Key storage cannot be turned on safely here');
    }
    // Repair creates only the missing backup and keeps every existing key.
    await _backend.repairCryptoIdentity(keyOrPassphrase);
  }

  @override
  Future<void> disableKeyStorage() => _backend.runCryptoMaintenance((
    client,
    current,
  ) async {
    String? version;
    try {
      version = (await client.getRoomKeysVersionCurrent()).version;
    } on matrix.MatrixException catch (error) {
      if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
    }
    if (!current()) throw StateError('Matrix session changed');
    if (version != null) await client.deleteRoomKeysVersion(version);
    if (!current()) throw StateError('Matrix session changed');
    final ssss = client.encryption!.ssss;
    if (ssss.isSecret(matrix.EventTypes.MegolmBackup)) {
      // Without the stored secret the SDK stops uploading and setup status
      // stays consistent (no secret for a missing backup).
      await client.setAccountData(
        client.userID!,
        matrix.EventTypes.MegolmBackup,
        {},
      );
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!ssss.isSecret(matrix.EventTypes.MegolmBackup)) break;
        await client.oneShotSync();
        if (!current()) throw StateError('Matrix session changed');
      }
      if (ssss.isSecret(matrix.EventTypes.MegolmBackup)) {
        throw StateError('Key storage removal is still syncing. Try again.');
      }
    }
    notifyListeners();
  });

  @override
  Future<RecoveryKeyChange> changeRecoveryKey({
    required String currentKeyOrPassphrase,
    required String newPassphrase,
  }) {
    if (currentKeyOrPassphrase.trim().isEmpty) {
      throw ArgumentError('Current recovery credential required');
    }
    if (newPassphrase.length < 32) {
      throw ArgumentError('A generated recovery phrase is required');
    }
    return _backend.runCryptoMaintenance((client, current) async {
      final status = await _backend.cryptoStatus();
      if (!current()) throw StateError('Matrix session changed');
      if (status.setupAvailability != CryptoSetupAvailability.connected &&
          status.setupAvailability != CryptoSetupAvailability.restore) {
        throw StateError('Recovery must be fully set up before changing it');
      }
      // Proves the credential unlocks the default key and that every stored
      // signing/backup secret matches the server before anything is written.
      await _backend.verifyRecoveryCredential(currentKeyOrPassphrase);
      if (!current()) throw StateError('Matrix session changed');
      final ssss = client.encryption!.ssss;
      final oldKeyId = ssss.defaultKeyId;
      if (oldKeyId == null) throw StateError('Recovery is not set up');
      final old = ssss.open(oldKeyId);
      await old.unlock(
        keyOrPassphrase: currentKeyOrPassphrase,
        postUnlock: false,
      );
      if (!current()) throw StateError('Matrix session changed');
      final writer = _MatrixSecretStorageWriter(ssss, old, newPassphrase);
      final outcome = await rotateSecretStorageKey(
        writer,
        requiredTypes: {
          ..._identityTypes,
          if (ssss.isSecret(matrix.EventTypes.MegolmBackup))
            matrix.EventTypes.MegolmBackup,
        },
        isCurrent: current,
      );
      final recoveryKey = writer.newKey?.recoveryKey;
      if (recoveryKey == null) throw StateError('New recovery key missing');
      return RecoveryKeyChange(
        recoveryKey: recoveryKey,
        oldKeyRetired: outcome == RotationOutcome.completed,
      );
    });
  }

  @override
  Future<String> resetIdentity({
    required String newPassphrase,
    String? password,
    required BrowserApproval approveInBrowser,
  }) {
    if (newPassphrase.length < 32) {
      throw ArgumentError('A generated recovery phrase is required');
    }
    return _backend.runCryptoMaintenance((client, current) async {
      var passwordTried = false;
      var prompts = 0;
      Future<void> answer(matrix.UiaRequest<dynamic> uia) async {
        try {
          if (++prompts > 4 || !current()) {
            uia.cancel(Exception('Identity reset was not authorised'));
            return;
          }
          final step = chooseResetAuthStep(
            stages: uia.nextStages,
            params: Map<String, Object?>.from(uia.params),
            session: uia.session,
            homeserver: client.homeserver ?? Uri(),
            hasPassword: password != null && password.isNotEmpty,
            passwordTried: passwordTried,
          );
          switch (step) {
            case PasswordAuthStep():
              passwordTried = true;
              await uia.completeStage(
                matrix.AuthenticationPassword(
                  session: uia.session,
                  password: password!,
                  identifier: matrix.AuthenticationUserIdentifier(
                    user: client.userID!,
                  ),
                ),
              );
            case BrowserAuthStep(:final url):
              final approved = await approveInBrowser(url);
              if (!approved || !current()) {
                uia.cancel(Exception('Identity reset was cancelled'));
                return;
              }
              await uia.completeStage(
                matrix.AuthenticationData(session: uia.session),
              );
            case UnsupportedAuthStep(:final reason):
              uia.cancel(Exception(reason));
          }
        } catch (error) {
          if (uia.state != matrix.UiaRequestState.done &&
              uia.state != matrix.UiaRequestState.fail) {
            uia.cancel(error is Exception ? error : Exception('$error'));
          }
        }
      }

      final subscription = client.onUiaRequest.stream.listen((uia) {
        if (uia.state == matrix.UiaRequestState.waitForUser) {
          unawaited(answer(uia));
        }
      });
      try {
        // Deliberately destructive: every wipe flag is true. The caller has
        // shown and confirmed the new phrase before this first write.
        final recoveryKey = await encryption.CryptoSetupExtension(client)
            .initCryptoIdentity(
              passphrase: newPassphrase,
              wipeSecureStorage: true,
              wipeKeyBackup: true,
              wipeCrossSigning: true,
              setupMasterKey: true,
              setupSelfSigningKey: true,
              setupUserSigningKey: true,
              setupOnlineKeyBackup: true,
            );
        if (!current()) throw StateError('Matrix session changed');
        notifyListeners();
        return recoveryKey;
      } finally {
        await subscription.cancel();
      }
    });
  }
}

class _MatrixSecretStorageWriter implements SecretStorageWriter {
  _MatrixSecretStorageWriter(this._ssss, this._old, this._newPassphrase);

  final encryption.SSSS _ssss;
  final encryption.OpenSSSS _old;
  final String _newPassphrase;
  encryption.OpenSSSS? newKey;

  encryption.OpenSSSS get _new =>
      newKey ?? (throw StateError('New key not created'));

  @override
  String? get defaultKeyId => _ssss.defaultKeyId;

  @override
  Map<String, Set<String>> encryptedSecrets() =>
      _ssss.analyzeEncryptedSecrets();

  @override
  Future<String> readWithOldKey(String type) => _old.getStored(type);

  @override
  Future<String> createNewKey() async {
    final key = await _ssss.createKey(_newPassphrase);
    newKey = key;
    return key.keyId;
  }

  @override
  Future<void> stage(String type, String secret) =>
      _new.store(type, secret, add: true);

  @override
  Future<String> readWithNewKey(String type) => _new.getStored(type);

  @override
  Future<void> commitDefault() => _ssss.setDefaultKeyId(_new.keyId);

  @override
  Future<void> retireOldCopies(String type, String secret) =>
      _new.validateAndStripOtherKeys(type, secret);
}
