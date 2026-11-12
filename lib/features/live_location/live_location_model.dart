// Live location sharing model (MSC3488/MSC3489/MSC3672), Flutter-free.
//
// A live share is a `beacon_info` state event whose state key is the sharer's
// user ID; position updates are `beacon` message events that reference it
// (`m.reference`). Parallax sends the unstable types Element Web/Classic and
// Element X send today and reads both the stable and unstable forms.
import 'package:flutter/foundation.dart';

import '../polls/location_model.dart';

const beaconInfoUnstableType = 'org.matrix.msc3672.beacon_info';
const beaconInfoStableType = 'm.beacon_info';
const beaconUnstableType = 'org.matrix.msc3672.beacon';
const beaconStableType = 'm.beacon';

const beaconInfoEventTypes = {beaconInfoUnstableType, beaconInfoStableType};
const beaconEventTypes = {beaconUnstableType, beaconStableType};

const _tsUnstable = 'org.matrix.msc3488.ts';
const _tsStable = 'm.ts';
const _assetUnstable = 'org.matrix.msc3488.asset';
const _locationUnstable = 'org.matrix.msc3488.location';
const _locationStable = 'm.location';
const referenceRelation = 'm.reference';

/// Element Web/X default description; the state event is cleartext.
const liveLocationDescription = 'Live location';

/// matrix-js-sdk tolerates a start timestamp up to six minutes in the future
/// (the sharer's clock may be ahead of ours).
const beaconClockSkew = Duration(minutes: 6);

/// Upper bound for a received timeout so arithmetic cannot overflow.
const _maxTimeout = Duration(days: 365);
const _maxDescriptionLength = 200;

/// Year 9999: later timestamps are malformed (and would throw in DateTime).
const _maxEpochMillis = 253402300799000;

/// The share durations Element offers.
enum LiveShareDuration {
  fifteenMinutes(Duration(minutes: 15), '15 minutes'),
  oneHour(Duration(hours: 1), '1 hour'),
  eightHours(Duration(hours: 8), '8 hours');

  const LiveShareDuration(this.duration, this.label);
  final Duration duration;
  final String label;
}

/// Whether a `beacon_info` state key belongs to [sender]: the user ID itself
/// (MSC3672) or an owned `@user:server_suffix` key (MSC3757).
bool beaconStateKeyOwnedBy(String stateKey, String sender) =>
    sender.startsWith('@') &&
    (stateKey == sender || stateKey.startsWith('${sender}_'));

int? _intOf(Object? value) => value is int
    ? value
    : value is double && value.isFinite && value == value.roundToDouble()
    ? value.toInt()
    : null;

/// A parsed `beacon_info` state event.
@immutable
class BeaconInfo {
  const BeaconInfo({
    required this.eventId,
    required this.type,
    required this.stateKey,
    required this.sender,
    required this.live,
    required this.start,
    required this.timeout,
    required this.sentAt,
    this.description,
  });

  final String eventId;
  final String type;
  final String stateKey;
  final String sender;
  final bool live;

  /// When sharing started (`org.matrix.msc3488.ts`, else origin_server_ts).
  final DateTime start;
  final Duration timeout;

  /// Server timestamp of this state event (orders start and stop events).
  final DateTime sentAt;
  final String? description;

  DateTime get expiresAt => start.add(timeout);

  /// MSC3489 liveness: `live` is set and [now] lies inside the share's
  /// period (with matrix-js-sdk's leniency for a future start). Whether a
  /// later `beacon_info` replaced this one is checked separately.
  bool isLiveAt(DateTime now) =>
      live &&
      !now.isBefore(start.subtract(beaconClockSkew)) &&
      now.isBefore(expiresAt);

  /// Whether a beacon measured at [timestamp] belongs to this share: only
  /// positions taken inside the live period count (matrix-js-sdk rule).
  bool acceptsTimestamp(DateTime timestamp) =>
      !timestamp.isBefore(start.subtract(beaconClockSkew)) &&
      !timestamp.isAfter(expiresAt);

  /// Parses a received `beacon_info`. Returns null for anything malformed,
  /// with a non-positive timeout, or whose state key the sender does not own.
  static BeaconInfo? fromEvent({
    required String eventId,
    required String type,
    required String? stateKey,
    required String sender,
    required Map<String, Object?> content,
    required DateTime originServerTs,
  }) {
    if (!beaconInfoEventTypes.contains(type) || stateKey == null) return null;
    if (!beaconStateKeyOwnedBy(stateKey, sender)) return null;
    final timeoutMs = _intOf(content['timeout']);
    if (timeoutMs == null || timeoutMs <= 0) return null;
    final ts = _intOf(content[_tsUnstable]) ?? _intOf(content[_tsStable]);
    final start = ts != null && ts > 0 && ts < _maxEpochMillis
        ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
        : originServerTs.toUtc();
    // Clamp before converting: Duration stores microseconds and a huge
    // millisecond value would overflow.
    final timeout = Duration(
      milliseconds: timeoutMs > _maxTimeout.inMilliseconds
          ? _maxTimeout.inMilliseconds
          : timeoutMs,
    );
    final description = content['description'];
    return BeaconInfo(
      eventId: eventId,
      type: type,
      stateKey: stateKey,
      sender: sender,
      live: content['live'] == true,
      start: start,
      timeout: timeout,
      sentAt: originServerTs.toUtc(),
      description: description is String && description.trim().isNotEmpty
          ? _truncate(description.trim(), _maxDescriptionLength)
          : null,
    );
  }
}

