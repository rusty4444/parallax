import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';

class _Database extends Fake implements matrix.DatabaseApi {
  /// Members stored by an earlier sync (lazy loading keeps them out of
  /// memory for rooms not opened yet).
  final names = <String, String>{};

  @override
  Future<void> close() async {}

  @override
  Future<List<matrix.User>> getUsers(matrix.Room room) async => [];

  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async {
    final name = names[userId];
    return name == null
        ? null
        : matrix.User(
            userId,
            room: room,
            displayName: name,
            membership: 'join',
          );
  }
}

/// The server's current member names, as GET .../state/m.room.member/{user}.
final serverNames = <String, String>{};

/// Full /members responses for groups whose avatar heroes must be loaded.
final serverMembers = <String, List<Map<String, Object?>>>{};

class _Client extends matrix.Client {
  _Client()
    : super(
        'projection-test',
        database: _Database(),
        httpClient: MockClient((request) async {
          final path = Uri.decodeComponent(request.url.path);
          if (path.endsWith('/members')) {
            const prefix = '/rooms/';
            final start = path.indexOf(prefix);
            final roomId = start < 0
                ? null
                : path.substring(
                    start + prefix.length,
                    path.length - '/members'.length,
                  );
            final members = serverMembers[roomId];
            if (members != null) {
              return http.Response(
                jsonEncode({'chunk': members}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
          }
          final marker = '/state/m.room.member/';
          final at = path.indexOf(marker);
          final name = at < 0
              ? null
              : serverNames[path.substring(at + marker.length)];
          if (name != null) {
            return http.Response(
              '{"membership":"join","displayname":"$name"}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
        }),
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
    r.setState(
      matrix.Event(
        type: matrix.EventTypes.RoomMember,
        stateKey: '@friend:example.org',
        senderId: '@friend:example.org',
        content: const {'membership': 'join', 'displayname': 'Friend'},
        room: r,
        eventId: '\$member-$id',
        originServerTs: DateTime(2026, 11, 12),
      ),
    );
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

  test(
    'the end of every sync projects nothing once the list is ready',
    () async {
      final before = backend.rooms;
      // The SDK reports "finished" after every sync, empty long polls too.
      for (var i = 0; i < 3; i++) {
        backend.debugSyncStatus(
          matrix.SyncStatusUpdate(matrix.SyncStatus.finished),
        );
      }
      await settle();
      expect(identical(backend.rooms, before), isTrue);
      expect(backend.debugRoomProjections, 3);
      expect(notifications, 1);
    },
  );

  test('an encrypted preview retried without change notifies no one', () async {
    final r = client.getRoomById('!b:example.org')!;
    r.lastEvent = matrix.Event(
      type: matrix.EventTypes.Encrypted,
      senderId: '@friend:example.org',
      content: const {'algorithm': 'm.megolm.v1.aes-sha2', 'ciphertext': 'x'},
      room: r,
      eventId: r'$sealed',
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
    expect(notifications, 2);
    final before = backend.rooms;

    // Later syncs retry it; the key hasn't arrived, so nothing changes.
    backend.debugRoomsSynced(matrix.SyncUpdate(nextBatch: '3'));
    await settle();
    expect(backend.debugRoomProjections, 5);
    expect(identical(backend.rooms, before), isTrue);
    expect(notifications, 2);

    // The key arrives: the decrypted preview replaces it.
    r.lastEvent = matrix.Event(
      type: matrix.EventTypes.Message,
      senderId: '@friend:example.org',
      content: const {'msgtype': 'm.text', 'body': 'decrypted'},
      room: r,
      eventId: r'$sealed',
      originServerTs: DateTime(2026, 11, 13),
    );
    backend.debugRoomsSynced(matrix.SyncUpdate(nextBatch: '4'));
    await settle();
    expect(notifications, 3);
    expect(
      backend.rooms.firstWhere((room) => room.id == '!b:example.org').preview,
      'decrypted',
    );
  });

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

  test('other account data notifies without projecting rooms', () async {
    final before = backend.rooms;
    backend.debugRoomsSynced(
      matrix.SyncUpdate(
        nextBatch: '2',
        accountData: [
          matrix.BasicEvent(type: 'io.element.recent_emoji', content: const {}),
        ],
      ),
    );
    await settle();
    expect(backend.debugRoomProjections, 3);
    expect(identical(backend.rooms, before), isTrue);
    expect(notifications, 2);
  });

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

  test('a preview sender not loaded yet never shows their Matrix ID', () async {
    const ghost = '@whatsapp_lid-100000000000001:example.org';
    (client.database as _Database).names[ghost] = 'Gen (WA)';
    final r = matrix.Room(id: '!d:example.org', client: client);
    r.lastEvent = matrix.Event(
      type: matrix.EventTypes.Message,
      senderId: ghost,
      content: const {'msgtype': 'm.text', 'body': 'Love our little bmfer'},
      room: r,
      eventId: r'$bmf',
      originServerTs: DateTime(2026, 11, 14),
    );
    client.rooms.add(r);
    final seen = <String?>[];
    backend.addListener(() {
      for (final room in backend.rooms) {
        if (room.id == '!d:example.org') seen.add(room.previewSender);
      }
    });
    backend.debugRoomsSynced(
      matrix.SyncUpdate(
        nextBatch: '2',
        rooms: matrix.RoomsUpdate(
          join: {'!d:example.org': matrix.JoinedRoomUpdate()},
        ),
      ),
    );
    await settle();
    await settle();
    // First without a sender, then with the name from the database.
    expect(seen.first, isNull);
    expect(seen.last, 'Gen (WA)');
    expect(seen, isNot(contains(ghost)));
    final projected = backend.rooms.firstWhere((r) => r.id == '!d:example.org');
    expect(projected.preview, 'Love our little bmfer');
  });

  test('a shown room checks its people with the server once', () async {
    // Friend was renamed while the app wasn't syncing: the stored copy
    // (in memory) still says "Friend".
    serverNames['@friend:example.org'] = 'Friend Renamed';
    addTearDown(serverNames.clear);
    final before = backend.debugRoomProjections;
    backend.roomShown('!a:example.org');
    backend.roomShown('!a:example.org');
    await settle();
    await settle();
    final a = backend.rooms.firstWhere((r) => r.id == '!a:example.org');
    expect(a.previewSender, 'Friend Renamed');
    // Only that room was projected again.
    expect(backend.debugRoomProjections, before + 1);
  });

  test(
    'a shown direct-marked group loads its four-person avatar stack',
    () async {
      const id = '!group:example.org';
      final r = matrix.Room(
        id: id,
        client: client,
        summary: matrix.RoomSummary.fromJson({
          'm.heroes': <String>[],
          'm.joined_member_count': 5,
          'm.invited_member_count': 0,
        }),
      );
      r.setState(
        matrix.Event(
          type: matrix.EventTypes.RoomName,
          stateKey: '',
          senderId: '@meta_1:example.org',
          content: const {'name': '#FAM'},
          room: r,
          eventId: r'$room-name',
          originServerTs: DateTime(2026, 11, 12),
        ),
      );
      r.lastEvent = matrix.Event(
        type: matrix.EventTypes.Message,
        senderId: '@meta_1:example.org',
        content: const {'msgtype': 'm.text', 'body': 'Hello family'},
        room: r,
        eventId: r'$group-message',
        originServerTs: DateTime(2026, 11, 13),
      );
      client.accountData['m.direct'] = matrix.BasicEvent(
        type: 'm.direct',
        content: const {
          '@meta_1:example.org': [id],
        },
      );
      client.rooms.add(r);
      serverMembers[id] = [
        for (var i = 1; i <= 4; i++)
          {
            'type': 'm.room.member',
            'state_key': '@meta_$i:example.org',
            'sender': '@meta_$i:example.org',
            'content': {
              'membership': 'join',
              'displayname': 'Person $i',
              'avatar_url': 'mxc://example.org/person$i',
            },
            'event_id': '\$member-$i',
            'origin_server_ts': i,
          },
      ];
      addTearDown(() => serverMembers.remove(id));
      backend.debugRoomsSynced(
        matrix.SyncUpdate(
          nextBatch: '2',
          rooms: matrix.RoomsUpdate(join: {id: matrix.JoinedRoomUpdate()}),
        ),
      );
      await settle();

      backend.roomShown(id);
      await settle();
      await settle();
      await settle();

      final projected = backend.rooms.firstWhere((room) => room.id == id);
      expect(projected.name, '#FAM');
      expect(projected.isDirect, isTrue);
      expect(projected.avatarUrl, isNull);
      expect(projected.heroes.map((hero) => hero.name), [
        'Person 1',
        'Person 2',
        'Person 3',
        'Person 4',
      ]);
      expect(projected.heroes.map((hero) => hero.url.toString()), [
        'mxc://example.org/person1',
        'mxc://example.org/person2',
        'mxc://example.org/person3',
        'mxc://example.org/person4',
      ]);
    },
  );

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
