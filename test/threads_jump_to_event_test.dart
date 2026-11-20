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
      : [for (final json in cached) matrix.Event.fromJson(json, room)];

  @override
  Future<List<matrix.Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    matrix.Room room,
  ) async => const [];

  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async => null;

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
  test('server context focuses the event and hides newer messages', () async {
    final requests = <String>[];
    final db = _Database()
      ..cached = [_event(r'$live2', 9000), _event(r'$live1', 8000)];
    final client = _Client(db, (request) async {
      requests.add(request.url.path);
      if (request.url.path.contains('/context/')) {
        expect(Uri.decodeComponent(request.url.path), endsWith(r'/$target'));
        return http.Response(
          jsonEncode({
            'event': _event(r'$target', 2000, body: 'pizza tonight'),
            'events_before': [_event(r'$before', 1000)],
            'events_after': [_event(r'$after', 3000)],
            'start': 'start-token',
            'end': 'end-token',
            'state': <Object?>[],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    final navigation = timelineNavigationOf(backend)!;

    await navigation.openRoomAt(_roomId, r'$target');

    expect(backend.activeRoomId, _roomId);
    expect(navigation.focusedEventIn(_roomId), r'$target');
    expect(navigation.focusedEventIn('!other:matrix.example'), isNull);
    expect(navigation.hasNewerThanFocus(_roomId), isTrue);
    // Oldest first, ending at the focused event.
    expect(backend.messages.map((e) => e.id), [r'$before', r'$target']);
    // A focused timeline never sends read receipts.
    expect(requests.where((path) => path.contains('read_markers')), isEmpty);

    // The room screen's own openRoom keeps the focused timeline.
    await backend.openRoom(_roomId);
    expect(navigation.focusedEventIn(_roomId), r'$target');

    await navigation.jumpToLatest(_roomId);
    expect(navigation.focusedEventIn(_roomId), isNull);
    expect(backend.messages.map((e) => e.id), [r'$live1', r'$live2']);
  });

  test('cached event focuses without a request and reveals in place', () async {
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
    expect(requests.where((path) => path.contains('/context/')), isEmpty);
    expect(backend.messages.map((e) => e.id), [r'$older', r'$target']);
    expect(navigation.hasNewerThanFocus(_roomId), isTrue);

    await navigation.jumpToLatest(_roomId);
    expect(navigation.focusedEventIn(_roomId), isNull);
    expect(backend.messages.map((e) => e.id), [
      r'$older',
      r'$target',
      r'$newest',
    ]);
  });

  test('unknown event fails without leaving a half-open room', () async {
    final client = _Client(
      _Database(),
      (request) async => http.Response(
        jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'Event not found'}),
        404,
      ),
    );
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    await expectLater(
      timelineNavigationOf(backend)!.openRoomAt(_roomId, r'$missing'),
      throwsA(anything),
    );
    expect(backend.activeRoomId, isNull);
    expect(backend.focusedEventId, isNull);
    // The room still opens normally afterwards.
    await backend.openRoom(_roomId);
    expect(backend.activeRoomId, _roomId);
    expect(backend.focusedEventId, isNull);
  });

  test('closing the room clears the focus', () async {
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

  test(
    'scrolling down reveals newer messages page by page to the live end',
    () async {
      final requests = <String>[];
      final db = _Database()
        ..cached = [_event(r'$live2', 9000), _event(r'$live1', 8000)];
      final client = _Client(db, (request) async {
        final path = request.url.path;
        requests.add(path);
        if (path.contains('/context/')) {
          return http.Response(
            jsonEncode({
              'event': _event(r'$target', 2000),
              'events_before': [_event(r'$before', 1000)],
              'events_after': [_event(r'$after', 3000)],
              'start': 'start-token',
              'end': 'end-token',
              'state': <Object?>[],
            }),
            200,
          );
        }
        if (path.contains('/messages') &&
            request.url.queryParameters['dir'] == 'f') {
          final from = request.url.queryParameters['from'];
          // Forward pages arrive oldest first; start == end means the live end.
          final pages = {
            'end-token': ([_event(r'$newer1', 4000)], 'page2-token'),
            'page2-token': ([_event(r'$newer2', 5000)], 'live-token'),
            'live-token': (<Map<String, Object?>>[], 'live-token'),
          };
          final page = pages[from];
          expect(page, isNotNull, reason: 'unexpected forward page $from');
          return http.Response(
            jsonEncode({
              'chunk': page!.$1,
              'start': from,
              'end': page.$2,
              'state': <Object?>[],
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      final navigation = timelineNavigationOf(backend)!;

      await navigation.openRoomAt(_roomId, r'$target');
      expect(backend.messages.map((e) => e.id), [r'$before', r'$target']);

      // First scroll down reveals the newer message loaded with the context.
      await backend.loadNewer(_roomId);
      expect(backend.messages.map((e) => e.id), [
        r'$before',
        r'$target',
        r'$after',
      ]);
      expect(navigation.focusedEventIn(_roomId), r'$target');
      expect(navigation.hasNewerThanFocus(_roomId), isTrue);

      // Further scrolls page forward through the server context.
      await backend.loadNewer(_roomId);
      expect(backend.messages.last.id, r'$newer1');
      expect(navigation.focusedEventIn(_roomId), r'$target');
      await backend.loadNewer(_roomId);
      expect(backend.messages.last.id, r'$newer2');
      expect(navigation.focusedEventIn(_roomId), r'$target');

      // Reaching the live end leaves the focus, like "Jump to latest".
      await backend.loadNewer(_roomId);
      expect(navigation.focusedEventIn(_roomId), isNull);
      expect(navigation.hasNewerThanFocus(_roomId), isFalse);
      expect(backend.messages.map((e) => e.id), [
        r'$before',
        r'$target',
        r'$after',
        r'$newer1',
        r'$newer2',
      ]);
      // A focused timeline never sends read receipts, even while paging.
      expect(requests.where((path) => path.contains('read_markers')), isEmpty);
    },
  );

  test('a cached timeline reveals its newer messages in place', () async {
    final requests = <String>[];
    final db = _Database()
      ..cached = [
        _event(r'$newest', 3000),
        _event(r'$target', 2000),
        _event(r'$older', 1000),
      ];
    final backend = MatrixBackend.withClient(
      _Client(db, (request) async {
        requests.add(request.url.path);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(backend.dispose);
    final navigation = timelineNavigationOf(backend)!;

    await navigation.openRoomAt(_roomId, r'$target');
    expect(backend.messages.map((e) => e.id), [r'$older', r'$target']);

    await backend.loadNewer(_roomId);
    expect(navigation.focusedEventIn(_roomId), isNull);
    expect(navigation.hasNewerThanFocus(_roomId), isFalse);
    expect(backend.messages.map((e) => e.id), [
      r'$older',
      r'$target',
      r'$newest',
    ]);
    expect(requests.where((p) => p.contains('/messages')), isEmpty);
  });

  test('loadNewer without a focused timeline does nothing', () async {
    final requests = <String>[];
    final db = _Database()..cached = [_event(r'$a', 1000)];
    final backend = MatrixBackend.withClient(
      _Client(db, (request) async {
        requests.add(request.url.path);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(backend.dispose);
    await backend.openRoom(_roomId);
    await backend.loadNewer(_roomId);
    await backend.loadNewer('!other:matrix.example');
    expect(backend.focusedEventId, isNull);
    expect(requests.where((p) => p.contains('/messages')), isEmpty);
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
