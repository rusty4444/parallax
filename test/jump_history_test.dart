// Jumping to an older message (reply quotes, search, permalinks) must
// survive another history request already running on the same timeline.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';

const _roomId = '!room:matrix.example';
const _me = '@sam:matrix.example';

Map<String, Object?> _event(String id, int ts) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@friend:matrix.example',
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': {'msgtype': 'm.text', 'body': id},
};

class _Database extends Fake implements matrix.DatabaseApi {
  /// Locally cached timeline, newest first (as the SDK stores it).
  List<Map<String, Object?>> cached = const [];
  final removed = <(String, String)>[];

  /// While set, history reads wait for it (another request in flight).
  Completer<void>? gate;
  int reads = 0;

  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async {
    if (onlySending) return const [];
    reads++;
    final wait = gate;
    if (wait != null) await wait.future;
    final end = limit == null
        ? cached.length
        : (start + limit).clamp(0, cached.length);
    if (start >= cached.length) return const [];
    return [
      for (final json in cached.sublist(start, end))
        matrix.Event.fromJson(json, room),
    ];
  }

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

void main() {
  // Newest first, as the SDK stores the timeline.
  List<Map<String, Object?>> history(int count) => [
    for (var i = 0; i < count; i++) _event('\$e$i', 1000000 - i * 1000),
  ];

  test('a jump waits for a history load already running', () async {
    final h = _Harness(cached: history(400));
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    expect(
      h.backend.messages.any((m) => m.id == r'$e350'),
      isFalse,
      reason: 'the target starts out of the loaded window',
    );

    // "Load earlier messages" is mid-request when the reply quote is tapped:
    // the SDK's requestHistory returns at once, loading nothing, until the
    // first request finishes.
    final gate = h.db.gate = Completer<void>();
    final older = h.backend.loadOlder(_roomId);
    await Future<void>.delayed(Duration.zero);
    final jump = h.backend.openRoomAt(_roomId, r'$e350');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    h.db.gate = null;
    gate.complete();
    await older;
    await jump;

    expect(h.backend.focusedEventId, r'$e350');
    expect(h.backend.messages.any((m) => m.id == r'$e350'), isTrue);
  });

  test('a jump far back in a long local history still arrives', () async {
    // 40 pages of 50 used to be the limit; this target is 2,500 back.
    final h = _Harness(cached: history(2600));
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    await h.backend.openRoomAt(_roomId, r'$e2500');
    expect(h.backend.focusedEventId, r'$e2500');
  });

  test('a missing target still fails once history runs out', () async {
    final h = _Harness(cached: history(120));
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    await expectLater(
      h.backend.openRoomAt(_roomId, r'$not-here'),
      throwsStateError,
    );
  });
}
