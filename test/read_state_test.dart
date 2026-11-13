import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';

const _roomId = '!room:matrix.example';
const _me = '@sam:matrix.example';

Map<String, Object?> _event(
  String id,
  int ts, {
  String sender = '@alice:matrix.example',
  int? status,
}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': sender,
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': {'msgtype': 'm.text', 'body': 'message $id'},
  'status': ?status,
};

Map<String, Object?> _reaction(
  String id,
  String target,
  String key,
  int ts, {
  int? status,
}) => {
  'event_id': id,
  'type': 'm.reaction',
  'sender': _me,
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': {
    'm.relates_to': {
      'rel_type': 'm.annotation',
      'event_id': target,
      'key': key,
    },
  },
  'status': ?status,
};

class _Database extends Fake implements matrix.DatabaseApi {
  /// Locally cached timeline, newest first (as the SDK stores it).
  List<Map<String, Object?>> cached = const [];
  final removed = <(String, String)>[];

  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => onlySending
      ? const []
      : [for (final json in cached) matrix.Event.fromJson(json, room)];

  @override
  Future<List<matrix.Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    matrix.Room room,
  ) async => const [];

  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async => null;

  @override
  Future<void> transaction(Future<void> Function() action) => action();

  @override
  Future<void> storeRoomUpdate(
    String roomId,
    matrix.SyncRoomUpdate roomUpdate,
    matrix.Event? lastEvent,
    matrix.Client client,
  ) async {}

  @override
  Future<void> storeRoomAccountData(
    String roomId,
    matrix.BasicEvent event,
  ) async {}

  @override
  Future<({Map<String, Object?> content, DateTime savedAt})?>
  getCustomCacheObject(String cacheKey) async => null;

  @override
  Future<void> removeEvent(String eventId, String roomId) async {
    removed.add((eventId, roomId));
    cached = cached.where((event) => event['event_id'] != eventId).toList();
  }

  @override
  Future<void> close() async {}
}

class _Request {
  _Request(this.method, this.path, this.body);
  final String method;
  final String path;
  final Map<String, Object?> body;
}

class _Client extends matrix.Client {
  _Client(this.db, this.requests)
    : super(
        'read-test',
        database: db,
        httpClient: MockClient((request) async {
          final body = request.body.isEmpty
              ? <String, Object?>{}
              : Map<String, Object?>.from(jsonDecode(request.body) as Map);
          requests.add(
            _Request(
              request.method,
              Uri.decodeComponent(request.url.path),
              body,
            ),
          );
          return http.Response('{}', 200);
        }),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
  final _Database db;
  final List<_Request> requests;
  @override
  String? get userID => _me;
  @override
  String? get deviceID => 'DEVICE';
}

class _Harness {
  _Harness({
    List<Map<String, Object?>> cached = const [],
    int notificationCount = 2,
    bool markedUnread = false,
    bool publicReceipts = true,
  }) {
    db = _Database()..cached = cached;
    client = _Client(db, requests);
    room = matrix.Room(
      id: _roomId,
      client: client,
      notificationCount: notificationCount,
      roomAccountData: {
        if (markedUnread)
          'm.marked_unread': matrix.BasicEvent(
            type: 'm.marked_unread',
            content: {'unread': true},
          ),
      },
    );
    final newest = cached.where((e) => e['status'] == null).firstOrNull;
    if (newest != null) room.lastEvent = matrix.Event.fromJson(newest, room);
    client.rooms.add(room);
    backend = MatrixBackend.withClient(
      client,
      sendReadReceipts: () => publicReceipts,
      isAppVisible: () => visible,
    );
  }

  final requests = <_Request>[];
  late final _Database db;
  late final _Client client;
  late final matrix.Room room;
  late final MatrixBackend backend;
  bool visible = true;

  List<Map<String, Object?>> get readMarkers => [
    for (final r in requests)
      if (r.path.endsWith('/read_markers')) r.body,
  ];

