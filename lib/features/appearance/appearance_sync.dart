import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../appearance_preferences.dart';
import '../../room_events.dart';
import '../app_fonts/app_fonts.dart';
import 'room_theme_sync.dart';
import 'sync_ledger.dart';

/// Keeps the app theme and font the same on every device signed in to the
/// account, through global account data
/// `net.samrusselltech.parallax.appearance` (`theme`: a theme name or
/// `system`; `font`: an app font ID). Off with
/// [AppearancePreferences.syncAppearance]. Also uploads per-room bubble
/// colours and backgrounds that were changed offline ([RoomThemeSync]).
///
/// The account copy wins unless this device changed the setting and could
/// not upload it yet; then the newer change wins (see [decideSync]).
class AppearanceSync {
  AppearanceSync({
    required Listenable backend,
    required this.preferences,
    required this.currentTheme,
    required this.applyTheme,
    required this.isKnownTheme,
    SyncLedger? ledger,
    int Function()? now,
    RoomThemeSync Function()? roomSync,
  }) : _backend = backend,
       _access = _sdkAccess(backend),
       ledger = ledger ?? SyncLedger.shared,
       _now = now ?? _wallClock,
       _roomSync = roomSync ?? (() => RoomThemeSync(backend));

  static const eventType = 'net.samrusselltech.parallax.appearance';

  final Listenable _backend;
  final MatrixSdkAccess? _access;
  final AppearancePreferences preferences;

  /// This device's theme: a theme name, or `system`.
  final String Function() currentTheme;

  /// Shows and saves a theme that came from another device.
  final Future<void> Function(String theme) applyTheme;

  /// Whether this version has [theme] (a newer one may add themes).
  final bool Function(String theme) isKnownTheme;

  final SyncLedger ledger;
  final int Function() _now;
  final RoomThemeSync Function() _roomSync;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  static MatrixSdkAccess? _sdkAccess(Object backend) =>
      backend is MatrixSdkAccess ? backend : null;

  bool _started = false;
  bool _disposed = false;
  String? _lastFont;
  bool? _lastEnabled;
  matrix.Client? _syncedClient;
  Object? _token = _unread;
  static const _unread = Object();
  bool _queued = false;

  matrix.Client? get _client {
    final client = _access?.sdkClient;
    return client == null || client.userID == null ? null : client;
  }

  bool _current(matrix.Client client) =>
      !_disposed && (_access?.isSessionCurrent(client) ?? false);

