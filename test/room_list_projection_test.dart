import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<void> close() async {}
}

class _Client extends matrix.Client {
  _Client()
    : super(
        'projection-test',
        database: _Database(),
        httpClient: http.Client(),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'token';
  }

  @override
  String? get userID => '@me:example.org';
}

/// Lets the 40 ms projection timer fire.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  late _Client client;
  late MatrixBackend backend;
  var notifications = 0;

  matrix.Room room(String id, String body) {
    final r = matrix.Room(id: id, client: client);
    r.lastEvent = matrix.Event(
      type: matrix.EventTypes.Message,
      senderId: '@friend:example.org',
      content: {'msgtype': 'm.text', 'body': body},
      room: r,
      eventId: '\$$id-$body',
      originServerTs: DateTime(2026, 11, 12),
    );
    return r;
  }

  setUp(() async {
    client = _Client();
    client.rooms.addAll([
      room('!a:example.org', 'first'),
      room('!b:example.org', 'second'),
      room('!c:example.org', 'third'),
    ]);
    backend = MatrixBackend.withClient(client);
    notifications = 0;
    backend.addListener(() => notifications++);
    // The first sync projects every room.
    backend.debugRoomsSynced(matrix.SyncUpdate(nextBatch: '1'));
    await settle();
  });

  tearDown(() => backend.dispose());

  test('the first sync projects every room', () {
    expect(backend.rooms, hasLength(3));
    expect(backend.debugRoomProjections, 3);
    expect(notifications, 1);
  });

  test(
    'a sync that touches no room changes nothing and notifies no one',
    () async {
      final before = backend.rooms;
      backend.debugRoomsSynced(matrix.SyncUpdate(nextBatch: '2'));
      await settle();
      expect(identical(backend.rooms, before), isTrue);
      expect(backend.debugRoomProjections, 3);
      expect(notifications, 1);
    },
  );

  test('a sync touching one room projects only that room', () async {
    final before = {for (final r in backend.rooms) r.id: r};
    client.getRoomById('!b:example.org')!.lastEvent = matrix.Event(
      type: matrix.EventTypes.Message,
      senderId: '@friend:example.org',
      content: {'msgtype': 'm.text', 'body': 'newer'},
      room: client.getRoomById('!b:example.org')!,
      eventId: r'$newer',
      originServerTs: DateTime(2026, 11, 13),
    );
    backend.debugRoomsSynced(
      matrix.SyncUpdate(
        nextBatch: '2',
        rooms: matrix.RoomsUpdate(
          join: {'!b:example.org': matrix.JoinedRoomUpdate()},
        ),
      ),
    );
    await settle();
    expect(backend.debugRoomProjections, 4);
    expect(notifications, 2);
    final after = {for (final r in backend.rooms) r.id: r};
    expect(after['!b:example.org']!.preview, 'newer');
    // Untouched rooms keep their projection; the newest room sorts first.
    expect(
      identical(after['!a:example.org'], before['!a:example.org']),
      isTrue,
    );
    expect(
      identical(after['!c:example.org'], before['!c:example.org']),
      isTrue,
    );
    expect(backend.rooms.first.id, '!b:example.org');
  });

  test(
    'account data (m.direct, push rules) projects every room again',
    () async {
      backend.debugRoomsSynced(
        matrix.SyncUpdate(
          nextBatch: '2',
          accountData: [matrix.BasicEvent(type: 'm.direct', content: const {})],
        ),
      );
      await settle();
      expect(backend.debugRoomProjections, 6);
    },
  );

  test('a left room drops out of the list', () async {
    client.rooms.removeWhere((r) => r.id == '!c:example.org');
    backend.debugRoomsSynced(
      matrix.SyncUpdate(
        nextBatch: '2',
        rooms: matrix.RoomsUpdate(
          leave: {'!c:example.org': matrix.LeftRoomUpdate()},
        ),
      ),
    );
    await settle();
    expect(backend.rooms.map((r) => r.id), isNot(contains('!c:example.org')));
    expect(backend.debugRoomProjections, 3);
  });

  test('favourites are read from the room index', () {
    expect(backend.isFavourite('!a:example.org'), isFalse);
    client
        .getRoomById('!a:example.org')!
        .roomAccountData['m.tag'] = matrix.BasicEvent(
      type: 'm.tag',
      content: const {
        'tags': {'m.favourite': {}},
      },
    );
    expect(backend.isFavourite('!a:example.org'), isTrue);
  });
}
