import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/security/security_features.dart';

/// Minimal backend: only what the security UI touches is implemented.
class SecurityTestBackend extends ChatBackend {
  String? user = '@me:example.org';
  SessionStatus status = SessionStatus.ready;
  final createdPhrases = <String>[];

  @override
  String? get userId => user;
  @override
  SessionStatus get connection => status;
  @override
  VerificationDetails? get verification => null;
  @override
  TrustWarning? get trustWarning => null;

  @override
  Future<CryptoStatus> cryptoStatus() async => const CryptoStatus(
    initialized: false,
    connected: false,
    keyBackupEnabled: false,
    crossSigningEnabled: false,
    setupAvailability: CryptoSetupAvailability.create,
  );

  @override
  Future<CryptoSetupResult> createCryptoIdentity(String phrase) async {
    createdPhrases.add(phrase);
    return const CryptoSetupResult(recoveryKey: 'EsTc fake key', ready: true);
  }

  void ping() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSecurity extends ChangeNotifier implements SecurityFeatures {
  String? session = 'session-1';
  bool encryption = true;
  bool verified = false;
  bool deferred = false;
  SessionSecurityState? state = const SessionSecurityState(
    encryptionAvailable: true,
    accountHasIdentity: true,
    deviceVerified: false,
    canUseAnotherDevice: true,
    canUseRecoveryKey: true,
    setupAvailability: CryptoSetupAvailability.restore,
  );
  Object? loadError;
  Completer<void>? loadGate;
  int loads = 0;
  int selfVerifications = 0;
  int observations = 0;
  final recoveryKeys = <String>[];
  bool verifyOnRecovery = true;
  Object? recoveryError;

  final trust = <String, UserTrust>{};
  final changes = <String, List<IdentityChange>>{};
  final acknowledged = <(String, String)>[];
  final verifiedUsers = <String>[];

  SecurityOverview overview = const SecurityOverview(
    deviceVerified: true,
    keyStorage: KeyStorageState.on,
    setupAvailability: CryptoSetupAvailability.connected,
    recoverySetUp: true,
  );
  int disables = 0;
  final enabled = <String>[];
  final rotations = <(String, String)>[];
  final resets = <(String, String?)>[];
  Uri? approvalUrl;
  bool? approvalResult;
  Object? resetError;

  void update() => notifyListeners();

  @override
  Listenable get securityChanges => this;
  @override
  String? get sessionKey => session;
  @override
  bool get encryptionAvailable => encryption;
  @override
  bool get thisDeviceVerified => verified;
  @override
  bool get verificationDeferred => deferred;

  @override
  void deferVerification() {
    deferred = true;
    notifyListeners();
  }

  @override
  Future<SessionSecurityState> loadSessionState() async {
    loads++;
    await loadGate?.future;
    final error = loadError;
    if (error != null) throw error;
    return state ?? const SessionSecurityState.unavailable();
  }

  @override
  Future<void> startSelfVerification() async => selfVerifications++;

  @override
  Future<void> confirmWithRecoveryKey(String keyOrPassphrase) async {
    recoveryKeys.add(keyOrPassphrase);
    final error = recoveryError;
    if (error != null) throw error;
    if (verifyOnRecovery) {
      verified = true;
      notifyListeners();
    }
  }

  @override
  void observeKnownIdentities() => observations++;

  @override
  UserTrust trustOf(String userId) =>
      trust[userId] ?? UserTrust(userId: userId, level: UserTrustLevel.unknown);

  @override
  List<IdentityChange> identityChanges(String roomId) =>
      changes[roomId] ?? const [];

  @override
  Future<void> acknowledgeIdentityChange(
    String userId,
    String masterKey,
  ) async {
    acknowledged.add((userId, masterKey));
    for (final entry in changes.entries) {
      changes[entry.key] = [
        for (final change in entry.value)
          if (change.userId != userId) change,
      ];
    }
    notifyListeners();
  }

  @override
  Future<void> verifyUser(String userId) async => verifiedUsers.add(userId);

  @override
  Future<SecurityOverview> loadOverview() async => overview;

  @override
  Future<void> enableKeyStorage(String keyOrPassphrase) async =>
      enabled.add(keyOrPassphrase);

  @override
  Future<void> disableKeyStorage() async => disables++;

  @override
  Future<RecoveryKeyChange> changeRecoveryKey({
    required String currentKeyOrPassphrase,
    required String newPassphrase,
  }) async {
    rotations.add((currentKeyOrPassphrase, newPassphrase));
    return const RecoveryKeyChange(
      recoveryKey: 'EsTn ew re co ve ry',
      oldKeyRetired: true,
    );
  }

  @override
  Future<String> resetIdentity({
    required String newPassphrase,
    String? password,
    required BrowserApproval approveInBrowser,
  }) async {
    resets.add((newPassphrase, password));
    final url = approvalUrl;
    if (url != null) {
      approvalResult = await approveInBrowser(url);
      if (approvalResult != true) throw StateError('cancelled');
    }
    final error = resetError;
    if (error != null) throw error;
    verified = true;
    notifyListeners();
    return 'EsTr es et ke y';
  }
}
