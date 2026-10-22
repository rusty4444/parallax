import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/crypto_setup_policy.dart';

void main() {
  test('stale local default storage pointer is not accepted', () {
    expect(
      defaultStorageMatchesServer(serverKeyId: null, localKeyId: null),
      isTrue,
    );
    expect(
      defaultStorageMatchesServer(serverKeyId: 'K1', localKeyId: 'K1'),
      isTrue,
    );
    expect(
      defaultStorageMatchesServer(serverKeyId: 'K2', localKeyId: 'K1'),
      isFalse,
    );
    expect(
      defaultStorageMatchesServer(serverKeyId: 'K2', localKeyId: null),
      isFalse,
    );
  });

  test('repair refuses public keys or backup without matching secrets', () {
    bool safe({
      bool masterPublic = false,
      bool masterSecret = false,
      bool backupVersion = false,
      bool backupSecret = false,
    }) => canRepairIdentityWithoutRotation(
      masterPublic: masterPublic,
      masterSecret: masterSecret,
      selfSigningPublic: false,
      selfSigningSecret: false,
      userSigningPublic: false,
      userSigningSecret: false,
      backupVersion: backupVersion,
      backupSecret: backupSecret,
    );

    expect(safe(), isTrue);
    expect(safe(masterPublic: true), isFalse);
    expect(safe(backupVersion: true), isFalse);
    expect(safe(masterPublic: true, masterSecret: true), isTrue);
    expect(
      canRepairIdentityWithoutRotation(
        masterPublic: false,
        masterSecret: false,
        selfSigningPublic: true,
        selfSigningSecret: true,
        userSigningPublic: false,
        userSigningSecret: false,
        backupVersion: false,
        backupSecret: false,
      ),
      isFalse,
    );
    expect(safe(backupVersion: true, backupSecret: true), isFalse);
  });

  test('only a truly empty account may create a new identity', () {
    expect(
      classifyCryptoSetup(
        initialized: false,
        connected: false,
        validSecretStorage: false,
        existingIdentityMaterial: false,
      ),
      CryptoSetupAvailability.create,
    );
    expect(
      classifyCryptoSetup(
        initialized: false,
        connected: false,
        validSecretStorage: false,
        existingIdentityMaterial: true,
      ),
      CryptoSetupAvailability.blocked,
    );
    expect(
      classifyCryptoSetup(
        initialized: false,
        connected: false,
        validSecretStorage: true,
        existingIdentityMaterial: true,
        repairSafe: true,
      ),
      CryptoSetupAvailability.repair,
    );
    expect(
      classifyCryptoSetup(
        initialized: false,
        connected: false,
        validSecretStorage: true,
        existingIdentityMaterial: true,
        repairSafe: false,
      ),
      CryptoSetupAvailability.blocked,
    );
    expect(
      classifyCryptoSetup(
        initialized: false,
        connected: false,
        validSecretStorage: false,
        existingIdentityMaterial: false,
        hasOtherDevices: true,
      ),
      CryptoSetupAvailability.needsSingleDevice,
    );
  });

  test('existing complete identity must restore rather than reset', () {
    expect(
      classifyCryptoSetup(
        initialized: true,
        connected: false,
        validSecretStorage: true,
        existingIdentityMaterial: true,
      ),
      CryptoSetupAvailability.restore,
    );
    expect(
      classifyCryptoSetup(
        initialized: true,
        connected: true,
        validSecretStorage: true,
        existingIdentityMaterial: true,
      ),
      CryptoSetupAvailability.connected,
    );
  });

  test('rechecks before writing and refuses a concurrent identity', () async {
    var writes = 0;
    await expectLater(
      runOnlyWhenCryptoSetupIsSafe(
        expected: CryptoSetupAvailability.create,
        inspect: () async => CryptoSetupAvailability.repair,
        action: () async {
          writes++;
          return 'never created';
        },
      ),
      throwsStateError,
    );
    expect(writes, 0);
    expect(
      await runOnlyWhenCryptoSetupIsSafe(
        expected: CryptoSetupAvailability.create,
        inspect: () async => CryptoSetupAvailability.create,
        action: () async {
          writes++;
          return 'created';
        },
      ),
      'created',
    );
    expect(writes, 1);
  });
}
