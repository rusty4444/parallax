import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import '../../room_events.dart';
import '../appearance/sync_ledger.dart' show SyncSerial;

/// What "Same settings on all devices" covers, for its switch.
const syncedSettingsSummary =
    'Uses your Matrix account. Theme, font, chat colours and backgrounds, '
    'and your chat, media, privacy and notification settings follow you to '
    'every device. Text size, app lock and how notifications arrive stay on '
    'each device. Turning this on takes the settings from your other devices.';

/// One setting that follows the account (Settings → "Same settings on all
/// devices"). Values are JSON: null, bool, num, String or a list of strings.
@immutable
class SyncedSetting {
  const SyncedSetting(
    this.id, {
    required this.defaultValue,
    required this.read,
    required this.apply,
  });

  /// Stable name in the account record. Never rename one: other devices
  /// (and older versions) know it by this name.
  final String id;

  /// The value a device has when nobody chose one. A device only offers
  /// its own value to the account the first time when it differs from this.
  final Object? defaultValue;

  /// This device's current value.
  final Future<Object?> Function() read;

  /// Uses a value another device chose. Returns false when this version
  /// can't (a choice a newer version added); the setting is then left alone
  /// here, and the account keeps the newer device's value.
  final Future<bool> Function(Object? value) apply;
}

/// Lets settings stores that are not [Listenable] say the user changed
/// something, so [SettingsSync] uploads it.
class SettingsEdits extends ChangeNotifier {
  SettingsEdits._();

  static final instance = SettingsEdits._();

  /// Call after saving a synced setting the user changed.
  static void changed() => instance.notifyListeners();
}

/// A setting's value and when it was chosen (ms since epoch; 0 for a value
/// chosen before syncing settings existed).
@immutable
class StampedValue {
  const StampedValue(this.value, this.at);

  final Object? value;
  final int at;

  Map<String, Object?> toJson() => {'value': value, 'at': at};

  static StampedValue? fromJson(Object? json) {
    if (json is! Map || !json.containsKey('value')) return null;
    final at = json['at'];
    return StampedValue(json['value'], at is int ? at : 0);
  }
}

