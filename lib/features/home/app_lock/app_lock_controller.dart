import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import '../../../secure_store.dart';
import 'pin_hash.dart';

/// Element X lock screen configuration (appconfig/LockScreenConfig.kt).
abstract final class AppLockConfig {
  static const pinLength = 4;
  static const forbiddenPins = {'0000', '1234'};
  static const maxAttempts = 3;
  static const gracePeriod = Duration(minutes: 2);
}

/// Device biometrics, injectable for tests.
abstract interface class BiometricUnlock {
  Future<bool> isAvailable();
  Future<bool> authenticate(String reason);
}

class LocalAuthBiometricUnlock implements BiometricUnlock {
  LocalAuthBiometricUnlock([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      // Cancelled, locked out or unavailable: fall back to the PIN.
      return false;
    }
  }
}

/// PIN hashing runs off the UI isolate in production.
typedef PinHasher = Future<PinHash> Function(String pin);
typedef PinVerifier = Future<bool> Function(PinHash hash, String pin);

Future<PinHash> _isolateHash(String pin) =>
    Isolate.run(() => PinHash.create(pin));
Future<bool> _isolateVerify(PinHash hash, String pin) =>
    Isolate.run(() => hash.verify(pin));

enum PinProblem { length, forbidden }

/// PIN/biometric app lock (Element X `features/lockscreen`). The PIN is stored
/// only as a salted PBKDF2 hash in platform secure storage; failed attempts are
/// persisted so restarting the app does not reset them.
class AppLockController extends ChangeNotifier {
  AppLockController({
    SecureValueStore? store,
    BiometricUnlock? biometrics,
    DateTime Function()? clock,
    PinHasher? hasher,
    PinVerifier? verifier,
  }) : _store = store ?? const PlatformSecureValueStore(),
       _biometrics = biometrics ?? LocalAuthBiometricUnlock(),
       _clock = clock ?? DateTime.now,
       _hasher = hasher ?? _isolateHash,
       _verifier = verifier ?? _isolateVerify;

  static const _pinKey = 'parallax.app_lock.v1.pin';
  static const _attemptsKey = 'parallax.app_lock.v1.attempts';
  static const _biometricKey = 'parallax.app_lock.v1.biometric';

  final SecureValueStore _store;
  final BiometricUnlock _biometrics;
  final DateTime Function() _clock;
  final PinHasher _hasher;
  final PinVerifier _verifier;

  bool _loaded = false;
  bool _disposed = false;
  PinHash? _pin;
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  bool _locked = false;
  int _remaining = AppLockConfig.maxAttempts;
  DateTime? _backgroundedAt;
  bool _authenticating = false;
  Future<void>? _loading;
  String? _loadError;

  bool get loaded => _loaded;
  bool get pinSet => _pin != null;
  bool get biometricEnabled => _biometricEnabled && _biometricAvailable;
  bool get biometricAvailable => _biometricAvailable;
  bool get locked => _locked;
  int get remainingAttempts => _remaining;
  String? get loadError => _loadError;

  static PinProblem? validatePin(String pin) {
    if (pin.length != AppLockConfig.pinLength ||
        !RegExp(r'^[0-9]+$').hasMatch(pin)) {
      return PinProblem.length;
    }
    if (AppLockConfig.forbiddenPins.contains(pin)) return PinProblem.forbidden;
    return null;
  }

