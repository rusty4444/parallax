import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A missing value is null; an unavailable store must throw.
abstract interface class SecureValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecureValueStore implements SecureValueStore {
  const PlatformSecureValueStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    // The data-protection keychain (the plugin default) needs a real Apple
    // signing identity; ad-hoc local builds get errSecMissingEntitlement
    // (-34018). The file-based login keychain works for personal builds and
    // is protected by the user's login password. Switch back to true when
    // distributing with a Developer ID / App Store signature.
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
