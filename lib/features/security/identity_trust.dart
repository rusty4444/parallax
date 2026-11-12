import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How far this device trusts a user's current cross-signing identity.
///
/// Mirrors Element X's identity states: pinned (trusted on first use),
/// verified, and the two violations raised when a pinned or verified
/// identity is replaced.
enum UserTrustLevel {
  /// No cross-signing identity is known for the user.
  unknown,

  /// Seen, but not yet pinned or verified on this device.
  unpinned,

  /// Accepted on first use (TOFU) or after an acknowledged reset.
  pinned,

  /// Verified through cross-signing.
  verified,

  /// The identity changed since this device pinned it.
  pinViolation,

  /// The identity changed after this device had verified it.
  verificationViolation,
}

@immutable
class UserTrust {
  const UserTrust({
    required this.userId,
    required this.level,
    this.masterKey,
    this.previousMasterKey,
  });

  final String userId;
  final UserTrustLevel level;

  /// Current master signing key (public, base64), if any.
  final String? masterKey;

  /// The key this device pinned before a violation.
  final String? previousMasterKey;

  bool get verified => level == UserTrustLevel.verified;
  bool get isViolation =>
      level == UserTrustLevel.pinViolation ||
      level == UserTrustLevel.verificationViolation;
}

/// The SDK's current view of one user's master key.
@immutable
class IdentitySnapshot {
  const IdentitySnapshot({
    required this.masterKey,
    this.verified = false,
    this.pinned = false,
  });
  final String? masterKey;
  final bool verified;
  final bool pinned;
}

/// What this device last accepted for a user (app-owned, per account).
///
/// The SDK drops a replaced master key together with its TOFU flag, so a
/// reset is indistinguishable from a first sighting without this record.
@immutable
class PinRecord {
  const PinRecord(this.masterKey, {this.verified = false});
  final String masterKey;
  final bool verified;

  @override
  bool operator ==(Object other) =>
      other is PinRecord &&
      other.masterKey == masterKey &&
      other.verified == verified;

  @override
  int get hashCode => Object.hash(masterKey, verified);
}

/// Pure identity state machine. [record] is what this device accepted
/// earlier; [current] is the SDK's present key for the user.
UserTrustLevel classifyIdentity(IdentitySnapshot current, PinRecord? record) {
  final key = current.masterKey;
  if (key == null) return UserTrustLevel.unknown;
  if (current.verified) return UserTrustLevel.verified;
  if (record != null && record.masterKey != key && !current.pinned) {
    return record.verified
        ? UserTrustLevel.verificationViolation
        : UserTrustLevel.pinViolation;
  }
  return current.pinned ? UserTrustLevel.pinned : UserTrustLevel.unpinned;
}

/// The record to keep after observing [current], or null to keep the old one.
/// Only accepted states (verified or pinned) move the record; violations and
/// unpinned keys never overwrite what the user last accepted.
PinRecord? nextPinRecord(IdentitySnapshot current, PinRecord? record) {
  final key = current.masterKey;
  if (key == null) return null;
  final level = classifyIdentity(current, record);
  final next = switch (level) {
    UserTrustLevel.verified => PinRecord(key, verified: true),
    UserTrustLevel.pinned => PinRecord(key),
    _ => null,
  };
  return next == record ? null : next;
}

/// Storage for per-account pin records. Public keys only; not secret.
abstract interface class IdentityPinStorage {
  Future<Map<String, PinRecord>> load(String account);
  Future<void> save(String account, Map<String, PinRecord> records);
}

class SharedPreferencesPinStorage implements IdentityPinStorage {
  const SharedPreferencesPinStorage();

  static String _key(String account) =>
      'parallax.security.identity_pins.v1.'
      '${sha256.convert(utf8.encode(account))}';

  @override
  Future<Map<String, PinRecord>> load(String account) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(account));
    if (raw == null || raw.length > IdentityPinBook.maxStoredBytes) {
      return {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final records = <String, PinRecord>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (entry.key is! String || value is! Map) continue;
      final key = value['k'];
      if (key is! String || key.isEmpty || key.length > 128) continue;
      records[entry.key as String] = PinRecord(key, verified: value['v'] == 1);
    }
    return records;
  }

  @override
  Future<void> save(String account, Map<String, PinRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(account),
      jsonEncode({
        for (final entry in records.entries)
          entry.key: {
            'k': entry.value.masterKey,
            'v': entry.value.verified ? 1 : 0,
          },
      }),
    );
  }
}

class MemoryPinStorage implements IdentityPinStorage {
  final data = <String, Map<String, PinRecord>>{};
  int saves = 0;

  @override
  Future<Map<String, PinRecord>> load(String account) async =>
      Map.of(data[account] ?? const {});

  @override
  Future<void> save(String account, Map<String, PinRecord> records) async {
    saves++;
    data[account] = Map.of(records);
  }
}

/// In-memory pin records for one account with write-behind persistence.
///
/// Violations are only reported after the stored records have loaded; until
/// then every lookup behaves as if nothing was pinned before.
class IdentityPinBook extends ChangeNotifier {
  IdentityPinBook(this.account, this._storage);

  static const maxRecords = 5000;
  static const maxStoredBytes = 1 << 20;

  final String account;
  final IdentityPinStorage _storage;
  // Map literals are insertion-ordered; the oldest entry is evicted first.
  final _records = <String, PinRecord>{};
  bool _loaded = false;
  bool _loading = false;
  bool _dirty = false;
  bool _saving = false;
  bool _closed = false;

  bool get loaded => _loaded;

  PinRecord? operator [](String userId) => _loaded ? _records[userId] : null;

  /// Starts loading once. Load failures behave as an empty book.
  void ensureLoaded() {
    if (_loaded || _loading || _closed) return;
    _loading = true;
    unawaited(
      _storage
          .load(account)
          .then<Map<String, PinRecord>>(
            (value) => value,
            onError: (Object _) => <String, PinRecord>{},
          )
          .then((stored) {
            if (_closed) return;
            // Observations made while loading are newer than storage.
            final observed = Map.of(_records);
            _records
              ..clear()
              ..addAll(stored)
              ..addAll(observed);
            _trim();
            _loaded = true;
            _loading = false;
            if (observed.isNotEmpty) _scheduleSave();
            notifyListeners();
          }),
    );
  }

  /// Applies [nextPinRecord] for [userId]. Returns true when it changed.
  bool observe(String userId, IdentitySnapshot current) {
    if (_closed) return false;
    final next = nextPinRecord(current, _records[userId]);
    if (next == null) return false;
    _put(userId, next);
    return true;
  }

  /// Records an explicit user acceptance, replacing any violation.
  void accept(String userId, PinRecord record) {
    if (_closed || _records[userId] == record) return;
    _put(userId, record);
    notifyListeners();
  }

  void _put(String userId, PinRecord record) {
    _records.remove(userId);
    _records[userId] = record;
    _trim();
    if (_loaded) _scheduleSave();
  }

  void _trim() {
    while (_records.length > maxRecords) {
      _records.remove(_records.keys.first);
    }
  }

  void _scheduleSave() {
    _dirty = true;
    if (_saving || _closed) return;
    _saving = true;
    unawaited(() async {
      try {
        while (_dirty && !_closed) {
          _dirty = false;
          try {
            await _storage.save(account, Map.of(_records));
          } catch (_) {
            // Best effort: records stay in memory for this session.
            break;
          }
        }
      } finally {
        _saving = false;
      }
    }());
  }

  void close() {
    _closed = true;
  }

  @visibleForTesting
  Map<String, PinRecord> get records => Map.unmodifiable(_records);
}
