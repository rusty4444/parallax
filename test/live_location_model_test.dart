import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/live_location/beacon_throttle.dart';
import 'package:parallax/features/live_location/live_location_format.dart';
import 'package:parallax/features/live_location/live_location_model.dart';
import 'package:parallax/features/live_location/live_share_store.dart';
import 'package:parallax/features/polls/location_model.dart';

const _alice = '@alice:example.org';
const _bob = '@bob:example.org';
final _start = DateTime.utc(2026, 11, 12, 4);

BeaconInfo _info({
  String id = r'$info',
  String type = beaconInfoUnstableType,
  String sender = _alice,
  String? stateKey,
  Map<String, Object?>? content,
  DateTime? sentAt,
}) => BeaconInfo.fromEvent(
  eventId: id,
  type: type,
  stateKey: stateKey ?? sender,
  sender: sender,
  content:
      content ??
      beaconInfoStartContent(timeout: const Duration(hours: 1), now: _start),
  originServerTs: sentAt ?? _start,
)!;

BeaconLocation _beacon(
  String id, {
  String sender = _alice,
  String target = r'$info',
  required DateTime at,
  GeoPoint point = const GeoPoint(-33.8688, 151.2093),
}) => BeaconLocation.fromEvent(
  eventId: id,
  type: beaconUnstableType,
  sender: sender,
  content: beaconContent(beaconInfoId: target, point: point, measuredAt: at),
  originServerTs: at,
)!;

