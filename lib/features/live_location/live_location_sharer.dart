import 'dart:async';

import 'package:flutter/foundation.dart';

import 'beacon_throttle.dart';
import 'live_location_model.dart';
import 'live_share_store.dart';
import 'position_source.dart';

/// Time source and timers, injectable for tests.
abstract interface class LiveClock {
  DateTime now();
  Timer timer(Duration delay, void Function() callback);
}

class SystemLiveClock implements LiveClock {
  const SystemLiveClock();
  @override
  DateTime now() => DateTime.now();
  @override
  Timer timer(Duration delay, void Function() callback) =>
      Timer(delay.isNegative ? Duration.zero : delay, callback);
}

/// A failed write. [fatal] failures (not joined, no permission, encryption
/// unavailable, the user declined the recipient-trust prompt) stop the share;
/// others are retried with backoff.
class LiveLocationSendException implements Exception {
  const LiveLocationSendException(this.message, {required this.fatal});
  final String message;
  final bool fatal;

  @override
  String toString() => 'LiveLocationSendException($message, fatal: $fatal)';
}

/// Room writes needed by [LiveLocationSharer]; the Matrix implementation
/// wraps `RoomEventFeatures`.
abstract interface class LiveLocationTransport {
  /// Writes a new `beacon_info` and resolves with its event ID once the
  /// homeserver echoed it into room state.
  Future<String> startBeaconInfo(String roomId, Map<String, Object?> content);

  /// Overwrites the own `beacon_info` (used to stop: `live: false`).
  Future<void> writeBeaconInfo(String roomId, Map<String, Object?> content);

  /// Sends one `beacon`; returns its event ID.
  Future<String> sendBeacon(String roomId, Map<String, Object?> content);

  /// The own current `beacon_info` content from the homeserver, or null when
  /// there is none.
  Future<Map<String, Object?>?> ownBeaconInfo(String roomId);
}

enum OwnShareStatus { starting, active }

/// Read-only view of one share this device is running.
@immutable
class OwnShare {
  const OwnShare({
    required this.roomId,
    required this.status,
    required this.start,
    required this.expiresAt,
    this.beaconInfoId,
    this.lastSentAt,
    this.retrying = false,
  });

  final String roomId;
  final OwnShareStatus status;
  final String? beaconInfoId;
  final DateTime start;
  final DateTime expiresAt;
  final DateTime? lastSentAt;

  /// The last beacon failed; Parallax keeps retrying until the share ends.
  final bool retrying;
}

class _Share {
  _Share({
    required this.roomId,
    required this.content,
    required this.start,
    required this.timeout,
    required this.throttle,
    this.beaconInfoId,
  });

  final String roomId;
  final Map<String, Object?> content;
  final DateTime start;
  final Duration timeout;
  final BeaconThrottle throttle;
  String? beaconInfoId;
  bool cancelled = false;
  bool inFlight = false;
  bool retrying = false;
  PositionFix? pending;
  Timer? flushTimer;
  Timer? expiryTimer;

  bool get active => beaconInfoId != null && !cancelled;
  DateTime get expiresAt => start.add(timeout);

  void cancelTimers() {
    flushTimer?.cancel();
    flushTimer = null;
    expiryTimer?.cancel();
    expiryTimer = null;
  }

  OwnShare get view => OwnShare(
    roomId: roomId,
    status: beaconInfoId == null
        ? OwnShareStatus.starting
        : OwnShareStatus.active,
    beaconInfoId: beaconInfoId,
    start: start,
    expiresAt: expiresAt,
    lastSentAt: throttle.lastSentAt,
    retrying: retrying,
  );
}

/// Runs this device's live shares for one signed-in session.
///
/// State machine per room: none → starting (beacon_info written, waiting
/// for its echo) → active (position updates are throttled into beacons) →
/// none, on Stop, on expiry (writes `live: false`), when another device
/// replaces or stops the share (local only), on sign-out ([stopAll]) or when
/// location permission is revoked. Active shares are persisted per account
/// so [resume] can continue them after Parallax restarts.
///
/// One device position stream serves every room; each room has its own
/// throttle and at most one beacon in flight (newer fixes replace the
/// pending one). Beacons carry the send time as `org.matrix.msc3488.ts`, as
/// Element does, so the timestamp is on the same clock as the share's start.
class LiveLocationSharer extends ChangeNotifier {
  LiveLocationSharer({
    required this.transport,
    required this.positions,
    required this.store,
    required this.accountKey,
    this.clock = const SystemLiveClock(),
    BeaconThrottle Function()? throttleFactory,
  }) : _throttleFactory = throttleFactory ?? BeaconThrottle.new;

