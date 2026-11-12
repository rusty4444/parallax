import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/live_location/live_location_model.dart';
import 'package:parallax/features/live_location/live_location_sharer.dart';
import 'package:parallax/features/live_location/live_share_store.dart';
import 'package:parallax/features/live_location/position_source.dart';
import 'package:parallax/features/polls/location_model.dart';

import 'live_location_fakes.dart';

const _room = '!room:example.org';
const _other = '!other:example.org';
const _account = '@me:example.org|DEVICE';
final _t0 = DateTime.utc(2026, 11, 12, 4);

/// About 1.1 m east per step at this latitude: GPS-jitter scale.
GeoPoint _jitter(int step) => GeoPoint(-33.8688, 151.2093 + step * 0.00001);

/// About 55 m per step: significant movement.
GeoPoint _walk(int step) => GeoPoint(-33.8688, 151.2093 + step * 0.0005);

class _Harness {
  _Harness({DateTime? start, LocationAccess access = LocationAccess.granted})
    : clock = FakeLiveClock(start ?? _t0),
      positions = FakePositions(access: access) {
    sharer = LiveLocationSharer(
      transport: transport,
      positions: positions,
      store: store,
      accountKey: _account,
      clock: clock,
    );
  }

  final FakeLiveClock clock;
  final FakePositions positions;
  final transport = FakeTransport();
  final store = MemoryShareStore();
  late final LiveLocationSharer sharer;

  void fix(GeoPoint point) => positions.emit(point, clock.now());

  Future<void> tick(Duration by, {GeoPoint? point}) async {
    await clock.advance(by);
    if (point != null) {
      fix(point);
      await settle();
    }
  }

  List<String> beaconTargets() => [
    for (final b in transport.beacons)
      ((b.content['m.relates_to'] as Map)['event_id'] as String),
  ];

  List<int> beaconTimes() => [
    for (final b in transport.beacons)
      b.content['org.matrix.msc3488.ts'] as int,
  ];
}

