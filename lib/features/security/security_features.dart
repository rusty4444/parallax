import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../crypto_setup_policy.dart';
import '../../matrix_backend.dart';
import 'identity_trust.dart';
import 'matrix_security.dart';

export 'identity_trust.dart' show UserTrust, UserTrustLevel;

/// What this device and account look like to the post-login security gate.
@immutable
class SessionSecurityState {
  const SessionSecurityState({
    required this.encryptionAvailable,
    required this.accountHasIdentity,
    required this.deviceVerified,
    this.canUseAnotherDevice = false,
    this.canUseRecoveryKey = false,
    this.setupAvailability,
  });

  const SessionSecurityState.unavailable()
    : encryptionAvailable = false,
      accountHasIdentity = false,
      deviceVerified = false,
      canUseAnotherDevice = false,
      canUseRecoveryKey = false,
      setupAvailability = null;

  final bool encryptionAvailable;

  /// The account has a published cross-signing master key.
  final bool accountHasIdentity;

  /// This device is signed by the account's current identity.
  final bool deviceVerified;

  /// Another of this account's devices is verified and can vouch for us.
  final bool canUseAnotherDevice;

  /// Secret storage exists, so a recovery key or passphrase can confirm us.
  final bool canUseRecoveryKey;
  final CryptoSetupAvailability? setupAvailability;
}

/// Server-side key backup ("key storage" in Element X).
enum KeyStorageState {
  /// A backup version exists and its secret is in secret storage.
  on,

  /// No backup version and no stored backup secret.
  off,

  /// Only one half exists (for example an interrupted turn-off).
  incomplete,
}

/// Settings-level summary of encryption, recovery and this device.
@immutable
class SecurityOverview {
  const SecurityOverview({
    required this.deviceVerified,
    required this.keyStorage,
    required this.setupAvailability,
    required this.recoverySetUp,
  });

  final bool deviceVerified;
  final KeyStorageState keyStorage;
  final CryptoSetupAvailability setupAvailability;

  /// Secret storage holds the cross-signing identity.
  final bool recoverySetUp;

  /// Rotation needs a complete identity reachable through secret storage.
  bool get canChangeRecoveryKey =>
      setupAvailability == CryptoSetupAvailability.connected ||
      setupAvailability == CryptoSetupAvailability.restore;
}

/// A room member whose identity changed since this device pinned it.
@immutable
class IdentityChange {
  const IdentityChange({
    required this.userId,
    required this.displayName,
    required this.trust,
  });
  final String userId;
  final String displayName;
  final UserTrust trust;
}

@immutable
class RecoveryKeyChange {
  const RecoveryKeyChange({
    required this.recoveryKey,
    required this.oldKeyRetired,
  });

  /// Base58 recovery key for the new secret storage key.
  final String recoveryKey;

  /// False when the new key is the default but some old wrappers remain: the
  /// previous credential may still decrypt them until a later retry.
  final bool oldKeyRetired;
}

/// Browser approval requested by the homeserver during identity reset (for
/// example MAS `org.matrix.cross_signing_reset` or a UIA fallback stage).
/// Return true once the user says they approved it, false to cancel.
typedef BrowserApproval = Future<bool> Function(Uri url);

/// Security module surface. The Matrix implementation wraps [MatrixBackend];
/// tests implement this interface directly.
abstract interface class SecurityFeatures {
  /// Notifies when trust records or local security state change.
  Listenable get securityChanges;

  /// Identifies the signed-in device session, or null when signed out.
  String? get sessionKey;

  bool get encryptionAvailable;

  /// Cheap local check: this device is cross-signed by the current identity.
  bool get thisDeviceVerified;

  /// The user chose "Later" on the identity confirmation for this session.
  bool get verificationDeferred;
  void deferVerification();

  /// Authoritative (network) state for the post-login gate.
  Future<SessionSecurityState> loadSessionState();

  /// Starts verification against this account's other devices. The global
  /// security overlay drives the emoji comparison.
  Future<void> startSelfVerification();

  /// Confirms this device with the recovery key or passphrase (restore,
  /// in-place repair or self-signing, whichever is safe for the account).
  Future<void> confirmWithRecoveryKey(String keyOrPassphrase);

  /// Records identities this device has accepted (verified or pinned) so a
  /// later reset can be recognised. Cheap and self-throttling.
  void observeKnownIdentities();

  /// Trust in a user's current cross-signing identity on this device.
  UserTrust trustOf(String userId);

  /// Members of an encrypted room whose identity was reset since pinned.
  List<IdentityChange> identityChanges(String roomId);

  /// Accepts (pins) [masterKey] as [userId]'s identity. Used for "Dismiss" on
  /// a reset identity and "Withdraw verification" on a reset verified one.
  Future<void> acknowledgeIdentityChange(String userId, String masterKey);

  /// Starts an interactive verification with another user.
  Future<void> verifyUser(String userId);

  Future<SecurityOverview> loadOverview();

  /// Creates a new backup with the existing recovery credential.
  Future<void> enableKeyStorage(String keyOrPassphrase);

  /// Deletes the server backup and its stored secret. Idempotent.
  Future<void> disableKeyStorage();

  /// Staged rotation: copy every secret to a new key, verify, then switch.
  Future<RecoveryKeyChange> changeRecoveryKey({
    required String currentKeyOrPassphrase,
    required String newPassphrase,
  });

  /// Destroys and recreates cross-signing, secret storage and key backup.
  /// Returns the new recovery key.
  Future<String> resetIdentity({
    required String newPassphrase,
    String? password,
    required BrowserApproval approveInBrowser,
  });
}

final _cache = Expando<SecurityFeatures>('parallax.security');

/// Resolves the security module for a backend, or null when unsupported
/// (for example lightweight demo/test backends).
SecurityFeatures? securityFeaturesOf(ChatBackend backend) =>
    backend is SecurityFeatures
    ? backend as SecurityFeatures
    : backend is MatrixBackend
    ? _cache[backend] ??= MatrixSecurity(backend)
    : null;

/// Trust helper for other modules (room headers, member lists …). Returns
/// [UserTrustLevel.unknown] when the backend has no security module.
UserTrust trustOf(ChatBackend backend, String userId) =>
    securityFeaturesOf(backend)?.trustOf(userId) ??
    UserTrust(userId: userId, level: UserTrustLevel.unknown);
