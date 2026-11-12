import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/live_location/live_location_features.dart';
import 'package:parallax/features/live_location/live_location_model.dart';
import 'package:parallax/features/live_location/live_location_sharer.dart';
import 'package:parallax/features/live_location/matrix_live_location.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/matrix_send_guard.dart';
import 'package:parallax/room_events.dart';

import 'live_location_fakes.dart';

const _roomId = '!room:example.org';
const _me = '@me:example.org';
const _alice = '@alice:example.org';
const _bob = '@bob:example.org';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client()
    : super(
        'live-location-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
    room = matrix.Room(
      id: _roomId,
      client: this,
      membership: matrix.Membership.join,
    )..partial = false;
  }

  late final matrix.Room room;
  List<Map<String, Object?>> relations = const [];
  final relationRequests = <String>[];

  @override
  String? get userID => _me;

  @override
  String? get deviceID => 'DEVICE';

  @override
  matrix.Room? getRoomById(String id) => id == _roomId ? room : null;

  @override
  Future<matrix.GetRelatingEventsWithRelTypeResponse>
  getRelatingEventsWithRelType(
    String roomId,
    String eventId,
    String relType, {
    String? from,
    String? to,
    int? limit,
    matrix.Direction? dir,
    bool? recurse,
  }) async {
    relationRequests.add('$eventId/$relType/${dir?.name}/$limit');
    return matrix.GetRelatingEventsWithRelTypeResponse(
      chunk: [
        for (final json in relations)
          matrix.MatrixEvent.fromJson(jsonDecode(jsonEncode(json))),
      ],
    );
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Backend implements MatrixSdkAccess, RoomEventFeatures {
  _Backend(this.client);
  final _Client client;
  bool current = true;
  bool echo = true;
  final stateWrites =
      <({String type, String stateKey, Map<String, Object?> content})>[];
  final sent = <({String type, Map<String, Object?> content})>[];
  int _next = 0;

  @override
  matrix.Client? get sdkClient => current ? client : null;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    sent.add((type: type, content: content));
    return '\$sent${_next++}';
  }

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {
    stateWrites.add((type: type, stateKey: stateKey, content: content));
    if (!echo) return;
    final event = _state(
      client,
      id: '\$state${_next++}',
      type: type,
      sender: _me,
      content: content,
      sentAt: DateTime.now(),
    );
    // The homeserver's echo arrives through sync after the PUT returns.
    scheduleMicrotask(() => client.room.setState(event));
  }

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async => client.room.getState(type, stateKey)?.content;

  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) =>
      throw UnimplementedError();
}

matrix.Event _state(
  _Client client, {
  required String id,
  required String type,
  required String sender,
  required Map<String, Object?> content,
  required DateTime sentAt,
  String? stateKey,
}) => matrix.Event(
  content: content,
  type: type,
  eventId: id,
  senderId: sender,
  stateKey: stateKey ?? sender,
  originServerTs: sentAt,
  room: client.room,
);

matrix.Event _member(_Client client, String user, String name) => matrix.Event(
  content: {'membership': 'join', 'displayname': name},
  type: matrix.EventTypes.RoomMember,
  eventId: '\$member-$user',
  senderId: user,
  stateKey: user,
  originServerTs: DateTime(2026),
  room: client.room,
);

Map<String, Object?> _rawBeacon(
  String id,
  String sender,
  String target,
  DateTime at,
  GeoPoint point,
) => {
  'event_id': id,
  'type': beaconUnstableType,
  'sender': sender,
  'origin_server_ts': at.millisecondsSinceEpoch,
  'room_id': _roomId,
  'content': beaconContent(beaconInfoId: target, point: point, measuredAt: at),
};

class _Harness {
  _Harness() {
    backend = _Backend(client);
    live = MatrixLiveLocation(
      backend,
      backend,
      positions: positions,
      store: store,
      echoTimeout: const Duration(milliseconds: 200),
    );
  }

  final client = _Client();
  late final _Backend backend;
  final positions = FakePositions();
  final store = MemoryShareStore();
  late final MatrixLiveLocation live;
}