void main() {
  group('start', () {
    test('writes beacon_info, sends the first fix at once and persists '
        'the share', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(minutes: 15));

      final start = h.transport.calls.first;
      expect(start.kind, 'start');
      expect(start.content, {
        'description': 'Live location',
        'live': true,
        'timeout': 900000,
        'org.matrix.msc3488.ts': _t0.millisecondsSinceEpoch,
        'org.matrix.msc3488.asset': {'type': 'm.self'},
      });
      expect(h.positions.watching, isTrue);
      expect(h.sharer.shareIn(_room)?.status, OwnShareStatus.active);
      expect(h.sharer.shareIn(_room)?.beaconInfoId, r'$info0');

      h.fix(_walk(0));
      await settle();
      expect(h.transport.beacons, hasLength(1));
      final beacon = h.transport.beacons.single.content;
      expect(beacon['m.relates_to'], {
        'rel_type': 'm.reference',
        'event_id': r'$info0',
      });
      expect(beacon['org.matrix.msc3488.location'], {
        'uri': _walk(0).toGeoUri(),
      });
      expect(beacon['org.matrix.msc3488.ts'], _t0.millisecondsSinceEpoch);

      await h.sharer.persisted;
      final record = h.store.records[_account]!.single;
      expect(record.roomId, _room);
      expect(record.beaconInfoId, r'$info0');
      expect(record.content, start.content);
    });

    test('a failed start leaves nothing running', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      h.transport.startError = const LiveLocationSendException(
        'nope',
        fatal: false,
      );
      await expectLater(
        h.sharer.start(_room, const Duration(hours: 1)),
        throwsA(isA<LiveLocationSendException>()),
      );
      expect(h.sharer.shares, isEmpty);
      expect(h.positions.watching, isFalse);
    });

    test('shows starting until the beacon_info echo arrives', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      h.transport.startGate = Completer();
      final starting = h.sharer.start(_room, const Duration(hours: 1));
      await settle();
      expect(h.sharer.shareIn(_room)?.status, OwnShareStatus.starting);
      expect(h.positions.watching, isFalse);
      h.transport.startGate!.complete(r'$echo');
      await starting;
      expect(h.sharer.shareIn(_room)?.status, OwnShareStatus.active);
      expect(h.sharer.shareIn(_room)?.beaconInfoId, r'$echo');
    });

    test('stopping while starting ends the share once it exists', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      h.transport.startGate = Completer();
      final starting = h.sharer.start(_room, const Duration(hours: 1));
      await settle();
      await h.sharer.stop(_room);
      expect(h.sharer.shareIn(_room), isNull);
      h.transport.startGate!.complete(r'$late');
      await starting;
      final write = h.transport.calls.last;
      expect(write.kind, 'write');
      expect(write.content['live'], isFalse);
      expect(h.sharer.shares, isEmpty);
      expect(h.positions.watching, isFalse);
    });
  });

  group('throttling', () {
    test('jitter is sent only as a 30 s heartbeat', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.fix(_jitter(0));
      await settle();
      expect(h.transport.beacons, hasLength(1));
      for (var i = 1; i <= 29; i++) {
        await h.tick(const Duration(seconds: 1), point: _jitter(i % 3));
      }
      expect(h.transport.beacons, hasLength(1), reason: 'no significant move');
      await h.tick(const Duration(seconds: 1));
      expect(h.transport.beacons, hasLength(2));
      expect(
        h.beaconTimes().last - h.beaconTimes().first,
        const Duration(seconds: 30).inMilliseconds,
      );
    });

    test('significant movement is sent at most once per 5 s', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.fix(_walk(0));
      await settle();
      // Moving 55 m every second for 12 s.
      for (var i = 1; i <= 12; i++) {
        await h.tick(const Duration(seconds: 1), point: _walk(i));
      }
      final times = h.beaconTimes();
      expect(times, hasLength(3));
      for (var i = 1; i < times.length; i++) {
        expect(times[i] - times[i - 1], greaterThanOrEqualTo(5000));
      }
      // Each deferred send carries the newest position at that moment.
      final last = h.transport.beacons.last.content;
      expect(
        (last['org.matrix.msc3488.location'] as Map)['uri'],
        _walk(9).toGeoUri(),
      );
    });

    test('one beacon in flight per room; the newest fix wins', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      final gate = h.transport.beaconGate = Completer<String>();
      h.fix(_walk(0));
      await settle();
      expect(h.transport.beacons, hasLength(1));
      // Held (for example by a recipient-trust prompt) for 20 s.
      for (var i = 1; i <= 20; i++) {
        await h.tick(const Duration(seconds: 1), point: _walk(i));
      }
      expect(h.transport.beacons, hasLength(1));
      gate.complete(r'$b');
      await settle();
      expect(h.transport.beacons, hasLength(2));
      expect(
        (h.transport.beacons.last.content['org.matrix.msc3488.location']
            as Map)['uri'],
        _walk(20).toGeoUri(),
      );
    });

    test('transient failures back off and keep the share', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.transport.beaconError = const LiveLocationSendException(
        'offline',
        fatal: false,
      );
      h.fix(_walk(0));
      await settle();
      expect(h.sharer.shareIn(_room)?.retrying, isTrue);
      await h.tick(const Duration(seconds: 4));
      expect(h.transport.beacons, hasLength(1));
      await h.tick(const Duration(seconds: 1)); // 5 s backoff
      expect(h.transport.beacons, hasLength(2));
      await h.tick(const Duration(seconds: 9));
      expect(h.transport.beacons, hasLength(2));
      h.transport.beaconError = null;
      await h.tick(const Duration(seconds: 1)); // 10 s backoff
      expect(h.transport.beacons, hasLength(3));
      expect(h.sharer.shareIn(_room)?.retrying, isFalse);
      expect(h.transport.stateWrites, hasLength(1), reason: 'never stopped');
    });

    test('a fatal failure (declined trust prompt) stops the share', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.transport.beaconError = const LiveLocationSendException(
        'Encrypted send was cancelled',
        fatal: true,
      );
      h.fix(_walk(0));
      await settle();
      expect(h.sharer.shareIn(_room), isNull);
      expect(h.transport.calls.last.kind, 'write');
      expect(h.transport.calls.last.content['live'], isFalse);
      expect(h.positions.watching, isFalse);
    });

    test('stale fixes are not sent', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.positions.emit(_walk(0), _t0.subtract(const Duration(minutes: 5)));
      await settle();
      expect(h.transport.beacons, isEmpty);
    });
  });

  group('stop and expiry', () {
    test('Stop rewrites the same content with live: false', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      final started = h.transport.calls.first.content;
      await h.sharer.stop(_room);
      final stop = h.transport.calls.last;
      expect(stop.kind, 'write');
      expect(stop.content, {...started, 'live': false});
      expect(h.sharer.shares, isEmpty);
      expect(h.positions.watching, isFalse);
      await h.sharer.persisted;
      expect(h.store.records, isEmpty);
    });

    test(
      'a failed stop write is reported but local sharing still stops',
      () async {
        final h = _Harness();
        addTearDown(h.sharer.dispose);
        await h.sharer.start(_room, const Duration(hours: 1));
        h.transport.stopError = StateError('offline');
        await expectLater(h.sharer.stop(_room), throwsStateError);
        expect(h.sharer.shares, isEmpty);
        expect(h.positions.watching, isFalse);
      },
    );

    test('Stop without a local share ends the server share (another '
        'device)', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      final remote = beaconInfoStartContent(
        timeout: const Duration(hours: 8),
        now: _t0,
      );
      h.transport.serverState[_room] = remote;
      await h.sharer.stop(_room);
      expect(h.transport.calls.last.kind, 'write');
      expect(h.transport.calls.last.content, {...remote, 'live': false});
    });

    test('the timeout ends the share on the server', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(minutes: 15));
      h.fix(_walk(0));
      await settle();
      await h.clock.advance(const Duration(minutes: 15));
      expect(h.sharer.shares, isEmpty);
      final stop = h.transport.calls.last;
      expect(stop.kind, 'write');
      expect(stop.content['live'], isFalse);
      expect(h.positions.watching, isFalse);
      // A late fix after expiry sends nothing.
      final before = h.transport.beacons.length;
      h.fix(_walk(1));
      await settle();
      expect(h.transport.beacons, hasLength(before));
    });

    test('sign-out stops every share and clears the record', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      await h.sharer.start(_other, const Duration(hours: 8));
      await h.sharer.persisted;
      expect(h.store.records[_account], hasLength(2));
      await h.sharer.stopAll();
      final writes = h.transport.calls.where((c) => c.kind == 'write');
      expect(writes.map((w) => w.roomId).toSet(), {_room, _other});
      expect(writes.every((w) => w.content['live'] == false), isTrue);
      expect(h.store.records, isEmpty);
      expect(h.store.clears, 1);
      expect(h.positions.watching, isFalse);
    });

    test('revoked permission ends every share', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      h.positions.fail(const PositionStreamException(LocationAccess.denied));
      await settle();
      expect(h.sharer.shares, isEmpty);
      expect(h.transport.calls.last.content['live'], isFalse);
    });

    test('a disabled location service retries the stream later', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      expect(h.positions.watches, 1);
      h.positions.fail(
        const PositionStreamException(LocationAccess.serviceDisabled),
      );
      await settle();
      expect(h.sharer.shareIn(_room), isNotNull);
      expect(h.positions.watching, isFalse);
      await h.clock.advance(LiveLocationSharer.streamRetryDelay);
      expect(h.positions.watches, 2);
      expect(h.positions.watching, isTrue);
    });
  });

  group('other devices', () {
    test('a newer own beacon_info elsewhere stops local updates without '
        'writing', () async {
      final h = _Harness();
      addTearDown(h.sharer.dispose);
      await h.sharer.start(_room, const Duration(hours: 1));
      final writes = h.transport.stateWrites.length;
      h.sharer.ownBeaconInfoChanged(
        _room,
        _info(r'$older', start: _t0.subtract(const Duration(hours: 1))),
      );
      expect(h.sharer.shareIn(_room), isNotNull, reason: 'replayed old event');
      h.sharer.ownBeaconInfoChanged(
        _room,
        _info(r'$stop', start: _t0, live: false),
      );
      expect(h.sharer.shareIn(_room), isNull);
      expect(h.transport.stateWrites, hasLength(writes));
      expect(h.positions.watching, isFalse);
    });
  });

  group('resume after restart', () {
    PersistedShare record(
      Duration timeout, {
      DateTime? start,
      String room = _room,
    }) => PersistedShare(
      roomId: room,
      beaconInfoId: r'$persisted',
      content: beaconInfoStartContent(timeout: timeout, now: start ?? _t0),
    );

    test('continues a live share without prompting', () async {
      final h = _Harness(start: _t0.add(const Duration(minutes: 10)));
      addTearDown(h.sharer.dispose);
      final r = record(const Duration(hours: 1));
      h.store.records[_account] = [r];
      h.transport.serverState[_room] = r.content;
      await h.sharer.resume();
      expect(h.positions.requests, 0);
      expect(h.positions.checks, 1);
      expect(h.sharer.shareIn(_room)?.beaconInfoId, r'$persisted');
      h.fix(_walk(0));
      await settle();
      expect(h.beaconTargets(), [r'$persisted']);
      // Expires at the original end, 50 minutes later.
      await h.clock.advance(const Duration(minutes: 50));
      expect(h.sharer.shares, isEmpty);
      expect(h.transport.calls.last.content['live'], isFalse);
    });

    test('ends an expired share on the server', () async {
      final h = _Harness(start: _t0.add(const Duration(hours: 2)));
      addTearDown(h.sharer.dispose);
      h.store.records[_account] = [record(const Duration(hours: 1))];
      await h.sharer.resume();
      expect(h.sharer.shares, isEmpty);
      expect(h.transport.calls.single.kind, 'write');
      expect(h.transport.calls.single.content['live'], isFalse);
      await h.sharer.persisted;
      expect(h.store.records, isEmpty);
    });

    test('drops a share stopped or replaced elsewhere', () async {
      final h = _Harness(start: _t0.add(const Duration(minutes: 1)));
      addTearDown(h.sharer.dispose);
      final r = record(const Duration(hours: 1));
      h.store.records[_account] = [r];
      h.transport.serverState[_room] = {...r.content, 'live': false};
      await h.sharer.resume();
      expect(h.sharer.shares, isEmpty);
      expect(h.transport.stateWrites, isEmpty);
      await h.sharer.persisted;
      expect(h.store.records, isEmpty);
    });

    test('stops instead of prompting when permission was revoked', () async {
      final h = _Harness(
        start: _t0.add(const Duration(minutes: 1)),
        access: LocationAccess.deniedForever,
      );
      addTearDown(h.sharer.dispose);
      final r = record(const Duration(hours: 1));
      h.store.records[_account] = [r];
      h.transport.serverState[_room] = r.content;
      await h.sharer.resume();
      expect(h.positions.requests, 0);
      expect(h.sharer.shares, isEmpty);
      expect(h.transport.calls.last.content, {...r.content, 'live': false});
    });

    test('offline: trusts the local record', () async {
      final h = _Harness(start: _t0.add(const Duration(minutes: 1)));
      addTearDown(h.sharer.dispose);
      h.store.records[_account] = [record(const Duration(hours: 1))];
      h.transport.stateReadError = StateError('offline');
      await h.sharer.resume();
      expect(h.sharer.shareIn(_room)?.status, OwnShareStatus.active);
    });
  });

  test(
    'dispose stops local work without writing and keeps the record',
    () async {
      final h = _Harness();
      await h.sharer.start(_room, const Duration(hours: 1));
      await h.sharer.persisted;
      final calls = h.transport.calls.length;
      h.sharer.dispose();
      await settle();
      expect(h.positions.watching, isFalse);
      expect(h.clock.pendingTimers, 0);
      expect(h.transport.calls, hasLength(calls));
      expect(h.store.records[_account], hasLength(1));
    },
  );
}

BeaconInfo _info(String id, {required DateTime start, bool live = true}) =>
    BeaconInfo(
      eventId: id,
      type: beaconInfoUnstableType,
      stateKey: '@me:example.org',
      sender: '@me:example.org',
      live: live,
      start: start,
      timeout: const Duration(hours: 1),
      sentAt: start,
    );
