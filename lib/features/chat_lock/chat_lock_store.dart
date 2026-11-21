import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../secure_store.dart';
import '../home/app_lock/app_lock_controller.dart';
import '../home/app_lock/pin_hash.dart';

/// Per-chat lock (WhatsApp Chat Lock style). Locked rooms hide their preview
/// in the inbox and notifications, and require the app's biometric/PIN
/// credential before their content is shown. The locked-room set is stored
/// per account; the credential itself is the app lock's (Settings → Security).
class ChatLockStore extends ChangeNotifier {
  ChatLockStore({
    SharedPreferences? preferences,
    SecureValueStore? secureStore,
    BiometricUnlock? biometrics,
  }) : _prefs = preferences,
       _secure = secureStore ?? const PlatformSecureValueStore(),
       _biometrics = biometrics ?? LocalAuthBiometricUnlock();

  static final shared = ChatLockStore();

  static const _pinKey = 'parallax.app_lock.v1.pin';
  static const _biometricKey = 'parallax.app_lock.v1.biometric';

  SharedPreferences? _prefs;
  final SecureValueStore _secure;
  final BiometricUnlock _biometrics;

  String? _accountKey;
  final _locked = <String>{};
  final _unlockedThisSession = <String>{};
  bool _pinSet = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  bool _loaded = false;

  bool get loaded => _loaded;
  bool get pinSet => _pinSet;
  bool get biometricAvailable => _biometricAvailable && _biometricEnabled;
  bool get canLock => _pinSet || biometricAvailable;

  bool isLocked(String roomId) => _locked.contains(roomId);
  bool needsUnlock(String roomId) =>
      _locked.contains(roomId) && !_unlockedThisSession.contains(roomId);

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  static String _keyFor(String accountKey) =>
      'parallax.chat_lock.v1.${sha256.convert(utf8.encode(accountKey))}';

  /// Loads the locked-room set and credential availability for an account.
  Future<void> bindAccount(String? accountKey) async {
    if (accountKey == null || accountKey.isEmpty) {
      _accountKey = null;
      _locked.clear();
      _unlockedThisSession.clear();
      _loaded = true;
      notifyListeners();
      return;
    }
    if (accountKey == _accountKey && _loaded) return;
    _accountKey = accountKey;
    _unlockedThisSession.clear();
    _locked.clear();
    try {
      final raw = (await _preferences()).getString(_keyFor(accountKey));
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          _locked.addAll(list.whereType<String>());
        }
      }
    } catch (_) {
      // Unreadable storage: treat as no locked chats rather than trapping.
    }
    await refreshCredential();
    _loaded = true;
    notifyListeners();
  }

  /// Re-reads whether the app lock credential is available.
  Future<void> refreshCredential() async {
    try {
      _pinSet = PinHash.decode(await _secure.read(_pinKey)) != null;
      _biometricEnabled = await _secure.read(_biometricKey) == 'true';
      _biometricAvailable = await _biometrics.isAvailable();
    } catch (_) {
      _pinSet = false;
      _biometricAvailable = false;
    }
    notifyListeners();
  }

  Future<void> setLocked(String roomId, bool locked) async {
    final accountKey = _accountKey;
    if (locked) {
      _locked.add(roomId);
      _unlockedThisSession.remove(roomId);
    } else {
      _locked.remove(roomId);
      _unlockedThisSession.remove(roomId);
    }
    notifyListeners();
    if (accountKey == null) return;
    try {
      final prefs = await _preferences();
      if (_locked.isEmpty) {
        await prefs.remove(_keyFor(accountKey));
      } else {
        await prefs.setString(
          _keyFor(accountKey),
          jsonEncode(_locked.toList()),
        );
      }
    } catch (_) {
      // Best-effort persistence; the in-memory state still applies.
    }
  }

  void markUnlocked(String roomId) {
    _unlockedThisSession.add(roomId);
    notifyListeners();
  }

  /// Biometric unlock for a chat. Returns true on success.
  Future<bool> unlockWithBiometrics(String roomId) async {
    if (!biometricAvailable) return false;
    final ok = await _biometrics.authenticate('Unlock chat');
    if (ok) markUnlocked(roomId);
    return ok;
  }

  /// PIN unlock for a chat, verified against the app lock PIN without
  /// consuming the app lock's attempt budget.
  Future<bool> unlockWithPin(String roomId, String pin) async {
    if (!_pinSet) return false;
    final hash = PinHash.decode(await _secure.read(_pinKey));
    if (hash == null) return false;
    final ok = await Isolate.run(() => hash.verify(pin));
    if (ok) markUnlocked(roomId);
    return ok;
  }

  /// Forgets session unlocks (for example on sign-out).
  void resetSession() {
    _unlockedThisSession.clear();
    notifyListeners();
  }
}