  final LiveLocationTransport transport;
  final LivePositionSource positions;
  final LiveShareStore store;
  final String accountKey;
  final LiveClock clock;
  final BeaconThrottle Function() _throttleFactory;

  /// Fixes older than this are not sent.
  static const maxFixAge = Duration(minutes: 2);

  /// Delay before re-opening the position stream after a non-fatal error.
  static const streamRetryDelay = Duration(seconds: 30);

  /// Bound on stop writes during sign-out.
  static const stopAllTimeout = Duration(seconds: 8);

  final _shares = <String, _Share>{};
  StreamSubscription<PositionFix>? _positions;
  Timer? _streamRetry;
  PositionFix? _lastFix;
  bool _disposed = false;
  Future<void> _persisting = Future<void>.value();

  bool get disposed => _disposed;

  /// Shares this device is running (starting or active), by room.
  Map<String, OwnShare> get shares => {
    for (final share in _shares.values) share.roomId: share.view,
  };

  OwnShare? shareIn(String roomId) => _shares[roomId]?.view;

  /// Active shares as records (what [stopAll] would end).
  List<PersistedShare> get activeRecords => [
    for (final share in _shares.values)
      if (share.active)
        PersistedShare(
          roomId: share.roomId,
          beaconInfoId: share.beaconInfoId!,
          content: share.content,
        ),
  ];

  bool get tracking => _positions != null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // --- Start / stop -----------------------------------------------------