class _MatrixChatBackend extends ChatBackend
    implements MatrixSdkAccess, RoomEventFeatures {
  _MatrixChatBackend(this.inner);
  final _Backend inner;
  @override
  matrix.Client? get sdkClient => inner.sdkClient;
  @override
  bool isSessionCurrent(matrix.Client client) => inner.isSessionCurrent(client);
  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) => inner.sendRoomEvent(roomId, type, content);
  @override
  Future<void> redactEvent(String roomId, String eventId, {String? reason}) =>
      inner.redactEvent(roomId, eventId, reason: reason);
  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) => inner.roomState(roomId, type, stateKey: stateKey);
  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) => inner.setRoomState(roomId, type, content, stateKey: stateKey);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlainBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('resolves via MatrixSdkAccess + RoomEventFeatures with one cache', () {
    expect(liveLocationFeaturesOf(_PlainBackend()), isNull);
    final adapter = _MatrixChatBackend(_Backend(_Client()));
    final first = liveLocationFeaturesOf(adapter);
    expect(first, isA<MatrixLiveLocation>());
    expect(identical(first, liveLocationFeaturesOf(adapter)), isTrue);
    expect(identical(first, liveLocationLifecycleOf(adapter)), isTrue);
  });

  group('sharing', () {
    test('writes beacon_info as state (own state key), waits for the echo '
        'and sends beacons through sendRoomEvent', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      await h.live.startSharing(_roomId, const Duration(minutes: 15));

      final write = h.backend.stateWrites.single;
      expect(write.type, 'org.matrix.msc3672.beacon_info');
      expect(write.stateKey, _me);
      expect(write.content['live'], isTrue);
      expect(write.content['timeout'], 900000);
      final share = h.live.deviceShare(_roomId)!;
      expect(share.status, OwnShareStatus.active);
      expect(share.beaconInfoId, r'$state0');

      h.positions.emit(const GeoPoint(-33.86, 151.2), DateTime.now());
      await settle();
      final beacon = h.backend.sent.single;
      expect(beacon.type, 'org.matrix.msc3672.beacon');
      expect(beacon.content['m.relates_to'], {
        'rel_type': 'm.reference',
        'event_id': r'$state0',
      });

      // Now live in room state for everyone.
      final shares = h.live.liveShares(_roomId);
      expect(shares.single.mine, isTrue);
      expect(shares.single.live, isTrue);

      await h.live.stopSharing(_roomId);
      final stop = h.backend.stateWrites.last;
      expect(stop.type, 'org.matrix.msc3672.beacon_info');
      expect(stop.content, {...write.content, 'live': false});
      expect(h.live.deviceShare(_roomId), isNull);
    });

    test('an unconfirmed beacon_info is ended again and start fails', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      h.backend.echo = false;
      await expectLater(
        h.live.startSharing(_roomId, const Duration(hours: 1)),
        throwsA(isA<LiveLocationSendException>()),
      );
      expect(h.backend.stateWrites, hasLength(2));
      expect(h.backend.stateWrites.last.content['live'], isFalse);
      expect(h.live.deviceShare(_roomId), isNull);
    });

    test('encrypted room without working encryption: the beacon is refused '
        'before sending and the share ends', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      h.client.room.setState(
        _state(
          h.client,
          id: r'$enc',
          type: matrix.EventTypes.Encryption,
          sender: _me,
          stateKey: '',
          content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
          sentAt: DateTime(2026),
        ),
      );
      await h.live.startSharing(_roomId, const Duration(hours: 1));
      h.positions.emit(const GeoPoint(-33.86, 151.2), DateTime.now());
      await settle();
      expect(h.backend.sent, isEmpty);
      expect(h.live.deviceShare(_roomId), isNull);
      expect(h.backend.stateWrites.last.content['live'], isFalse);
    });

    test('another device replacing the share stops local updates', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      await h.live.startSharing(_roomId, const Duration(hours: 1));
      final started = h.backend.stateWrites.single.content;
      h.client.room.setState(
        _state(
          h.client,
          id: r'$elsewhere',
          type: beaconInfoUnstableType,
          sender: _me,
          content: {...started, 'live': false},
          sentAt: DateTime.now().add(const Duration(seconds: 1)),
        ),
      );
      await settle();
      expect(h.live.deviceShare(_roomId), isNull);
      expect(h.backend.stateWrites, hasLength(1), reason: 'no write');
    });

    test('sign-out: shares end even though the session is no longer '
        'current, and local records are cleared', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      await h.live.startSharing(_roomId, const Duration(hours: 1));
      await settle();
      expect(h.store.records, isNotEmpty);
      // MatrixBackend.logout marks the session as ending before its
      // pre-logout hook; a rebuild may already have dropped the sharer.
      h.backend.current = false;
      expect(h.live.liveShares(_roomId), isEmpty);
      await h.live.stopAllShares();
      expect(h.backend.stateWrites.last.content['live'], isFalse);
      expect(h.backend.stateWrites.last.stateKey, _me);
      expect(h.store.records, isEmpty);
      expect(h.positions.watching, isFalse);
    });

    test('power levels gate sharing', () {
      final h = _Harness();
      addTearDown(h.live.dispose);
      expect(h.live.canShareIn(_roomId), isTrue, reason: 'no power levels');
      void levels(Map<String, Object?> content) => h.client.room.setState(
        _state(
          h.client,
          id: '\$pl${content.hashCode}',
          type: matrix.EventTypes.RoomPowerLevels,
          sender: _alice,
          stateKey: '',
          content: content,
          sentAt: DateTime(2026),
        ),
      );
      levels({'state_default': 50, 'users_default': 0});
      expect(h.live.canShareIn(_roomId), isFalse);
      levels({
        'state_default': 50,
        'users_default': 0,
        'events': {'org.matrix.msc3672.beacon_info': 0},
      });
      expect(h.live.canShareIn(_roomId), isTrue);
      expect(h.live.canShareIn('!unknown:example.org'), isFalse);
    });
  });

  group('reading shares', () {
    test('live shares come from room state, one per sharer, own first', () {
      final h = _Harness();
      addTearDown(h.live.dispose);
      final now = DateTime.now().toUtc();
      Map<String, Object?> started(Duration ago, Duration timeout) =>
          beaconInfoStartContent(timeout: timeout, now: now.subtract(ago));
      void put(
        String id,
        String sender,
        Map<String, Object?> content, {
        String type = beaconInfoUnstableType,
        Duration ago = Duration.zero,
      }) => h.client.room.setState(
        _state(
          h.client,
          id: id,
          type: type,
          sender: sender,
          content: content,
          sentAt: now.subtract(ago),
        ),
      );
      h.client.room.setState(_member(h.client, _alice, 'Alice'));
      put(
        r'$alice',
        _alice,
        started(const Duration(minutes: 5), const Duration(hours: 1)),
      );
      put(
        r'$bob',
        _bob,
        started(const Duration(minutes: 1), const Duration(hours: 1)),
        type: beaconInfoStableType,
      );
      put(
        r'$carol',
        '@carol:example.org',
        started(const Duration(hours: 2), const Duration(hours: 1)),
      );
      final daveStart = started(
        const Duration(minutes: 10),
        const Duration(hours: 1),
      );
      put(
        r'$dave-start',
        '@dave:example.org',
        daveStart,
        type: beaconInfoStableType,
        ago: const Duration(minutes: 10),
      );
      put(r'$dave-stop', '@dave:example.org', {
        ...daveStart,
        'live': false,
      }, ago: const Duration(minutes: 2));
      put(
        r'$me',
        _me,
        started(const Duration(minutes: 30), const Duration(hours: 1)),
      );
      // A beacon_info in someone else's state key is ignored.
      h.client.room.setState(
        _state(
          h.client,
          id: r'$spoof',
          type: beaconInfoUnstableType,
          sender: _bob,
          stateKey: '@erin:example.org',
          content: started(Duration.zero, const Duration(hours: 1)),
          sentAt: now,
        ),
      );

      final shares = h.live.liveShares(_roomId);
      expect(shares.map((s) => s.info.eventId), [r'$me', r'$bob', r'$alice']);
      expect(shares.last.displayName, 'Alice');
      expect(shares[1].displayName, _bob);

      // The original start event of a stopped share renders as ended.
      final daveInfo = BeaconInfo.fromEvent(
        eventId: r'$dave-start',
        type: beaconInfoStableType,
        stateKey: '@dave:example.org',
        sender: '@dave:example.org',
        content: daveStart,
        originServerTs: now.subtract(const Duration(minutes: 10)),
      )!;
      expect(h.live.shareSnapshot(_roomId, daveInfo).live, isFalse);
      expect(h.live.shareSnapshot(_roomId, shares.first.info).live, isTrue);
    });

    test('latest beacon: one bounded newest-first page, then live events; '
        'foreign, out-of-period and unsent beacons are ignored', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      final start = DateTime.now().toUtc().subtract(
        const Duration(minutes: 10),
      );
      final info = BeaconInfo.fromEvent(
        eventId: r'$info',
        type: beaconInfoUnstableType,
        stateKey: _alice,
        sender: _alice,
        content: beaconInfoStartContent(
          timeout: const Duration(minutes: 30),
          now: start,
        ),
        originServerTs: start,
      )!;
      h.client.relations = [
        _rawBeacon(
          r'$b2',
          _alice,
          r'$info',
          start.add(const Duration(minutes: 2)),
          const GeoPoint(1, 2),
        ),
        _rawBeacon(
          r'$spoof',
          _bob,
          r'$info',
          start.add(const Duration(minutes: 3)),
          const GeoPoint(9, 9),
        ),
        _rawBeacon(
          r'$future',
          _alice,
          r'$info',
          start.add(const Duration(hours: 2)),
          const GeoPoint(8, 8),
        ),
        _rawBeacon(
          r'$b1',
          _alice,
          r'$info',
          start.add(const Duration(minutes: 1)),
          const GeoPoint(0, 0),
        ),
      ];
      var notified = 0;
      h.live.addListener(() => notified++);
      h.live.ensureBeaconsLoaded(_roomId, info);
      h.live.ensureBeaconsLoaded(_roomId, info);
      expect(notified, 0, reason: 'never notifies synchronously');
      expect(h.live.shareSnapshot(_roomId, info).loading, isTrue);
      await settle();
      expect(h.client.relationRequests, [r'$info/m.reference/b/20']);
      var snapshot = h.live.shareSnapshot(_roomId, info);
      expect(snapshot.loading, isFalse);
      expect(snapshot.latest?.eventId, r'$b2');
      expect(notified, greaterThan(0));

      matrix.Event live(String id, DateTime at, {bool sent = true}) =>
          matrix.Event.fromJson(
              _rawBeacon(id, _alice, r'$info', at, const GeoPoint(3, 4)),
              h.client.room,
            )
            ..status = sent
                ? matrix.EventStatus.synced
                : matrix.EventStatus.sending;
      h.client.onTimelineEvent.add(
        live(r'$echo', start.add(const Duration(minutes: 4)), sent: false),
      );
      await settle();
      expect(h.live.shareSnapshot(_roomId, info).latest?.eventId, r'$b2');
      h.client.onTimelineEvent.add(
        live(r'$b3', start.add(const Duration(minutes: 5))),
      );
      await settle();
      snapshot = h.live.shareSnapshot(_roomId, info);
      expect(snapshot.latest?.eventId, r'$b3');
      expect(snapshot.latest?.point.latitude, 3);

      h.client.onTimelineEvent.add(
        matrix.Event(
          content: {'redacts': r'$b3'},
          type: matrix.EventTypes.Redaction,
          eventId: r'$redaction',
          senderId: _alice,
          originServerTs: DateTime.now(),
          redacts: r'$b3',
          room: h.client.room,
        ),
      );
      await settle();
      expect(h.live.shareSnapshot(_roomId, info).latest, isNull);
    });

    test('a session change drops everything', () async {
      final h = _Harness();
      addTearDown(h.live.dispose);
      await h.live.startSharing(_roomId, const Duration(hours: 1));
      h.backend.current = false;
      expect(h.live.deviceShare(_roomId), isNull);
      expect(h.live.liveShares(_roomId), isEmpty);
      expect(h.positions.watching, isFalse);
      await expectLater(
        h.live.startSharing(_roomId, const Duration(hours: 1)),
        throwsStateError,
      );
    });
  });

  group('encryption (SDK 14.1 pin)', () {
    test('beacon content is not relation-only, so encryptGroupMessagePayload '
        'does not take the plaintext short-circuit', () async {
      final client = _Client();
      client.room.setState(
        _state(
          client,
          id: r'$enc',
          type: matrix.EventTypes.Encryption,
          sender: _me,
          stateKey: '',
          content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
          sentAt: DateTime(2026),
        ),
      );
      final crypto = encryption.Encryption(client: client);
      final relation = {'rel_type': 'm.reference', 'event_id': r'$info'};
      // Relation-only payloads come back unencrypted with the relation …
      final bare = await crypto.encryptGroupMessagePayload(_roomId, {
        'm.relates_to': relation,
      }, type: beaconUnstableType);
      expect(bare, {'m.relates_to': relation});
      // … a beacon goes past that check to Megolm. Without an initialised
      // Olm account (as here) the SDK returns the inner payload; the app's
      // send path refuses that (see the guard test below and
      // MatrixBackend.sendRoomEvent's fail-closed encryption check).
      final content = beaconContent(
        beaconInfoId: r'$info',
        point: const GeoPoint(1, 2),
        measuredAt: DateTime.utc(2026),
      );
      final result = await crypto.encryptGroupMessagePayload(
        _roomId,
        content,
        type: beaconUnstableType,
      );
      expect(result.containsKey('m.relates_to'), isFalse);
      expect(result.containsKey('org.matrix.msc3488.location'), isTrue);
    });

    test('the final send guard refuses a plaintext beacon in an encrypted '
        'room', () async {
      final inner = MockClient((_) async => http.Response('{}', 200));
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (id) => id == _roomId,
      );
      final url = Uri.parse(
        'https://matrix.example.org/_matrix/client/v3/rooms/'
        '${Uri.encodeComponent(_roomId)}/send/org.matrix.msc3672.beacon/txn',
      );
      await expectLater(guard.send(http.Request('PUT', url)), throwsStateError);
    });
  });

  test('Android manifest: foreground location service without background '
      'location', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE"'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_LOCATION'),
    );
    expect(manifest, contains('android.permission.WAKE_LOCK'));
    expect(
      manifest,
      isNot(contains('android.permission.ACCESS_BACKGROUND_LOCATION"')),
    );
    expect(
      RegExp(
        r'GeolocatorLocationService"[^>]*foregroundServiceType="location"',
        dotAll: true,
      ).hasMatch(manifest),
      isTrue,
    );
  });
}