void main() {
  group('event content', () {
    test('beacon_info start matches Element (unstable keys, m.self)', () {
      expect(
        beaconInfoStartContent(timeout: const Duration(hours: 8), now: _start),
        {
          'description': 'Live location',
          'live': true,
          'timeout': 28800000,
          'org.matrix.msc3488.ts': _start.millisecondsSinceEpoch,
          'org.matrix.msc3488.asset': {'type': 'm.self'},
        },
      );
    });

    test('stop keeps everything but live', () {
      final started = beaconInfoStartContent(
        timeout: const Duration(minutes: 15),
        now: _start,
      );
      final stopped = beaconInfoStopContent(started);
      expect(stopped['live'], isFalse);
      expect({...stopped}..remove('live'), {...started}..remove('live'));
    });

    test('beacon references the beacon_info and carries location + ts', () {
      final content = beaconContent(
        beaconInfoId: r'$info',
        point: const GeoPoint(-33.8688, 151.2093, uncertainty: 12),
        measuredAt: _start,
      );
      expect(content, {
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$info'},
        'org.matrix.msc3488.location': {
          'uri': 'geo:-33.868800,151.209300;u=12',
        },
        'org.matrix.msc3488.ts': _start.millisecondsSinceEpoch,
      });
      // Not relation-only: SDK 14.1 encrypts it in encrypted rooms.
      expect(content.keys.where((k) => k != 'm.relates_to'), isNotEmpty);
    });

    test('the unstable types are sent and both forms are read', () {
      expect(beaconInfoUnstableType, 'org.matrix.msc3672.beacon_info');
      expect(beaconUnstableType, 'org.matrix.msc3672.beacon');
      expect(beaconInfoEventTypes, contains('m.beacon_info'));
      expect(beaconEventTypes, contains('m.beacon'));
    });
  });

  group('BeaconInfo', () {
    test('parses unstable and stable (m.ts) forms', () {
      final unstable = _info();
      expect(unstable.live, isTrue);
      expect(unstable.start, _start);
      expect(unstable.timeout, const Duration(hours: 1));
      expect(unstable.description, 'Live location');
      final stable = _info(
        type: beaconInfoStableType,
        content: {
          'live': true,
          'timeout': 60000,
          'm.ts': _start.millisecondsSinceEpoch,
        },
      );
      expect(stable.start, _start);
      expect(stable.timeout, const Duration(minutes: 1));
    });

    test('falls back to the server timestamp without a start ts', () {
      final info = _info(
        content: {'live': true, 'timeout': 60000},
        sentAt: _start.add(const Duration(minutes: 3)),
      );
      expect(info.start, _start.add(const Duration(minutes: 3)));
    });

    test('rejects state keys the sender does not own', () {
      expect(
        BeaconInfo.fromEvent(
          eventId: r'$x',
          type: beaconInfoUnstableType,
          stateKey: _bob,
          sender: _alice,
          content: beaconInfoStartContent(
            timeout: const Duration(hours: 1),
            now: _start,
          ),
          originServerTs: _start,
        ),
        isNull,
      );
      // MSC3757 owned suffix.
      expect(
        _info(stateKey: '${_alice}_beacon1').stateKey,
        '${_alice}_beacon1',
      );
    });

    test('rejects missing, zero or non-integer timeouts; clamps huge ones', () {
      for (final timeout in [null, 0, -5, 'soon', 1.5]) {
        expect(
          BeaconInfo.fromEvent(
            eventId: r'$x',
            type: beaconInfoUnstableType,
            stateKey: _alice,
            sender: _alice,
            content: {'live': true, 'timeout': timeout},
            originServerTs: _start,
          ),
          isNull,
          reason: '$timeout',
        );
      }
      final huge = _info(content: {'live': true, 'timeout': 1 << 62});
      expect(huge.timeout, const Duration(days: 365));
    });

    test('liveness: live flag, period and future-start leniency', () {
      final info = _info();
      expect(info.isLiveAt(_start), isTrue);
      expect(info.isLiveAt(_start.add(const Duration(minutes: 59))), isTrue);
      expect(info.isLiveAt(_start.add(const Duration(hours: 1))), isFalse);
      expect(
        info.isLiveAt(_start.subtract(const Duration(minutes: 5))),
        isTrue,
        reason: "sharer's clock slightly ahead",
      );
      expect(
        info.isLiveAt(_start.subtract(const Duration(minutes: 7))),
        isFalse,
      );
      final stopped = _info(
        content: beaconInfoStopContent(
          beaconInfoStartContent(
            timeout: const Duration(hours: 1),
            now: _start,
          ),
        ),
      );
      expect(stopped.isLiveAt(_start), isFalse);
    });

    test('current beacon_info is the most recently sent', () {
      final start = _info(id: r'$start');
      final stop = _info(
        id: r'$stop',
        type: beaconInfoStableType,
        sentAt: _start.add(const Duration(minutes: 5)),
        content: beaconInfoStopContent(
          beaconInfoStartContent(
            timeout: const Duration(hours: 1),
            now: _start,
          ),
        ),
      );
      expect(currentBeaconInfo([start, stop])?.eventId, r'$stop');
      expect(currentBeaconInfo([stop, start])?.eventId, r'$stop');
    });
  });

  group('BeaconLocation', () {
    test('parses unstable and stable keys', () {
      final unstable = _beacon(r'$b', at: _start);
      expect(unstable.beaconInfoId, r'$info');
      expect(unstable.point.latitude, closeTo(-33.8688, 1e-9));
      final stable = BeaconLocation.fromEvent(
        eventId: r'$s',
        type: beaconStableType,
        sender: _alice,
        content: {
          'm.relates_to': {'rel_type': 'm.reference', 'event_id': r'$info'},
          'm.location': {'uri': 'geo:51.5,-0.12'},
          'm.ts': _start.millisecondsSinceEpoch,
        },
        originServerTs: _start,
      );
      expect(stable?.point.longitude, -0.12);
      expect(stable?.timestamp, _start);
    });

    test('rejects other relations, bad URIs and other types', () {
      Map<String, Object?> content({
        Object? rel = 'm.reference',
        Object? uri = 'geo:1,2',
      }) => {
        'm.relates_to': {'rel_type': rel, 'event_id': r'$info'},
        'org.matrix.msc3488.location': {'uri': uri},
        'org.matrix.msc3488.ts': 1,
      };
      BeaconLocation? parse(Map<String, Object?> c, {String? type}) =>
          BeaconLocation.fromEvent(
            eventId: r'$b',
            type: type ?? beaconUnstableType,
            sender: _alice,
            content: c,
            originServerTs: _start,
          );
      expect(parse(content()), isNotNull);
      expect(parse(content(rel: 'm.annotation')), isNull);
      expect(parse(content(uri: 'geo:200,2')), isNull);
      expect(parse(content(uri: 'https://evil.example')), isNull);
      expect(parse(content(), type: 'm.room.message'), isNull);
    });
  });

  group('BeaconAggregate', () {
    test('keeps the newest beacon from the sharer inside the period', () {
      final aggregate = BeaconAggregate(_info());
      final first = _beacon(r'$1', at: _start.add(const Duration(minutes: 1)));
      final second = _beacon(r'$2', at: _start.add(const Duration(minutes: 2)));
      expect(aggregate.offer(second), isTrue);
      expect(aggregate.offer(first), isFalse, reason: 'older');
      expect(aggregate.offer(second), isFalse, reason: 'duplicate');
      expect(aggregate.latest?.eventId, r'$2');
    });

    test('ignores beacons from others, for other shares or out of period', () {
      final aggregate = BeaconAggregate(_info());
      final mid = _start.add(const Duration(minutes: 30));
      expect(aggregate.offer(_beacon(r'$bob', sender: _bob, at: mid)), isFalse);
      expect(
        aggregate.offer(_beacon(r'$other', target: r'$x', at: mid)),
        isFalse,
      );
      expect(
        aggregate.offer(
          _beacon(r'$late', at: _start.add(const Duration(minutes: 61))),
        ),
        isFalse,
        reason: 'after expiry',
      );
      expect(
        aggregate.offer(
          _beacon(r'$early', at: _start.subtract(const Duration(minutes: 10))),
        ),
        isFalse,
        reason: 'before start',
      );
      expect(aggregate.latest, isNull);
      expect(aggregate.offer(_beacon(r'$ok', at: mid)), isTrue);
    });

    test('a redacted latest beacon is dropped', () {
      final aggregate = BeaconAggregate(_info())
        ..offer(_beacon(r'$1', at: _start.add(const Duration(minutes: 1))));
      expect(aggregate.remove(r'$other'), isFalse);
      expect(aggregate.remove(r'$1'), isTrue);
      expect(aggregate.latest, isNull);
    });
  });

  group('BeaconThrottle', () {
    const here = GeoPoint(-33.8688, 151.2093);
    const near = GeoPoint(-33.8688, 151.20935); // ~4.6 m
    const far = GeoPoint(-33.8688, 151.2103); // ~92 m

    test('distanceMetres', () {
      expect(distanceMetres(here, far), closeTo(92.4, 1));
      expect(distanceMetres(here, here), 0);
    });

    test('first fix immediately, then 5 s spacing for movement and a 30 s '
        'heartbeat otherwise', () {
      final throttle = BeaconThrottle();
      expect(throttle.schedule(here, _start), _start);
      throttle.sent(here, _start);
      final t1 = _start.add(const Duration(seconds: 1));
      expect(
        throttle.schedule(far, t1),
        _start.add(const Duration(seconds: 5)),
      );
      expect(
        throttle.schedule(near, t1),
        _start.add(const Duration(seconds: 30)),
      );
      final t40 = _start.add(const Duration(seconds: 40));
      expect(throttle.schedule(near, t40), t40);
    });

    test('movement inside the accuracy radius is jitter', () {
      final throttle = BeaconThrottle()..sent(here, _start);
      const vague = GeoPoint(-33.8688, 151.2103, uncertainty: 150);
      expect(throttle.isSignificant(vague), isFalse);
      expect(throttle.isSignificant(far), isTrue);
    });

    test('failures back off 5, 10, 20 s … up to 2 minutes', () {
      final throttle = BeaconThrottle();
      final expected = [5, 10, 20, 40, 80, 120, 120];
      for (final seconds in expected) {
        throttle.failed(_start);
        expect(
          throttle.schedule(here, _start),
          _start.add(Duration(seconds: seconds)),
        );
      }
      throttle.sent(here, _start);
      expect(throttle.consecutiveFailures, 0);
    });
  });

  group('formatting', () {
    test('clock times in Australian style', () {
      final afternoon = DateTime(2026, 11, 12, 15, 45);
      expect(formatClockTime(afternoon), '3:45 pm');
      expect(formatClockTime(DateTime(2026, 11, 12, 0, 5)), '12:05 am');
      expect(formatClockTime(DateTime(2026, 11, 12, 12)), '12:00 pm');
      expect(formatClockTime(afternoon, use24Hour: true), '15:45');
    });

    test('end time adds the day when it is not today', () {
      final now = DateTime(2026, 11, 12, 20);
      expect(formatEndTime(DateTime(2026, 11, 12, 23, 30), now), '11:30 pm');
      expect(
        formatEndTime(DateTime(2026, 11, 13, 1, 15), now),
        'tomorrow 1:15 am',
      );
      expect(formatEndTime(DateTime(2026, 11, 20, 9), now), '20/11 9:00 am');
    });

    test('updated ago', () {
      final now = DateTime(2026, 11, 12, 20);
      expect(
        formatUpdatedAgo(now.subtract(const Duration(seconds: 20)), now),
        'Updated just now',
      );
      expect(
        formatUpdatedAgo(now.subtract(const Duration(minutes: 4)), now),
        'Updated 4 min ago',
      );
      expect(
        formatUpdatedAgo(now.subtract(const Duration(hours: 2)), now),
        'Updated 2 h ago',
      );
      expect(peopleSharingLabel(1), '1 person is sharing live location');
      expect(peopleSharingLabel(3), '3 people are sharing live location');
    });
  });

  group('PersistedShare', () {
    test('round-trips and rejects malformed records', () {
      final share = PersistedShare(
        roomId: '!room:example.org',
        beaconInfoId: r'$info',
        content: beaconInfoStartContent(
          timeout: const Duration(hours: 1),
          now: _start,
        ),
      );
      final back = PersistedShare.fromJson(share.toJson())!;
      expect(back.roomId, share.roomId);
      expect(back.startMillis, _start.millisecondsSinceEpoch);
      expect(back.timeoutMillis, 3600000);
      expect(PersistedShare.fromJson({'room_id': 'x'}), isNull);
      expect(
        PersistedShare.fromJson({
          'room_id': '!r:x',
          'event_id': r'$e',
          'content': {'live': true},
        }),
        isNull,
      );
    });
  });
}
