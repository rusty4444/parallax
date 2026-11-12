import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_location_model.dart';

/// A share this device started, persisted so it can resume after restart.
@immutable
class PersistedShare {
  const PersistedShare({
    required this.roomId,
    required this.beaconInfoId,
    required this.content,
  });

  final String roomId;
  final String beaconInfoId;

  /// The `beacon_info` content as started (stopping rewrites it with
  /// `live: false`).
  final Map<String, Object?> content;

  int? get startMillis => beaconInfoStartMillis(content);
  int? get timeoutMillis {
    final value = content['timeout'];
    return value is int && value > 0 ? value : null;
  }

  Map<String, Object?> toJson() => {
    'room_id': roomId,
    'event_id': beaconInfoId,
    'content': content,
  };

  static PersistedShare? fromJson(Object? json) {
    if (json is! Map) return null;
    final roomId = json['room_id'];
    final eventId = json['event_id'];
    final content = json['content'];
    if (roomId is! String ||
        !roomId.startsWith('!') ||
        eventId is! String ||
        !eventId.startsWith(r'$') ||
        content is! Map) {
      return null;
    }
    final share = PersistedShare(
      roomId: roomId,
      beaconInfoId: eventId,
      content: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(content),
      ),
    );
    final start = share.startMillis;
    final timeout = share.timeoutMillis;
    const maxMillis = 253402300799000; // year 9999
    if (start == null ||
        timeout == null ||
        start <= 0 ||
        start >= maxMillis ||
        timeout > const Duration(days: 365).inMilliseconds) {
      return null;
    }
    return share;
  }
}

/// Local record of this device's active shares, per account and device.
abstract interface class LiveShareStore {
  Future<List<PersistedShare>> load(String accountKey);
  Future<void> save(String accountKey, List<PersistedShare> shares);
  Future<void> clear(String accountKey);
}

/// SharedPreferences store. Holds room IDs, event IDs and share timing only
/// (no positions); room IDs are already in the SDK database on the device.
class PreferencesLiveShareStore implements LiveShareStore {
  const PreferencesLiveShareStore();

  static const maxShares = 32;
  static String _key(String accountKey) =>
      'parallax.live_location.shares.v1.$accountKey';

  @override
  Future<List<PersistedShare>> load(String accountKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(accountKey));
      if (raw == null || raw.length > 64 * 1024) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded.take(maxShares))
          ?PersistedShare.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(String accountKey, List<PersistedShare> shares) async {
    final prefs = await SharedPreferences.getInstance();
    if (shares.isEmpty) {
      await prefs.remove(_key(accountKey));
      return;
    }
    await prefs.setString(
      _key(accountKey),
      jsonEncode([for (final s in shares.take(maxShares)) s.toJson()]),
    );
  }

  @override
  Future<void> clear(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(accountKey));
  }
}
