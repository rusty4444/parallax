import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/matrix_backend.dart';

const _roomId = '!room:matrix.example';

Map<String, Object?> _event(String id, int ts, {String? body}) => {
  'event_id': id,
  'type': 'm.room.message',
  'sender': '@alice:matrix.example',
  'origin_server_ts': ts,
  'room_id': _roomId,
  'content': {'msgtype': 'm.text', 'body': body ?? 'message $id'},
};

class _Database extends Fake implements matrix.DatabaseApi {
  /// Locally cached timeline, newest first (as the SDK stores it).
  List<Map<String, Object?>> cached = const [];

  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => onlySending
      ? const []
      : [
          for (final json in cached.skip(start).take(limit ?? cached.length))
            matrix.Event.fromJson(json, room),
        ];

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
  Future setRoomPrevBatch(
    String? prevBatch,
    String roomId,
    matrix.Client client,
  ) async {}

  @override
  Future<void> storeEventUpdate(
    String roomId,
    matrix.StrippedStateEvent event,
    matrix.EventUpdateType type,
    matrix.Client client,
  ) async {}

  @override
  Future<void> storeRoomUpdate(
    String roomId,
    matrix.SyncRoomUpdate roomUpdate,
    matrix.Event? lastEvent,
    matrix.Client client,
  ) async {}

  @override
  Future<void> close() async {}
}

class _Client extends matrix.Client {
  _Client(this.db, Future<http.Response> Function(http.Request) respond)
    : super('jump-test', database: db, httpClient: MockClient(respond)) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
    rooms.add(matrix.Room(id: _roomId, client: this));
  }
  final _Database db;
  @override
  String? get userID => '@sam:matrix.example';
  @override
  String? get deviceID => 'DEVICE';
}

void main() {
  test('jump to a cached event keeps the whole live timeline', () async {
    final requests = <String>[];
    final db = _Database()
      ..cached = [
        _event(r'$newest', 3000),
        _event(r'$target', 2000),
        _event(r'$older', 1000),
      ];
    final client = _Client(db, (request) async {
      requests.add(request.url.path);
      return http.Response('{}', 200);
    });
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    final navigation = timelineNavigationOf(backend)!;

    await navigation.openRoomAt(_roomId, r'$target');

    expect(backend.activeRoomId, _roomId);
    expect(navigation.focusedEventIn(_roomId), r'$target');
    expect(navigation.jumpGenerationIn(_roomId), 1);
    // Nothing is hidden: older, target and newer are all visible.
    expect(backend.messages.map((e) => e.id), [
      r'$older',
      r'$target',
      r'$newest',
    ]);
    expect(navigation.hasNewerThanFocus(_roomId), isFalse);
    expect(requests.where((p) => p.contains('/messages')), isEmpty);

    // Jumping again re-scrolls even to the same event.
    await navigation.openRoomAt(_roomId, r'$target');
    expect(navigation.jumpGenerationIn(_roomId), 2);

    // "Jump to latest" only clears the marker; the timeline is unchanged.
    await navigation.jumpToLatest(_roomId);
    expect(navigation.focusedEventIn(_roomId), isNull);
    expect(backend.messages.map((e) => e.id), [
      r'$older',
      r'$target',
      r'$newest',
    ]);
  });

  test('jump pages back through history to an older event', () async {
    final requests = <String>[];
    final db = _Database()
      ..cached = [_event(r'$live2', 9000), _event(r'$live1', 8000)];
    final client = _Client(db, (request) async {
      requests.add(request.url.path);
      if (request.url.path.contains('/messages') &&
          request.url.queryParameters['dir'] == 'b') {
        // Backward pages arrive newest first.
        return http.Response(
          jsonEncode({
            'chunk': [_event(r'$target', 2000), _event(r'$before', 1000)],
            'start': 'prev-token',
            'end': 'older-token',
            'state': <Object?>[],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    client.getRoomById(_roomId)!.prev_batch = 'prev-token';
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    final navigation = timelineNavigationOf(backend)!;

    await navigation.openRoomAt(_roomId, r'$target');

    expect(navigation.focusedEventIn(_roomId), r'$target');
    // The older page and the live messages are all visible, oldest first.
    expect(backend.messages.map((e) => e.id), [
      r'$before',
      r'$target',
      r'$live1',
      r'$live2',
    ]);
    expect(navigation.hasNewerThanFocus(_roomId), isFalse);
    expect(requests.where((p) => p.contains('/messages')), isNotEmpty);
    expect(requests.where((p) => p.contains('/context/')), isEmpty);
  });

  test('an unloadable event fails without hiding anything', () async {
    final db = _Database()
      ..cached = [_event(r'$live2', 9000), _event(r'$live1', 8000)];
    final client = _Client(db, (_) async => http.Response('{}', 200));
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    final navigation = timelineNavigationOf(backend)!;

    await expectLater(
      navigation.openRoomAt(_roomId, r'$missing'),
      throwsStateError,
    );
    // The room stays open at the live end, nothing focused or hidden.
    expect(backend.activeRoomId, _roomId);
    expect(backend.focusedEventId, isNull);
    expect(backend.messages.map((e) => e.id), [r'$live1', r'$live2']);
  });

  test('closing the room clears the jump', () async {
    final db = _Database()..cached = [_event(r'$target', 2000)];
    final backend = MatrixBackend.withClient(
      _Client(db, (_) async => http.Response('{}', 200)),
    );
    addTearDown(backend.dispose);
    await backend.openRoomAt(_roomId, r'$target');
    expect(backend.focusedEventId, r'$target');
    expect(backend.focusHasNewer, isFalse);
    backend.closeRoom(_roomId);
    expect(backend.focusedEventId, isNull);
    await backend.openRoom(_roomId);
    expect(backend.focusedEventId, isNull);
  });

  test('rejects non-joined rooms and malformed event IDs', () async {
    final backend = MatrixBackend.withClient(
      _Client(_Database(), (_) async => http.Response('{}', 200)),
    );
    addTearDown(backend.dispose);
    await expectLater(
      backend.openRoomAt('!unknown:matrix.example', r'$x'),
      throwsStateError,
    );
    await expectLater(
      backend.openRoomAt(_roomId, 'not-an-event'),
      throwsArgumentError,
    );
    expect(backend.activeRoomId, isNull);
  });
}