  /// Call once the saved theme and preferences are loaded.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _lastFont = preferences.appFont.id;
    _lastEnabled = preferences.syncAppearance;
    _backend.addListener(_backendChanged);
    preferences.addListener(_preferencesChanged);
    _backendChanged();
  }

  void dispose() {
    _disposed = true;
    if (!_started) return;
    _backend.removeListener(_backendChanged);
    preferences.removeListener(_preferencesChanged);
  }

  /// Call after the theme was picked on this device.
  Future<void> themeChanged() => _localChanged();

  /// Uploads changes still waiting (the app came back to the foreground).
  Future<void> retryPending() async {
    final client = _client;
    if (!_started || client == null || !_hasSynced(client)) return;
    await _flush(client);
  }

  static bool _hasSynced(matrix.Client client) => client.onSync.value != null;

  void _backendChanged() {
    if (_disposed) return;
    final client = _client;
    if (client == null || !_hasSynced(client)) return;
    if (!identical(client, _syncedClient)) {
      // A session's first sync: changes made offline can go now.
      _syncedClient = client;
      _token = _unread;
      unawaited(_flush(client));
      return;
    }
    if (identical(client.accountData[eventType], _token)) return;
    unawaited(reconcile());
  }

  Future<void> _flush(matrix.Client client) async {
    _token = client.accountData[eventType];
    await reconcile();
    if (!_current(client)) return;
    try {
      await _roomSync().flushPending();
    } catch (_) {
      // Retried on the next start or resume.
    }
  }

  void _preferencesChanged() {
    if (_disposed) return;
    final enabled = preferences.syncAppearance;
    if (enabled != _lastEnabled) {
      _lastEnabled = enabled;
      if (enabled) unawaited(_resync());
    }
    final font = preferences.appFont.id;
    if (font != _lastFont) {
      _lastFont = font;
      unawaited(_localChanged());
    }
  }

  /// Sync was turned back on: this device takes the account's look, or
  /// uploads its own when the account has none.
  Future<void> _resync() async {
    final client = _client;
    if (client == null) return;
    final userId = client.userID!;
    await SyncSerial.run(SyncLedger.keyFor(userId, eventType), () async {
      final entry = await ledger.read(userId, eventType);
      await ledger.write(entry.copyWith(seen: () => null, pending: () => null));
    });
    await reconcile();
  }

  /// Brings this device's theme and font in line with the account.
  Future<void> reconcile() async {
    final client = _client;
    if (client == null || !preferences.syncAppearance) return;
    final userId = client.userID!;
    final key = SyncLedger.keyFor(userId, eventType);
    try {
      await SyncSerial.run(key, () async {
        _token = client.accountData[eventType];
        final remote = await _remote(client);
        if (!_current(client) || !preferences.syncAppearance) return;
        final entry = await ledger.read(userId, eventType);
        final action = decideSync(
          remote: remote,
          entry: entry,
          hasLocal: true,
          ownWrites: OwnWrites.of(key),
        );
        switch (action) {
          case SyncAction.none:
            return;
          case SyncAction.adoptRemote:
            final theme = remote!['theme'];
            final font = remote['font'];
            if (theme is String &&
                isKnownTheme(theme) &&
                theme != currentTheme()) {
              await applyTheme(theme);
            }
            if (font is String &&
                appFontById(font) != null &&
                font != preferences.appFont.id) {
              _lastFont = font;
              await preferences.setAppFont(font);
            }
            await ledger.write(
              entry.copyWith(
                seen: () => contentHash(remote),
                pending: () => null,
              ),
            );
          case SyncAction.pushLocal:
            if (!_hasSynced(client)) return;
            await _push(client, entry.pending ?? _now());
        }
      });
    } catch (_) {
      // Offline or unreadable: tried again on the next change or start.
    }
  }

  Future<void> _localChanged() async {
    final client = _client;
    if (client == null || !preferences.syncAppearance || _disposed) return;
    final userId = client.userID!;
    final key = SyncLedger.keyFor(userId, eventType);
    try {
      final entry = await ledger.read(userId, eventType);
      await ledger.write(entry.copyWith(pending: _now));
    } catch (_) {
      return;
    }
    if (_queued) return;
    _queued = true;
    unawaited(
      SyncSerial.run(key, () async {
        _queued = false;
        if (!_current(client) || !preferences.syncAppearance) return;
        final entry = await ledger.read(userId, eventType);
        final pending = entry.pending;
        if (pending != null) await _push(client, pending);
      }).catchError((Object _) {
        // Stays pending: retried on the next start or resume.
      }),
    );
  }

  Future<void> _push(matrix.Client client, int updatedAt) async {
    final userId = client.userID!;
    final content = <String, Object?>{
      'version': 1,
      'updatedAt': updatedAt,
      'theme': currentTheme(),
      'font': preferences.appFont.id,
    };
    if (!_current(client)) return;
    await client.request(matrix.RequestType.PUT, _path(userId), data: content);
    if (!_current(client)) return;
    final hash = contentHash(content);
    OwnWrites.add(SyncLedger.keyFor(userId, eventType), hash);
    // Until the sync echo arrives, readers see what was just written.
    final written = matrix.BasicEvent(type: eventType, content: content);
    client.accountData[eventType] = written;
    _token = written;
    final entry = await ledger.read(userId, eventType);
    await ledger.write(
      entry.copyWith(
        seen: () => hash,
        pending: () => entry.pending == updatedAt ? null : entry.pending,
      ),
    );
  }

  static String _path(String userId) =>
      '/client/v3/user/${Uri.encodeComponent(userId)}/account_data/$eventType';

  /// The account's copy (synced, else read from the server); null when the
  /// account has none. Throws when it can't be read.
  Future<Map<String, Object?>?> _remote(matrix.Client client) async {
    final cached = client.accountData[eventType]?.content;
    if (cached != null) return Map<String, Object?>.from(cached);
    // After a sync the synced account data is complete.
    if (_hasSynced(client)) return null;
    try {
      return await client.request(
        matrix.RequestType.GET,
        _path(client.userID!),
      );
    } on matrix.MatrixException catch (error) {
      if (error.error == matrix.MatrixError.M_NOT_FOUND) return null;
      rethrow;
    }
  }
}