  /// Starts sharing in [roomId] for [duration]. Location permission must
  /// already be granted (the UI asks first). Replaces a share this device
  /// was already running in the room.
  Future<void> start(String roomId, Duration duration) async {
    if (_disposed) throw StateError('Live location is no longer available');
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration');
    }
    final existing = _shares[roomId];
    if (existing != null && existing.beaconInfoId == null) {
      throw StateError('Live location is already starting in this room');
    }
    final now = clock.now();
    final content = beaconInfoStartContent(timeout: duration, now: now);
    final share = _Share(
      roomId: roomId,
      content: content,
      start: now,
      timeout: duration,
      throttle: _throttleFactory(),
    );
    // Register first so dropping the replaced share keeps the stream.
    _shares[roomId] = share;
    if (existing != null) _drop(existing);
    _notify();
    final String eventId;
    try {
      eventId = await transport.startBeaconInfo(roomId, content);
    } catch (_) {
      if (identical(_shares[roomId], share)) {
        _shares.remove(roomId);
        _stopStreamIfIdle();
        _notify();
      }
      rethrow;
    }
    if (_disposed || share.cancelled || !identical(_shares[roomId], share)) {
      // Stopped (or the session ended) while the write was in flight: the
      // share now exists on the server, so end it there too.
      if (share.cancelled) {
        await _writeStop(roomId, content, swallow: true);
      }
      return;
    }
    share.beaconInfoId = eventId;
    _arm(share);
    _persist();
    _notify();
    final fix = _lastFix;
    if (fix != null &&
        clock.now().difference(fix.receivedAt) < const Duration(seconds: 30)) {
      _offer(share, fix);
    }
  }

  /// Stops sharing in [roomId]. Local updates stop at once; then the share is
  /// ended on the server (`live: false`). With no local share (started on
  /// another device) the server's current own share is ended instead.
  Future<void> stop(String roomId) async {
    if (_disposed) throw StateError('Live location is no longer available');
    final share = _shares[roomId];
    if (share == null) {
      final current = await transport.ownBeaconInfo(roomId);
      if (current == null || current['live'] != true) return;
      await _writeStop(roomId, current, swallow: false);
      return;
    }
    _drop(share);
    _persist();
    _notify();
    // A share still starting is ended by start() once its event exists.
    if (share.beaconInfoId == null) return;
    await _writeStop(roomId, share.content, swallow: false);
  }

  /// Stops every share (sign-out). Writes are bounded by [stopAllTimeout];
  /// the persisted record is cleared either way.
  Future<void> stopAll() async {
    final all = _shares.values.toList();
    for (final share in all) {
      _drop(share);
    }
    _notify();
    final writes = [
      for (final share in all)
        if (share.beaconInfoId != null)
          _writeStop(share.roomId, share.content, swallow: true),
    ];
    try {
      await Future.wait(writes).timeout(stopAllTimeout);
    } catch (_) {
      // Best effort: the server ends the shares at their timeout anyway.
    }
    try {
      await _persisting;
      await store.clear(accountKey);
    } catch (_) {}
  }

  Future<void> _writeStop(
    String roomId,
    Map<String, Object?> started, {
    required bool swallow,
  }) async {
    try {
      await transport.writeBeaconInfo(roomId, beaconInfoStopContent(started));
    } catch (_) {
      if (!swallow) rethrow;
    }
  }

  /// Removes [share] locally (no server write).
  void _drop(_Share share) {
    share.cancelled = true;
    share.cancelTimers();
    share.pending = null;
    if (identical(_shares[share.roomId], share)) _shares.remove(share.roomId);
    _stopStreamIfIdle();
  }

  /// Another device (or client) replaced or stopped the own share in
  /// [roomId]: stop sending there without writing anything.
  void ownBeaconInfoChanged(String roomId, BeaconInfo info) {
    final share = _shares[roomId];
    if (share == null || share.beaconInfoId == null) return;
    if (info.eventId == share.beaconInfoId) return;
    final startMillis = beaconInfoStartMillis(share.content);
    final infoMillis = info.start.millisecondsSinceEpoch;
    final newer = startMillis == null || infoMillis > startMillis;
    final stoppedSame = infoMillis == startMillis && !info.live;
    if (!newer && !stoppedSame) return; // an older event replayed
    _drop(share);
    _persist();
    _notify();
  }

  // --- Expiry -----------------------------------------------------------

  void _arm(_Share share) {
    share.expiryTimer?.cancel();
    share.expiryTimer = clock.timer(
      share.expiresAt.difference(clock.now()),
      () => unawaited(_expire(share)),
    );
    _ensureStream();
  }

  Future<void> _expire(_Share share) async {
    if (share.cancelled || !identical(_shares[share.roomId], share)) return;
    _drop(share);
    _persist();
    _notify();
    await _writeStop(share.roomId, share.content, swallow: true);
  }

  // --- Resume -----------------------------------------------------------

  /// Continues shares this device started before Parallax restarted: each
  /// persisted share that has not expired and is still the live
  /// `beacon_info` on the server resumes without prompting. Expired ones are
  /// ended on the server; a share whose location permission was revoked is
  /// stopped (Parallax never prompts in the background). Shares started on
  /// other devices are left to them.
  Future<void> resume() async {
    if (_disposed) return;
    final records = await store.load(accountKey);
    if (_disposed || records.isEmpty) return;
    LocationAccess? access;
    var changed = false;
    for (final record in records) {
      if (_disposed) return;
      if (_shares.containsKey(record.roomId)) continue;
      final start = DateTime.fromMillisecondsSinceEpoch(record.startMillis!);
      final timeout = Duration(milliseconds: record.timeoutMillis!);
      if (!clock.now().isBefore(start.add(timeout))) {
        await _writeStop(record.roomId, record.content, swallow: true);
        changed = true;
        continue;
      }
      Map<String, Object?>? server;
      var confirmed = true;
      try {
        server = await transport.ownBeaconInfo(record.roomId);
      } catch (_) {
        // Offline: trust the local record; a newer share arriving by sync
        // still replaces it (ownBeaconInfoChanged).
        confirmed = false;
      }
      if (_disposed) return;
      if (confirmed &&
          (server == null ||
              server['live'] != true ||
              beaconInfoStartMillis(server) != record.startMillis)) {
        changed = true; // stopped or replaced elsewhere
        continue;
      }
      access ??= await positions.check();
      if (_disposed) return;
      if (access == LocationAccess.denied ||
          access == LocationAccess.deniedForever) {
        await _writeStop(record.roomId, record.content, swallow: true);
        changed = true;
        continue;
      }
      if (_shares.containsKey(record.roomId)) continue;
      final share = _Share(
        roomId: record.roomId,
        content: record.content,
        start: start,
        timeout: timeout,
        throttle: _throttleFactory(),
        beaconInfoId: record.beaconInfoId,
      );
      _shares[record.roomId] = share;
      _arm(share);
      changed = true;
    }
    if (changed) {
      _persist();
      _notify();
    }
  }

  void _persist() {
    if (_disposed) return;
    final snapshot = activeRecords;
    // Serialise writes so an older snapshot can never land last.
    _persisting = _persisting.then((_) async {
      try {
        await store.save(accountKey, snapshot);
      } catch (_) {}
    });
  }

  /// Completes when pending persistence writes have finished.
  @visibleForTesting
  Future<void> get persisted => _persisting;

  // --- Positions --------------------------------------------------------

  void _ensureStream() {
    if (_disposed || _positions != null || _streamRetry != null) return;
    if (!_shares.values.any((s) => s.active)) return;
    _positions = positions.watch().listen(
      _onFix,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: true,
    );
  }

  void _stopStreamIfIdle() {
    if (_shares.values.any((s) => !s.cancelled)) return;
    _streamRetry?.cancel();
    _streamRetry = null;
    final subscription = _positions;
    _positions = null;
    _lastFix = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void _onStreamError(Object error) {
    _positions = null;
    if (_disposed) return;
    final access = error is PositionStreamException ? error.access : null;
    if (access == LocationAccess.denied ||
        access == LocationAccess.deniedForever) {
      // Permission revoked while sharing: end every share.
      for (final share in _shares.values.toList()) {
        if (share.active) unawaited(_expire(share));
      }
      return;
    }
    _scheduleStreamRetry();
  }

  void _onStreamDone() {
    _positions = null;
    if (!_disposed) _scheduleStreamRetry();
  }

  void _scheduleStreamRetry() {
    if (_streamRetry != null || !_shares.values.any((s) => s.active)) return;
    _streamRetry = clock.timer(streamRetryDelay, () {
      _streamRetry = null;
      _ensureStream();
    });
  }

  void _onFix(PositionFix fix) {
    if (_disposed) return;
    _lastFix = fix;
    for (final share in _shares.values.toList()) {
      if (share.active) _offer(share, fix);
    }
  }

  void _offer(_Share share, PositionFix fix) {
    share.pending = fix;
    if (share.inFlight) return; // sent after the current beacon settles
    final now = clock.now();
    final due = share.throttle.schedule(fix.point, now);
    share.flushTimer?.cancel();
    share.flushTimer = null;
    if (!due.isAfter(now)) {
      unawaited(_flush(share));
    } else {
      share.flushTimer = clock.timer(
        due.difference(now),
        () => unawaited(_flush(share)),
      );
    }
  }

  Future<void> _flush(_Share share) async {
    share.flushTimer?.cancel();
    share.flushTimer = null;
    final fix = share.pending;
    if (fix == null || share.inFlight || !share.active || _disposed) return;
    if (!identical(_shares[share.roomId], share)) return;
    final now = clock.now();
    if (!now.isBefore(share.expiresAt)) {
      await _expire(share);
      return;
    }
    share.pending = null;
    if (now.difference(fix.receivedAt) > maxFixAge) return; // stale
    share.inFlight = true;
    try {
      await transport.sendBeacon(
        share.roomId,
        beaconContent(
          beaconInfoId: share.beaconInfoId!,
          point: fix.point,
          measuredAt: now,
        ),
      );
      if (!_current(share)) return;
      // Spacing is measured between send attempts, so a beacon held up (for
      // example by a trust prompt) does not delay the next one further.
      share.throttle.sent(fix.point, now);
      share.retrying = false;
      _notify();
    } on LiveLocationSendException catch (error) {
      if (!_current(share)) return;
      if (error.fatal) {
        await _expire(share);
        return;
      }
      _failed(share, fix);
    } catch (_) {
      if (_current(share)) _failed(share, fix);
    } finally {
      share.inFlight = false;
      final next = share.pending;
      if (_current(share) && next != null) _offer(share, next);
    }
  }

  bool _current(_Share share) =>
      !_disposed && share.active && identical(_shares[share.roomId], share);

  void _failed(_Share share, PositionFix fix) {
    share.throttle.failed(clock.now());
    share.retrying = true;
    share.pending ??= fix; // retry this fix unless a newer one arrived
    _notify();
  }

  /// Stops local work for this session without writing anything (the
  /// session ended or the app is closing). Persisted shares remain for
  /// [resume].
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final share in _shares.values) {
      share.cancelled = true;
      share.cancelTimers();
    }
    _shares.clear();
    _streamRetry?.cancel();
    _streamRetry = null;
    final subscription = _positions;
    _positions = null;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}
