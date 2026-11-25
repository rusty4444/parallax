import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hash of account-data content that ignores key order, so the same setting
/// written by two devices hashes the same.
String contentHash(Object? content) =>
    sha256.convert(utf8.encode(_canonical(content))).toString();

String _canonical(Object? value) {
  if (value is Map) {
    final keys = [for (final key in value.keys) '$key']..sort();
    return '{${[for (final key in keys) '${jsonEncode(key)}:${_canonical(value[key])}'].join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

/// When a synced setting was last changed (`updatedAt`, ms since epoch).
/// Content written by Parallax 1.5.4 and earlier has none and counts as 0.
int remoteUpdatedAt(Map<String, Object?> content) {
  final value = content['updatedAt'];
  return value is int ? value : 0;
}

/// What this device knows about one synced setting.
@immutable
class SyncEntry {
  const SyncEntry({
    required this.userId,
    required this.type,
    this.roomId,
    this.seen,
    this.pending,
    this.localOnly = false,
  });

  final String userId;

  /// The account-data event type.
  final String type;

  /// Null for account-wide settings.
  final String? roomId;

  /// Hash of the account copy this device last adopted or wrote.
  final String? seen;

  /// When this device changed the setting without the account having the
  /// change yet (ms since epoch). Cleared once it is uploaded.
  final int? pending;

  /// Kept on this device only: never uploaded, account changes ignored.
  final bool localOnly;

  SyncEntry copyWith({
    String? Function()? seen,
    int? Function()? pending,
    bool? localOnly,
  }) => SyncEntry(
    userId: userId,
    type: type,
    roomId: roomId,
    seen: seen == null ? this.seen : seen(),
    pending: pending == null ? this.pending : pending(),
    localOnly: localOnly ?? this.localOnly,
  );

  Map<String, Object?> toJson() => {
    'user': userId,
    'type': type,
    'room': ?roomId,
    'seen': ?seen,
    'pending': ?pending,
    if (localOnly) 'localOnly': true,
  };

  static SyncEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final user = json['user'], type = json['type'], room = json['room'];
    if (user is! String || type is! String) return null;
    final seen = json['seen'], pending = json['pending'];
    return SyncEntry(
      userId: user,
      type: type,
      roomId: room is String ? room : null,
      seen: seen is String ? seen : null,
      pending: pending is int ? pending : null,
      localOnly: json['localOnly'] == true,
    );
  }
}

enum SyncAction {
  /// Both sides already agree, or the setting is kept on this device.
  none,

  /// Another device changed the setting: use the account's copy here.
  adoptRemote,

  /// Upload this device's setting to the account.
  pushLocal,
}

/// How one synced setting converges. The account copy wins unless this
/// device has a change that has not been uploaded yet; then the newer of the
/// two wins. A device with a setting the account has never had uploads it
/// (settings chosen before syncing existed).
SyncAction decideSync({
  required Map<String, Object?>? remote,
  required SyncEntry entry,
  required bool hasLocal,
  Set<String> ownWrites = const {},
}) {
  if (entry.localOnly) return SyncAction.none;
  final pending = entry.pending;
  if (remote == null) {
    return pending != null || hasLocal ? SyncAction.pushLocal : SyncAction.none;
  }
  final hash = contentHash(remote);
  // A late echo of this device's own earlier upload is not someone else's
  // change: adopting it would briefly undo a newer local edit. Only while
  // this device knows a newer copy; after a reset (syncing turned back on)
  // the account's copy is taken even if this device once wrote it.
  final changed =
      hash != entry.seen && !(entry.seen != null && ownWrites.contains(hash));
  if (pending != null) {
    return changed && remoteUpdatedAt(remote) > pending
        ? SyncAction.adoptRemote
        : SyncAction.pushLocal;
  }
  return changed ? SyncAction.adoptRemote : SyncAction.none;
}

/// Per-device sync state of synced settings, in SharedPreferences.
class SyncLedger {
  SyncLedger({SharedPreferences? preferences}) : _prefs = preferences;

  static final shared = SyncLedger();

  static const _prefix = 'parallax.sync.v1.';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  static String keyFor(String userId, String type, [String? roomId]) =>
      '$_prefix${sha256.convert(utf8.encode('$userId|$type|${roomId ?? ''}'))}';

  Future<SyncEntry> read(String userId, String type, [String? roomId]) async {
    final prefs = await _preferences();
    final raw = prefs.getString(keyFor(userId, type, roomId));
    SyncEntry? entry;
    if (raw != null) {
      try {
        entry = SyncEntry.fromJson(jsonDecode(raw));
      } catch (_) {
        // Unreadable: start over (the account copy then wins).
      }
    }
    return entry ?? SyncEntry(userId: userId, type: type, roomId: roomId);
  }

  Future<void> write(SyncEntry entry) async {
    final prefs = await _preferences();
    final saved = await prefs.setString(
      keyFor(entry.userId, entry.type, entry.roomId),
      jsonEncode(entry.toJson()),
    );
    if (!saved) throw StateError('Could not save sync state');
  }

  /// Settings of [userId] with a change still waiting to be uploaded.
  Future<List<SyncEntry>> pending(String userId) async {
    final prefs = await _preferences();
    final entries = <SyncEntry>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final raw = prefs.get(key);
      if (raw is! String) continue;
      SyncEntry? entry;
      try {
        entry = SyncEntry.fromJson(jsonDecode(raw));
      } catch (_) {
        continue;
      }
      if (entry != null &&
          entry.userId == userId &&
          entry.pending != null &&
          !entry.localOnly) {
        entries.add(entry);
      }
    }
    return entries;
  }
}

/// Runs operations on one synced setting one at a time, across every helper
/// instance (a room screen, the settings sheet and the app-wide retry share
/// the same setting).
class SyncSerial {
  SyncSerial._();

  static final _tails = <String, Future<void>>{};

  static Future<T> run<T>(String key, Future<T> Function() operation) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return result;
  }
}

/// Hashes of content this device uploaded recently, per setting, so late
/// echoes of its own earlier writes are recognised.
class OwnWrites {
  OwnWrites._();

  static final _byKey = <String, List<String>>{};

  static Set<String> of(String key) => {...?_byKey[key]};

  static void add(String key, String hash) {
    final list = _byKey.putIfAbsent(key, () => []);
    list
      ..remove(hash)
      ..add(hash);
    if (list.length > 8) list.removeAt(0);
  }

  @visibleForTesting
  static void clear() => _byKey.clear();
}
