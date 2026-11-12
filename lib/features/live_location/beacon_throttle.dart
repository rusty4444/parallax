// Beacon send throttling for one live share, Flutter-free and clock-free.
import 'dart:math' as math;

import '../polls/location_model.dart';

/// Great-circle distance between two points in metres (haversine).
double distanceMetres(GeoPoint a, GeoPoint b) {
  const earthRadius = 6371000.0;
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLon = rad(b.longitude - a.longitude);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
}

/// Decides when a position fix may be sent as a beacon:
///
/// * the first fix goes out at once;
/// * afterwards at most one beacon per [minInterval] (Element Classic uses
///   5 s);
/// * a fix that moved significantly — at least [minDistanceMetres] and more
///   than its own accuracy radius, so GPS jitter does not count — is sent
///   as soon as [minInterval] allows;
/// * otherwise the newest fix is sent as a heartbeat every [maxInterval];
/// * after a failed send, retries back off exponentially up to [maxBackoff].
///
/// The caller keeps only the newest pending fix and sends it at the time
/// [schedule] returns.
class BeaconThrottle {
  BeaconThrottle({
    this.minInterval = const Duration(seconds: 5),
    this.maxInterval = const Duration(seconds: 30),
    this.minDistanceMetres = 10,
    this.maxBackoff = const Duration(minutes: 2),
  });

  final Duration minInterval;
  final Duration maxInterval;
  final double minDistanceMetres;
  final Duration maxBackoff;

  DateTime? _lastSentAt;
  GeoPoint? _lastSentPoint;
  DateTime? _retryNotBefore;
  int _failures = 0;

  DateTime? get lastSentAt => _lastSentAt;
  int get consecutiveFailures => _failures;

  static DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  /// Whether [point] moved far enough from the last sent position.
  bool isSignificant(GeoPoint point) {
    final last = _lastSentPoint;
    if (last == null) return true;
    final accuracy = (point.uncertainty ?? 0).clamp(0, 100).toDouble();
    final threshold = math.max(minDistanceMetres, accuracy);
    return distanceMetres(last, point) >= threshold;
  }

  /// When [point], offered at [now], should be sent: [now] for immediately,
  /// otherwise the time to send it (or a newer fix offered meanwhile).
  DateTime schedule(GeoPoint point, DateTime now) {
    final retry = _retryNotBefore;
    final last = _lastSentAt;
    var due = last == null
        ? now
        : (isSignificant(point)
              ? last.add(minInterval)
              : last.add(maxInterval));
    if (retry != null) due = _later(due, retry);
    return due.isAfter(now) ? due : now;
  }

  /// Records a successful send.
  void sent(GeoPoint point, DateTime at) {
    _lastSentAt = at;
    _lastSentPoint = point;
    _failures = 0;
    _retryNotBefore = null;
  }

  /// Records a failed send; the next attempt waits 5 s, 10 s, 20 s … up to
  /// [maxBackoff].
  void failed(DateTime at) {
    _failures++;
    final factor = 1 << math.min(_failures - 1, 16);
    final backoff = minInterval * factor;
    _retryNotBefore = at.add(backoff > maxBackoff ? maxBackoff : backoff);
  }
}