  /// A message arriving through sync while the room is open.
  void receive(Map<String, Object?> json) {
    final event = matrix.Event.fromJson(json, room);
    room.lastEvent = event;
    client.onTimelineEvent.add(event);
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 450));

void main() {
  test('opening marks read up to the newest sent event, skipping local echoes; '
      'private only when public receipts are off', () async {
    final h = _Harness(
      publicReceipts: false,
      cached: [
        // A failed send from this device: no server ID, can't take a receipt.
        _event('txn-failed', 9500, sender: _me, status: -2),
        _event(r'$newest', 9000),
        _event(r'$older', 8000),
      ],
    );
    addTearDown(h.backend.dispose);

    await h.backend.openRoom(_roomId);
    await _settle();

    expect(h.readMarkers, isNotEmpty);
    for (final body in h.readMarkers) {
      expect(body['m.fully_read'], r'$newest');
      expect(body['m.read.private'], r'$newest');
      expect(body.containsKey('m.read'), isFalse, reason: 'receipts are off');
    }
  });

  test('sends the public receipt when read receipts are on', () async {
    final h = _Harness(cached: [_event(r'$newest', 9000)]);
    addTearDown(h.backend.dispose);

    await h.backend.openRoom(_roomId);
    await _settle();

    expect(h.readMarkers, hasLength(1));
    expect(h.readMarkers.single['m.read'], r'$newest');
  });

  test('opening clears a manual "mark as unread" (set by a bridge)', () async {
    final h = _Harness(
      notificationCount: 0,
      markedUnread: true,
      cached: [_event(r'$newest', 9000)],
    );
    addTearDown(h.backend.dispose);
    expect(h.room.markedUnread, isTrue);

    await h.backend.openRoom(_roomId);
    await _settle();

    expect(h.room.markedUnread, isFalse);
    final flag = h.requests.where(
      (r) =>
          r.method == 'PUT' && r.path.endsWith('/account_data/m.marked_unread'),
    );
    expect(flag.single.body, {'unread': false});
    expect(h.readMarkers.single['m.fully_read'], r'$newest');
  });

  test(
    'backing out before the timeline loads still marks the room read',
    () async {
      final h = _Harness(cached: [_event(r'$newest', 9000)]);
      addTearDown(h.backend.dispose);

      final opening = h.backend.openRoom(_roomId);
      h.backend.closeRoom(_roomId);
      await opening;
      await _settle();

      expect(h.readMarkers.map((b) => b['m.fully_read']), contains(r'$newest'));
      expect(h.backend.activeRoomId, isNull);
    },
  );

  test(
    'messages arriving while the room is on screen are marked read; '
    'not while Parallax is in the background, and not own messages',
    () async {
      final h = _Harness(cached: [_event(r'$a', 1000)]);
      addTearDown(h.backend.dispose);

      await h.backend.openRoom(_roomId);
      await _settle();
      expect(h.readMarkers.map((b) => b['m.fully_read']), [r'$a']);
      // The server's next sync reports the room as read.
      h.room.notificationCount = 0;

      // In the background: nothing is marked.
      h.visible = false;
      h.receive(_event(r'$b', 2000));
      await _settle();
      expect(h.readMarkers, hasLength(1));

      // Back on screen with the room open.
      h.visible = true;
      h.backend.markActiveRoomRead();
      await _settle();
      expect(h.readMarkers.last['m.fully_read'], r'$b');

      // A message arriving while watching.
      h.receive(_event(r'$c', 3000));
      await _settle();
      expect(h.readMarkers.last['m.fully_read'], r'$c');
      expect(h.readMarkers, hasLength(3));

      // Own messages need no receipt.
      h.receive(_event(r'$mine', 4000, sender: _me));
      await _settle();
      expect(h.readMarkers, hasLength(3));
    },
  );

  test('a read room is not marked again on open', () async {
    final h = _Harness(notificationCount: 0, cached: [_event(r'$a', 1000)]);
    addTearDown(h.backend.dispose);
    // Own receipt already on the newest event.
    h.room.receiptState = matrix.LatestReceiptState.fromJson({
      'global': {
        'latest': {'e': r'$a', 'ts': 1000},
        'private': {'e': r'$a', 'ts': 1000},
      },
    });

    await h.backend.openRoom(_roomId);
    await _settle();

    expect(h.readMarkers, isEmpty);
  });

  test('failed local echoes merge into timeline time order', () async {
    final h = _Harness(
      cached: [
        _event('txn-late', 12000, sender: _me, status: -2),
        _event('txn-early', 10000, sender: _me, status: -2),
        _event(r'$newer', 11000),
        _event(r'$older', 9000),
      ],
    );
    addTearDown(h.backend.dispose);

    await h.backend.openRoom(_roomId);

    expect(h.backend.messages.map((entry) => entry.id), [
      r'$older',
      'txn-early',
      r'$newer',
      'txn-late',
    ]);
  });

  test('failed own message is discarded locally instead of redacted', () async {
    final h = _Harness(
      cached: [
        _event(r'$newest', 9000),
        _event('txn-failed', 8000, sender: _me, status: -2),
        _event(r'$older', 7000),
      ],
    );
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);

    await h.backend.redactMessage(_roomId, 'txn-failed');

    expect(h.db.removed, [('txn-failed', _roomId)]);
    expect(
      h.backend.messages.any((entry) => entry.id == 'txn-failed'),
      isFalse,
    );
    expect(
      h.requests.where((request) => request.path.contains('/redact')),
      isEmpty,
    );
  });

