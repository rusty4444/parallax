/// A missing half of an identity is not permission to reset the other half.
enum CryptoSetupAvailability {
  create,
  repair,
  restore,
  connected,
  needsSingleDevice,
  blocked,
}

bool defaultStorageMatchesServer({
  required String? serverKeyId,
  required String? localKeyId,
}) => serverKeyId == localKeyId;

/// `wipe: false` does not prevent the SDK from replacing a public key or
/// backup when its private secret is missing. Require agreement on both sides
/// of each component before enabling in-place repair.
bool canRepairIdentityWithoutRotation({
  required bool masterPublic,
  required bool masterSecret,
  required bool selfSigningPublic,
  required bool selfSigningSecret,
  required bool userSigningPublic,
  required bool userSigningSecret,
  required bool backupVersion,
  required bool backupSecret,
}) =>
    // The SDK signs only newly generated subkeys. A new master cannot adopt
    // existing self/user-signing keys (or an old backup) as a trusted chain.
    (masterPublic ||
        (!selfSigningPublic && !userSigningPublic && !backupVersion)) &&
    masterPublic == masterSecret &&
    selfSigningPublic == selfSigningSecret &&
    userSigningPublic == userSigningSecret &&
    backupVersion == backupSecret;

CryptoSetupAvailability classifyCryptoSetup({
  required bool initialized,
  required bool connected,
  required bool validSecretStorage,
  required bool existingIdentityMaterial,
  bool repairSafe = false,
  bool hasOtherDevices = false,
}) {
  if (initialized) {
    return connected
        ? CryptoSetupAvailability.connected
        : CryptoSetupAvailability.restore;
  }
  if (validSecretStorage) {
    return repairSafe
        ? CryptoSetupAvailability.repair
        : CryptoSetupAvailability.blocked;
  }
  if (existingIdentityMaterial) return CryptoSetupAvailability.blocked;
  return hasOtherDevices
      ? CryptoSetupAvailability.needsSingleDevice
      : CryptoSetupAvailability.create;
}

/// Re-inspect immediately before any write, rather than trusting a settings
/// screen snapshot that may predate another device's setup.
Future<T> runOnlyWhenCryptoSetupIsSafe<T>({
  required CryptoSetupAvailability expected,
  required Future<CryptoSetupAvailability> Function() inspect,
  required Future<T> Function() action,
}) async {
  if (await inspect() != expected) {
    throw StateError('Encryption identity changed. Refresh its status.');
  }
  return action();
}