String _truncate(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);

/// Content for a new live share, as Element sends it.
Map<String, Object?> beaconInfoStartContent({
  required Duration timeout,
  required DateTime now,
  String description = liveLocationDescription,
}) => {
  'description': description,
  'live': true,
  'timeout': timeout.inMilliseconds,
  _tsUnstable: now.millisecondsSinceEpoch,
  _assetUnstable: {'type': 'm.self'},
};

/// Stopping rewrites the same content with `live: false` (Element Classic
/// `StopLiveLocationShareTask`).
Map<String, Object?> beaconInfoStopContent(Map<String, Object?> started) => {
  ...started,
  'live': false,
};

/// Start timestamp of beacon_info [content], for matching echoes/records.
int? beaconInfoStartMillis(Map<String, Object?> content) =>
    _intOf(content[_tsUnstable]) ?? _intOf(content[_tsStable]);

/// A parsed `beacon` (location update).
@immutable
class BeaconLocation {
  const BeaconLocation({
    required this.eventId,
    required this.sender,
    required this.beaconInfoId,
    required this.point,
    required this.timestamp,
  });

  final String eventId;
  final String sender;
  final String beaconInfoId;
  final GeoPoint point;

  /// When the position was measured (`org.matrix.msc3488.ts`).
  final DateTime timestamp;

  /// Parses a received beacon. The relation must be an `m.reference` and the
  /// location a valid WGS84 `geo:` URI.
  static BeaconLocation? fromEvent({
    required String eventId,
    required String type,
    required String sender,
    required Map<String, Object?> content,
    required DateTime originServerTs,
  }) {
    if (!beaconEventTypes.contains(type)) return null;
    final relation = content['m.relates_to'];
    if (relation is! Map || relation['rel_type'] != referenceRelation) {
      return null;
    }
    final target = relation['event_id'];
    if (target is! String || !target.startsWith(r'$')) return null;
    final block = content[_locationUnstable] ?? content[_locationStable];
    if (block is! Map) return null;
    final point = GeoPoint.tryParse(block['uri']);
    if (point == null) return null;
    final ts = _intOf(content[_tsUnstable]) ?? _intOf(content[_tsStable]);
    return BeaconLocation(
      eventId: eventId,
      sender: sender,
      beaconInfoId: target,
      point: point,
      timestamp: ts != null && ts > 0 && ts < _maxEpochMillis
          ? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
          : originServerTs.toUtc(),
    );
  }
}

/// Content for a location update referencing [beaconInfoId].
///
/// In an encrypted room the location and timestamp are a non-empty payload,
/// so Matrix SDK 14.1 encrypts the beacon to `m.room.encrypted` and copies
/// only `m.relates_to` to the cleartext envelope (unlike a relation-only
/// reaction, which it would leave in plaintext).
Map<String, Object?> beaconContent({
  required String beaconInfoId,
  required GeoPoint point,
  required DateTime measuredAt,
}) => {
  'm.relates_to': {'rel_type': referenceRelation, 'event_id': beaconInfoId},
  _locationUnstable: {'uri': point.toGeoUri()},
  _tsUnstable: measuredAt.millisecondsSinceEpoch,
};

/// The latest valid beacon of one live share.
class BeaconAggregate {
  BeaconAggregate(this.info);

  final BeaconInfo info;
  BeaconLocation? _latest;

  BeaconLocation? get latest => _latest;

  /// Offers a received beacon; returns whether it became the latest. Only
  /// the sharer's own beacons, taken inside the live period and newer than
  /// the current latest, are accepted.
  bool offer(BeaconLocation beacon) {
    if (beacon.beaconInfoId != info.eventId) return false;
    if (beacon.sender != info.sender) return false;
    if (!info.acceptsTimestamp(beacon.timestamp)) return false;
    final current = _latest;
    if (current != null) {
      if (current.eventId == beacon.eventId) return false;
      if (!beacon.timestamp.isAfter(current.timestamp)) return false;
    }
    _latest = beacon;
    return true;
  }

  /// Drops a redacted beacon. The previous position is not restored; the
  /// next beacon replaces it.
  bool remove(String eventId) {
    if (_latest?.eventId != eventId) return false;
    _latest = null;
    return true;
  }
}

/// Of several `beacon_info` state events for one state key (stable and
/// unstable types), the current one is the most recently sent.
BeaconInfo? currentBeaconInfo(Iterable<BeaconInfo> candidates) {
  BeaconInfo? best;
  for (final info in candidates) {
    if (best == null ||
        info.sentAt.isAfter(best.sentAt) ||
        (info.sentAt == best.sentAt &&
            info.eventId.compareTo(best.eventId) > 0)) {
      best = info;
    }
  }
  return best;
}