  test('tapping a synced own reaction hides it while redacting', () async {
    final h = _Harness(
      cached: [
        _reaction(r'$own-reaction', r'$message', '❤️', 10000),
        _event(r'$message', 9000),
      ],
    );
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    expect(h.backend.messages.single.reactions.single.mine, isTrue);

    await h.backend.react(_roomId, r'$message', emoji: '❤️');

    expect(h.backend.messages.single.reactions, isEmpty);
    expect(
      h.requests.where((request) => request.path.contains('/redact/')),
      isNotEmpty,
    );
  });

  test('an unsent own reaction is cancelled and removed locally', () async {
    final h = _Harness(
      cached: [
        _reaction('txn-reaction', r'$message', '❤️', 10000, status: -2),
        _event(r'$message', 9000),
      ],
    );
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    expect(h.backend.messages.single.reactions.single.mine, isTrue);

    await h.backend.react(_roomId, r'$message', emoji: '❤️');

    expect(h.db.removed, [('txn-reaction', _roomId)]);
    expect(h.backend.messages.single.reactions, isEmpty);
    expect(
      h.requests.where((request) => request.path.contains('/redact/')),
      isEmpty,
    );
  });

  test('uncaptioned bridged images do not gain an SDK error caption', () async {
    Map<String, Object?> image(String id, int ts, {String? body}) => {
      ..._event(id, ts),
      'content': {
        'msgtype': 'm.image',
        'url': 'mxc://matrix.example/$id',
        'body': ?body,
      },
    };
    final h = _Harness(
      notificationCount: 0,
      // Cached events are newest first.
      cached: [
        image(r'$missing-body', 3000),
        image(r'$empty-body', 2000, body: ''),
        image(r'$captioned', 1000, body: 'Sunday forecast'),
      ],
    );
    addTearDown(h.backend.dispose);

    await h.backend.openRoom(_roomId);

    expect(h.backend.messages.map((entry) => entry.id), [
      r'$captioned',
      r'$empty-body',
      r'$missing-body',
    ]);
    expect(h.backend.messages.map((entry) => entry.body), [
      'Sunday forecast',
      '',
      '',
    ]);
  });
}