/// Whether two setting values are the same (lists compare by content).
bool sameSettingValue(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// Keeps app settings the same on every device signed in to the account,
/// through global account data `net.samrusselltech.parallax.settings`:
/// `{"version": 1, "settings": {"<id>": {"value": …, "at": ms}}}`.
///
/// Each setting converges on its own: the most recent choice wins, so
/// changes to different settings on two devices both survive. A device
/// meeting the account for the first time (or syncing again after it was
/// turned off) takes the account's values; it only offers the settings the
/// account doesn't have yet and that it changed from their defaults.
/// Settings this version doesn't know (added by a newer one) are kept.
///
/// Off with the same switch as theme and font ([enabled]).
class SettingsSync {
  SettingsSync({
    required Listenable backend,
    required this.settings,
    required this.enabled,
    required this._enabledChanges,
    required this._edits,
    SharedPreferences? preferences,
    int Function()? now,
    this.debounce = const Duration(milliseconds: 250),
  }) : _backend = backend,
       _access = backend is MatrixSdkAccess ? backend as MatrixSdkAccess : null,
       _prefs = preferences,
       _now = now ?? _wallClock;

  static const eventType = 'net.samrusselltech.parallax.settings';
  static const _statePrefix = 'parallax.settings_sync.v1.';

  final List<SyncedSetting> settings;
  final bool Function() enabled;
  final Duration debounce;

  final Listenable _backend;
  final MatrixSdkAccess? _access;
  final Listenable _enabledChanges;
  final Listenable _edits;
  SharedPreferences? _prefs;
  final int Function() _now;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  late final Map<String, SyncedSetting> _byId = {
    for (final setting in settings) setting.id: setting,
  };

  bool _started = false;
  bool _disposed = false;
  bool? _lastEnabled;
  matrix.Client? _syncedClient;
  Object? _token = _unread;
  static const _unread = Object();
  Timer? _editTimer;

  /// What this device's settings were when last looked at; a difference is
  /// a change made here.
  Map<String, Object?>? _observed;
  Future<void>? _baseline;

  matrix.Client? get _client {
    final client = _access?.sdkClient;
    return client == null || client.userID == null ? null : client;
  }

  bool _current(matrix.Client client) =>
      !_disposed && (_access?.isSessionCurrent(client) ?? false);

  static bool _hasSynced(matrix.Client client) => client.onSync.value != null;

  /// Call once this device's settings are loaded.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _lastEnabled = enabled();
    _baseline = _snapshot().then((values) {
      _observed ??= values;
    });
    _backend.addListener(_backendChanged);
    _enabledChanges.addListener(_enabledChanged);
    _edits.addListener(_edited);
    _backendChanged();
  }

  void dispose() {
    _disposed = true;
    _editTimer?.cancel();
    if (!_started) return;
    _backend.removeListener(_backendChanged);
    _enabledChanges.removeListener(_enabledChanged);
    _edits.removeListener(_edited);
  }

  /// Uploads changes still waiting (the app came back to the foreground).
  Future<void> retryPending() async {
    final client = _client;
    if (!_started || client == null || !_hasSynced(client)) return;
    await reconcile();
  }

  void _backendChanged() {
    if (_disposed) return;
    final client = _client;
    if (client == null || !_hasSynced(client)) return;
    if (!identical(client, _syncedClient)) {
      // A session's first sync: changes made offline can go now.
      _syncedClient = client;
      _token = _unread;
      unawaited(reconcile());
      return;
    }
    if (identical(client.accountData[eventType], _token)) return;
    unawaited(reconcile());
  }

  void _enabledChanged() {
    if (_disposed) return;
    final now = enabled();
    if (now == _lastEnabled) return;
    _lastEnabled = now;
    if (now) unawaited(_resync());
  }

  void _edited() {
    if (_disposed || !_started) return;
    _editTimer?.cancel();
    _editTimer = Timer(debounce, () => unawaited(checkLocalChanges()));
  }

  /// Syncing was turned back on: this device takes the account's settings,
  /// and offers only those the account doesn't have.
  Future<void> _resync() async {
    final client = _client;
    if (client == null) return;
    final userId = client.userID!;
    try {
      await SyncSerial.run(_serialKey(userId), () async {
        await _writeState(userId, const {});
      });
    } catch (_) {
      return;
    }
    await reconcile();
  }

  /// Records settings changed on this device and uploads them.
  @visibleForTesting
  Future<void> checkLocalChanges() async {
    _editTimer?.cancel();
    if (_disposed || !_started) return;
    await _baseline;
    final client = _client;
    if (client == null) return;
    if (!enabled()) {
      // Not tracked while off; turning it on takes the account's copy.
      _observed = await _snapshot();
      return;
    }
    final userId = client.userID!;
    try {
      await SyncSerial.run(_serialKey(userId), () async {
        if (!_current(client) || !enabled()) return;
        final state = await _readState(userId);
        if (!await _recordLocalChanges(state)) return;
        await _writeState(userId, state);
        if (_hasSynced(client)) {
          await _push(client, await _remote(client), state);
        }
      });
    } catch (_) {
      // Offline or unreadable: the change stays recorded and is uploaded on
      // the next sync, resume or change.
    }
  }

  /// Brings this device's settings in line with the account.
  Future<void> reconcile() async {
    if (_disposed || !_started) return;
    await _baseline;
    final client = _client;
    if (client == null || !enabled()) return;
    final userId = client.userID!;
    try {
      await SyncSerial.run(_serialKey(userId), () async {
        _token = client.accountData[eventType];
        final remote = await _remote(client);
        if (!_current(client) || !enabled()) return;
        final state = await _readState(userId);
        await _recordLocalChanges(state);
        final observed = _observed!;
        // Choices made here before syncing settings existed (or while it
        // was off) count as oldest, so the account's copy wins over them.
        for (final setting in settings) {
          final value = observed[setting.id];
          if (!state.containsKey(setting.id) &&
              !sameSettingValue(value, setting.defaultValue)) {
            state[setting.id] = StampedValue(value, 0);
          }
        }
        final adopt = <String, StampedValue>{};
        var push = false;
        for (final id in {...remote.keys, ...state.keys}) {
          final theirs = remote[id];
          final mine = state[id];
          if (theirs != null &&
              (mine == null ||
                  theirs.at > mine.at ||
                  (theirs.at == mine.at &&
                      !sameSettingValue(theirs.value, mine.value)))) {
            state[id] = theirs;
            adopt[id] = theirs;
          } else if (mine != null && (theirs == null || mine.at > theirs.at)) {
            push = true;
          }
        }
        for (final MapEntry(key: id, value: chosen) in adopt.entries) {
          final setting = _byId[id];
          if (setting == null) continue; // A newer version's setting.
          if (sameSettingValue(observed[id], chosen.value)) continue;
          try {
            await setting.apply(chosen.value);
          } catch (_) {
            // Left as it is on this device.
          }
          if (!_current(client)) return;
          observed[id] = await _read(setting);
        }
        await _writeState(userId, state);
        if (push && _hasSynced(client) && _current(client)) {
          await _push(client, remote, state);
        }
      });
    } catch (_) {
      // Offline or unreadable: tried again on the next change, sync or start.
    }
  }

  /// Compares this device's settings with the last look and stamps the
  /// changed ones with the current time. True when something changed.
  Future<bool> _recordLocalChanges(Map<String, StampedValue> state) async {
    final observed = _observed;
    if (observed == null) return false;
    final now = await _snapshot();
    var changed = false;
    for (final setting in settings) {
      final value = now[setting.id];
      if (sameSettingValue(value, observed[setting.id])) continue;
      observed[setting.id] = value;
      state[setting.id] = StampedValue(value, _now());
      changed = true;
    }
    return changed;
  }

  Future<void> _push(
    matrix.Client client,
    Map<String, StampedValue> remote,
    Map<String, StampedValue> state,
  ) async {
    final merged = <String, StampedValue>{...remote};
    for (final MapEntry(key: id, value: mine) in state.entries) {
      final theirs = remote[id];
      if (theirs == null || mine.at > theirs.at) merged[id] = mine;
    }
    final content = <String, Object?>{
      'version': 1,
      'settings': {
        for (final MapEntry(:key, :value) in merged.entries)
          key: value.toJson(),
      },
    };
    if (!_current(client)) return;
    await client.request(
      matrix.RequestType.PUT,
      _path(client.userID!),
      data: content,
    );
    if (!_current(client)) return;
    // Until the sync echo arrives, readers see what was just written.
    final written = matrix.BasicEvent(type: eventType, content: content);
    client.accountData[eventType] = written;
    _token = written;
  }

  Future<Map<String, Object?>> _snapshot() async => {
    for (final setting in settings) setting.id: await _read(setting),
  };

  static Future<Object?> _read(SyncedSetting setting) async {
    try {
      return await setting.read();
    } catch (_) {
      return setting.defaultValue;
    }
  }

  static String _path(String userId) =>
      '/client/v3/user/${Uri.encodeComponent(userId)}/account_data/$eventType';

  /// The account's copy (synced, else read from the server); empty when the
  /// account has none. Throws when it can't be read.
  Future<Map<String, StampedValue>> _remote(matrix.Client client) async {
    Map<String, Object?>? content = client.accountData[eventType]?.content;
    if (content == null && !_hasSynced(client)) {
      try {
        content = await client.request(
          matrix.RequestType.GET,
          _path(client.userID!),
        );
      } on matrix.MatrixException catch (error) {
        if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
      }
    }
    return parseSettingsRecord(content);
  }

  /// The settings in an account record; malformed entries are skipped.
  static Map<String, StampedValue> parseSettingsRecord(Object? content) {
    final settings = content is Map ? content['settings'] : null;
    if (settings is! Map) return {};
    return {
      for (final MapEntry(:key, :value) in settings.entries)
        if (key is String && StampedValue.fromJson(value) != null)
          key: StampedValue.fromJson(value)!,
    };
  }

  // --- This device's record: the last value it agreed with the account ---

  static String _serialKey(String userId) => '$_statePrefix$userId';

  static String _stateKey(String userId) =>
      '$_statePrefix${sha256.convert(utf8.encode(userId))}';

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<Map<String, StampedValue>> _readState(String userId) async {
    final raw = (await _preferences()).getString(_stateKey(userId));
    if (raw == null) return {};
    try {
      return parseSettingsRecord({'settings': jsonDecode(raw)});
    } catch (_) {
      return {}; // Unreadable: start over (the account's copy then wins).
    }
  }

  Future<void> _writeState(
    String userId,
    Map<String, StampedValue> state,
  ) async {
    final saved = await (await _preferences()).setString(
      _stateKey(userId),
      jsonEncode({
        for (final MapEntry(:key, :value) in state.entries) key: value.toJson(),
      }),
    );
    if (!saved) throw StateError('Could not save settings sync state');
  }
}
