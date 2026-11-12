/// Staged recovery-key rotation for Matrix secret storage (SSSS).
///
/// SDK 14.1.0's `Bootstrap.newSsss()` migrates with `stripKeys: true` and
/// ignores which secrets actually migrated, so a failed write can leave the
/// key backup readable only under the old key while the new key becomes the
/// default. This implementation never strips or switches until every secret
/// has been copied and read back under the new key:
///
/// 1. read every secret encrypted under the current default key;
/// 2. create the new key (not yet default);
/// 3. add a new-key copy beside each old copy;
/// 4. decrypt each copy with the new key and compare;
/// 5. confirm no other device changed the default meanwhile;
/// 6. make the new key the default (commit);
/// 7. remove the old copies (best effort, reported).
///
/// Any failure before step 6 leaves the old recovery key fully working.
library;

abstract interface class SecretStorageWriter {
  /// Current default secret storage key ID.
  String? get defaultKeyId;

  /// Secret type -> key IDs that currently encrypt it.
  Map<String, Set<String>> encryptedSecrets();

  /// Decrypts [type] with the (unlocked) current default key.
  Future<String> readWithOldKey(String type);

  /// Creates and unlocks the new key without making it the default.
  Future<String> createNewKey();

  /// Adds a copy of [secret] under the new key, keeping other copies.
  Future<void> stage(String type, String secret);

  /// Decrypts [type] with the new key.
  Future<String> readWithNewKey(String type);

  /// Makes the new key the default.
  Future<void> commitDefault();

  /// Removes every copy of [type] not encrypted with the new key.
  Future<void> retireOldCopies(String type, String secret);
}

enum RotationOutcome {
  /// The new key is the default and old copies were removed.
  completed,

  /// The new key is the default, but some old copies remain readable with
  /// the previous credential.
  oldCopiesRemain,
}

class RotationAborted implements Exception {
  const RotationAborted(this.message);
  final String message;
  @override
  String toString() => 'RotationAborted: $message';
}

Future<RotationOutcome> rotateSecretStorageKey(
  SecretStorageWriter storage, {
  required Set<String> requiredTypes,
  required bool Function() isCurrent,
}) async {
  void check() {
    if (!isCurrent()) throw const RotationAborted('Session changed');
  }

  final oldKeyId = storage.defaultKeyId;
  if (oldKeyId == null) {
    throw const RotationAborted('Recovery is not set up');
  }
  final types = [
    for (final entry in storage.encryptedSecrets().entries)
      if (entry.value.contains(oldKeyId)) entry.key,
  ]..sort();
  if (!types.toSet().containsAll(requiredTypes)) {
    throw const RotationAborted('Recovery does not hold the full identity');
  }

  // 1. Every secret must be readable before anything is written.
  final secrets = <String, String>{};
  for (final type in types) {
    secrets[type] = await storage.readWithOldKey(type);
    check();
  }

  // 2–3. Stage copies under an unreferenced new key.
  final newKeyId = await storage.createNewKey();
  check();
  if (newKeyId == oldKeyId) {
    throw const RotationAborted('New key matches the old key');
  }
  for (final type in types) {
    await storage.stage(type, secrets[type]!);
    check();
  }

  // 4. Read back and compare before switching.
  for (final type in types) {
    if (await storage.readWithNewKey(type) != secrets[type]) {
      throw RotationAborted('Copy of $type did not verify');
    }
    check();
  }

  // 5. Another device may have rotated or reset meanwhile.
  if (storage.defaultKeyId != oldKeyId) {
    throw const RotationAborted('Recovery changed on another device');
  }
  final staged = storage.encryptedSecrets();
  for (final type in types) {
    final keys = staged[type] ?? const <String>{};
    if (!keys.contains(newKeyId) || !keys.contains(oldKeyId)) {
      throw RotationAborted('Copies of $type changed during rotation');
    }
  }
  check();

  // 6. Commit.
  await storage.commitDefault();

  // 7. Retire old copies; a failure here leaves the old key usable but loses
  // nothing, so report it instead of throwing.
  var retired = true;
  for (final type in types) {
    try {
      await storage.retireOldCopies(type, secrets[type]!);
    } catch (_) {
      retired = false;
    }
    if (!isCurrent()) return RotationOutcome.oldCopiesRemain;
  }
  return retired ? RotationOutcome.completed : RotationOutcome.oldCopiesRemain;
}