  /// Loads the saved configuration once. A configured PIN locks immediately
  /// (cold start). Unreadable storage leaves the app unlocked and reports
  /// [loadError] rather than trapping the user.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final pin = PinHash.decode(await _store.read(_pinKey));
      final attempts = int.tryParse(await _store.read(_attemptsKey) ?? '');
      final biometric = await _store.read(_biometricKey) == 'true';
      final available = await _biometrics.isAvailable();
      if (_disposed) return;
      _pin = pin;
      _remaining = (attempts ?? AppLockConfig.maxAttempts).clamp(
        0,
        AppLockConfig.maxAttempts,
      );
      _biometricEnabled = biometric;
      _biometricAvailable = available;
      _locked = pin != null;
    } catch (_) {
      if (_disposed) return;
      _loadError = 'Screen lock settings could not be read.';
    } finally {
      _loaded = true;
      _notify();
    }
  }

  Future<void> setPin(String pin) async {
    if (validatePin(pin) != null) throw ArgumentError('Invalid PIN');
    final hash = await _hasher(pin);
    await _store.write(_pinKey, hash.encode());
    await _store.write(_attemptsKey, '${AppLockConfig.maxAttempts}');
    _pin = hash;
    _remaining = AppLockConfig.maxAttempts;
    _locked = false;
    _loadError = null;
    _notify();
  }

  /// Checks [pin]. A wrong PIN consumes an attempt; the caller signs out when
  /// [remainingAttempts] reaches zero.
  Future<bool> verifyPin(String pin) async {
    final hash = _pin;
    if (hash == null || _remaining <= 0) return false;
    final ok = await _verifier(hash, pin);
    if (ok) {
      _remaining = AppLockConfig.maxAttempts;
      _locked = false;
      _backgroundedAt = null;
      await _store.write(_attemptsKey, '$_remaining');
    } else {
      _remaining = (_remaining - 1).clamp(0, AppLockConfig.maxAttempts);
      await _store.write(_attemptsKey, '$_remaining');
    }
    _notify();
    return ok;
  }

  Future<void> removePin() async {
    await _store.delete(_pinKey);
    await _store.delete(_attemptsKey);
    await _store.delete(_biometricKey);
    _pin = null;
    _biometricEnabled = false;
    _locked = false;
    _remaining = AppLockConfig.maxAttempts;
    _notify();
  }

  /// Removes the lock after sign-out (Element X deletes the PIN with the
  /// session). Safe after disposal.
  Future<void> clear() async {
    try {
      await _store.delete(_pinKey);
      await _store.delete(_attemptsKey);
      await _store.delete(_biometricKey);
    } catch (_) {
      // A stale PIN without a session is harmless: it is removed on next set.
    }
    if (_disposed) return;
    _pin = null;
    _biometricEnabled = false;
    _locked = false;
    _notify();
  }

  Future<void> refreshBiometricAvailability() async {
    final available = await _biometrics.isAvailable();
    if (_disposed || available == _biometricAvailable) return;
    _biometricAvailable = available;
    _notify();
  }

  /// Enabling requires a successful biometric check first.
  Future<bool> setBiometricEnabled(bool enabled) async {
    if (enabled) {
      if (!_biometricAvailable) return false;
      final ok = await _guardedAuthenticate(
        'Confirm biometric to unlock Parallax',
      );
      if (!ok) return false;
    }
    await _store.write(_biometricKey, enabled ? 'true' : 'false');
    _biometricEnabled = enabled;
    _notify();
    return true;
  }

  Future<bool> unlockWithBiometrics() async {
    if (!biometricEnabled || !_locked) return false;
    final ok = await _guardedAuthenticate('Unlock Parallax');
    if (ok && !_disposed) {
      _locked = false;
      _backgroundedAt = null;
      _remaining = AppLockConfig.maxAttempts;
      await _store.write(_attemptsKey, '$_remaining');
      _notify();
    }
    return ok;
  }

  Future<bool> _guardedAuthenticate(String reason) async {
    if (_authenticating) return false;
    _authenticating = true;
    try {
      return await _biometrics.authenticate(reason);
    } finally {
      _authenticating = false;
    }
  }

  void lock() {
    if (_pin == null || _locked) return;
    _locked = true;
    _notify();
  }

  /// Lifecycle: the biometric prompt itself may pause the activity, so it is
  /// ignored while authenticating.
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_pin == null || _authenticating) return;
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _backgroundedAt ??= _clock();
      case AppLifecycleState.resumed:
        final since = _backgroundedAt;
        _backgroundedAt = null;
        if (since != null &&
            _clock().difference(since) >= AppLockConfig.gracePeriod) {
          lock();
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
