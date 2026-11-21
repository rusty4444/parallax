import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One signed-in (or pending) account slot. The `default` slot keeps the
/// original database and client name so existing sessions are untouched.
@immutable
class AccountSlot {
  const AccountSlot({
    required this.id,
    this.userId,
    this.homeserver,
    this.label,
    this.pending = false,
  });

  final String id;
  final String? userId;
  final String? homeserver;
  final String? label;
  final bool pending;

  bool get isDefault => id == AccountStore.defaultSlotId;

  String get displayName => label?.trim().isNotEmpty == true
      ? label!.trim()
      : userId ?? (pending ? 'New account' : 'Account');

  String get databaseFileName =>
      isDefault ? 'parallax.db' : 'parallax_acct_$id.db';
  String get clientName => isDefault ? 'Parallax' : 'Parallax:$id';

  AccountSlot copyWith({
    String? userId,
    String? homeserver,
    String? label,
    bool? pending,
  }) => AccountSlot(
    id: id,
    userId: userId ?? this.userId,
    homeserver: homeserver ?? this.homeserver,
    label: label ?? this.label,
    pending: pending ?? this.pending,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    if (userId != null) 'user_id': userId,
    if (homeserver != null) 'homeserver': homeserver,
    if (label != null) 'label': label,
    if (pending) 'pending': true,
  };

  static AccountSlot? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return AccountSlot(
      id: id,
      userId: json['user_id'] as String?,
      homeserver: json['homeserver'] as String?,
      label: json['label'] as String?,
      pending: json['pending'] == true,
    );
  }
}

/// Tracks the account slots and which one is active. The app shell rebuilds
/// the whole session when the active slot changes, so each account gets an
/// isolated backend, database and notification session.
class AccountStore extends ChangeNotifier {
  AccountStore._();

  static final instance = AccountStore._();

  static const defaultSlotId = 'default';
  static const _slotsKey = 'parallax.accounts.v1.slots';
  static const _activeKey = 'parallax.accounts.v1.active';

  final List<AccountSlot> _slots = [const AccountSlot(id: defaultSlotId)];
  String _activeSlotId = defaultSlotId;
  String? _previousSlotId;
  bool _loaded = false;

  bool get loaded => _loaded;
  List<AccountSlot> get slots => List.unmodifiable(_slots);
  String get activeSlotId => _activeSlotId;
  AccountSlot get activeSlot => _slots.firstWhere(
    (s) => s.id == _activeSlotId,
    orElse: () => _slots.first,
  );
  bool get addingAccount => activeSlot.pending;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_slotsKey);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) {
          final parsed = [for (final item in list) ?AccountSlot.fromJson(item)];
          if (parsed.any((s) => s.isDefault)) {
            _slots
              ..clear()
              ..addAll(parsed);
          }
        }
      }
      final active = prefs.getString(_activeKey);
      if (active != null && _slots.any((s) => s.id == active)) {
        _activeSlotId = active;
      }
    } catch (_) {
      // Fall back to the default slot.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _slotsKey,
        jsonEncode([for (final s in _slots) s.toJson()]),
      );
      await prefs.setString(_activeKey, _activeSlotId);
    } catch (_) {}
  }

  /// Starts adding a new account: creates a pending slot and activates it.
  Future<String> beginAddAccount() async {
    _previousSlotId = _activeSlotId;
    final id = 'acct_${DateTime.now().millisecondsSinceEpoch}';
    _slots.add(AccountSlot(id: id, pending: true));
    _activeSlotId = id;
    notifyListeners();
    await _persist();
    return id;
  }

  /// Records the signed-in identity for the active (pending) slot.
  Future<void> registerActive({
    required String userId,
    required String homeserver,
    String? label,
  }) async {
    final index = _slots.indexWhere((s) => s.id == _activeSlotId);
    if (index < 0) return;
    _slots[index] = _slots[index].copyWith(
      userId: userId,
      homeserver: homeserver,
      label: label,
      pending: false,
    );
    _previousSlotId = null;
    notifyListeners();
    await _persist();
  }

  /// Cancels adding an account and returns to the previous slot.
  Future<void> cancelAddAccount() async {
    final pendingId = _activeSlotId;
    _slots.removeWhere((s) => s.id == pendingId && s.pending);
    _activeSlotId =
        _previousSlotId != null && _slots.any((s) => s.id == _previousSlotId)
        ? _previousSlotId!
        : defaultSlotId;
    _previousSlotId = null;
    notifyListeners();
    await _persist();
  }

  Future<void> setActive(String id) async {
    if (!_slots.any((s) => s.id == id) || id == _activeSlotId) return;
    _activeSlotId = id;
    notifyListeners();
    await _persist();
  }

  Future<void> removeSlot(String id) async {
    if (id == defaultSlotId) return;
    _slots.removeWhere((s) => s.id == id);
    if (_activeSlotId == id) {
      _activeSlotId = defaultSlotId;
    }
    notifyListeners();
    await _persist();
  }
}
