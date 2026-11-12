import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/packs/matrix_packs.dart';
import 'package:parallax/features/packs/pack_model.dart';
import 'package:parallax/room_events.dart';

const _roomId = '!room:example.org';
const _otherId = '!other:example.org';
const _me = '@sam:example.org';

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client()
    : super(
        'packs-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
  }

  final roomsById = <String, matrix.Room>{};
  final serverAccountData = <String, Map<String, Object?>>{};
  final accountWrites = <String>[];
  final uploads = <String>[];
  Completer<void>? readGate;

  @override
  String? get userID => _me;

  @override
  matrix.Room? getRoomById(String id) => roomsById[id];

  @override
  Future<Map<String, Object?>> getAccountData(
    String userId,
    String type,
  ) async {
    await readGate?.future;
    final data = serverAccountData[type];
    if (data == null) {
      throw matrix.MatrixException.fromJson({
        'errcode': 'M_NOT_FOUND',
        'error': 'not found',
      });
    }
    return data;
  }

  @override
  Future<void> setAccountData(
    String userId,
    String type,
    Map<String, Object?> body,
  ) async {
    accountWrites.add(type);
    serverAccountData[type] = body;
  }

  @override
  Future<Uri> uploadContent(
    Uint8List file, {
    String? filename,
    String? contentType,
  }) async {
    uploads.add('$filename $contentType');
    return Uri.parse('mxc://example.org/uploaded');
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Backend implements MatrixSdkAccess, RoomEventFeatures {
  _Backend(this.client);
  final _Client client;
  bool current = true;
  bool offline = false;
  final serverState = <String, Map<String, Object?>>{};
  final stateWrites = <String>[];
  final sent = <({String room, String type, Map<String, Object?> content})>[];

  @override
  matrix.Client? get sdkClient => current && !offline ? client : null;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    sent.add((room: roomId, type: type, content: content));
    return r'$sent';
  }

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async {
    await client.readGate?.future;
    return serverState['$roomId|$type|$stateKey'];
  }

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {
    stateWrites.add('$roomId|$stateKey');
    serverState['$roomId|$type|$stateKey'] = content;
  }

  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async {}
}

matrix.Room _room(_Client client, String id, String name) {
  final room = matrix.Room(
    id: id,
    client: client,
    membership: matrix.Membership.join,
  )..partial = false;
  room.setState(
    matrix.Event.fromJson({
      'type': matrix.EventTypes.RoomName,
      'state_key': '',
      'sender': _me,
      'event_id': '\$name$id',
      'origin_server_ts': 1,
      'content': {'name': name},
    }, room),
  );
  client.roomsById[id] = room;
  return room;
}

void _packState(
  matrix.Room room,
  String stateKey,
  Map<String, Object?> content,
) => room.setState(
  matrix.Event.fromJson({
    'type': roomPackEventType,
    'state_key': stateKey,
    'sender': _me,
    'event_id': '\$pack${room.id}$stateKey${content.hashCode}',
    'origin_server_ts': 2,
    'content': content,
  }, room),
);

Map<String, Object?> _images(Map<String, String> codes, {String? name}) => {
  'images': {
    for (final entry in codes.entries)
      entry.key: {'url': 'mxc://example.org/${entry.value}'},
  },
  'pack': {'display_name': ?name},
};

void main() {
  late _Client client;
  late _Backend backend;
  late MatrixPacks packs;
  late matrix.Room room;
  late matrix.Room other;

  setUp(() {
    client = _Client();
    backend = _Backend(client);
    packs = MatrixPacks(backend, backend);
    room = _room(client, _roomId, 'Kangaroo Club');
    other = _room(client, _otherId, 'Wombats');
    client.accountData[userPackEventType] = matrix.BasicEvent(
      type: userPackEventType,
      content: _images({'wave': 'p-wave'}, name: 'Mine'),
    );
    client.accountData[emoteRoomsEventType] = matrix.BasicEvent(
      type: emoteRoomsEventType,
      content: {
        'rooms': {
          _otherId: {'': {}},
        },
      },
    );
    _packState(room, '', _images({'wave': 'r-wave', 'roo': 'r-roo'}));
    _packState(other, '', _images({'wombat': 'g-wombat'}, name: 'Wombat'));
  });

  tearDown(() => packs.dispose());

  test('available packs merge account data and room state', () {
    final available = packs.availablePacks(_roomId);
    expect(available.packs.map((p) => (p.scope, p.name)), [
      (PackScope.personal, 'Mine'),
      (PackScope.room, 'Kangaroo Club'),
      (PackScope.global, 'Wombat'),
    ]);
    expect(available.resolve('wave')!.image.url.path, '/p-wave');
    // Cached while nothing changed; recomputed after a state change.
    expect(identical(packs.availablePacks(_roomId), available), isTrue);
    _packState(room, 'extra', _images({'koala': 'koala'}));
    final next = packs.availablePacks(_roomId);
    expect(identical(next, available), isFalse);
    expect(next.resolve('koala'), isNotNull);
    expect(packs.availablePacks(null).packs.map((p) => p.scope), [
      PackScope.personal,
      PackScope.global,
    ]);
    expect(packs.isEnabledEverywhere(const PackRef.room(_otherId, '')), isTrue);
  });

  test('reaction shortcode lookup for custom emoji keys', () {
    expect(
      packShortcodeForKey(client, _roomId, 'mxc://example.org/r-roo'),
      ':roo:',
    );
    expect(
      packShortcodeForKey(client, _roomId, 'mxc://example.org/g-wombat'),
      ':wombat:',
    );
    expect(packShortcodeForKey(client, _roomId, 'mxc://example.org/x'), isNull);
    expect(packShortcodeForKey(client, _roomId, '👍'), isNull);
  });

  test(
    'room pack updates re-read server state and keep unknown keys',
    () async {
      backend.serverState['$_roomId|$roomPackEventType|'] = {
        ..._images({'wave': 'r-wave', 'newer': 'server-only'}),
        'org.example.top': 'kept',
      };
      var notified = 0;
      packs.addListener(() => notified++);
      final written = await packs.updatePack(
        const PackRef.room(_roomId, ''),
        (current) => current.withImage(
          PackImage(
            shortcode: 'koala',
            url: Uri.parse('mxc://example.org/koala'),
          ),
        ),
      );
      expect(written.images.keys, ['wave', 'newer', 'koala']);
      final stored = backend.serverState['$_roomId|$roomPackEventType|']!;
      expect(stored['org.example.top'], 'kept');
      expect((stored['images'] as Map).keys, ['wave', 'newer', 'koala']);
      expect(backend.stateWrites, ['$_roomId|']);
      expect(notified, 1);
    },
  );

  test(
    'personal pack updates use account data; missing data is empty',
    () async {
      final written = await packs.updatePack(
        const PackRef.personal(),
        (current) => current.copyWith(displayName: 'Mine'),
      );
      expect(written.images, isEmpty);
      expect(client.accountWrites, [userPackEventType]);
      expect((client.serverAccountData[userPackEventType]!['pack'] as Map), {
        'display_name': 'Mine',
      });
    },
  );

  test('a session change during a read prevents the write', () async {
    client.readGate = Completer<void>();
    final update = packs.updatePack(
      const PackRef.room(_roomId, ''),
      (current) => current.copyWith(displayName: 'Late'),
    );
    await Future<void>.delayed(Duration.zero);
    backend.current = false;
    client.readGate!.complete();
    await expectLater(update, throwsStateError);
    expect(backend.stateWrites, isEmpty);
  });

  test('writes are serialised in order', () async {
    final first = packs.updatePack(
      const PackRef.room(_roomId, ''),
      (current) => current.withImage(
        PackImage(shortcode: 'a', url: Uri.parse('mxc://example.org/a')),
      ),
    );
    final second = packs.updatePack(
      const PackRef.room(_roomId, ''),
      (current) => current.withImage(
        PackImage(shortcode: 'b', url: Uri.parse('mxc://example.org/b')),
      ),
    );
    await Future.wait([first, second]);
    final stored = backend.serverState['$_roomId|$roomPackEventType|']!;
    expect((stored['images'] as Map).keys, ['a', 'b']);
  });

  test(
    'use everywhere edits emote_rooms without losing other entries',
    () async {
      client.serverAccountData[emoteRoomsEventType] = {
        'org.example': 1,
        'rooms': {
          _otherId: {'': {}},
        },
      };
      await packs.setEnabledEverywhere(
        const PackRef.room(_roomId, 'extra'),
        enabled: true,
      );
      expect(parseEmoteRooms(client.serverAccountData[emoteRoomsEventType]), {
        _otherId: [''],
        _roomId: ['extra'],
      });
      expect(client.serverAccountData[emoteRoomsEventType]!['org.example'], 1);
    },
  );

  test('new packs take the default state key first, then a slug', () async {
    final first = await packs.createRoomPack(_otherId, 'Ignored');
    expect(first, const PackRef.room(_otherId, ''));
    backend.serverState['$_roomId|$roomPackEventType|'] = _images({
      'wave': 'r-wave',
    });
    final second = await packs.createRoomPack(_roomId, 'Big Pack');
    expect(second, const PackRef.room(_roomId, 'big-pack'));
    expect(
      (backend.serverState['$_roomId|$roomPackEventType|big-pack']!['pack']
          as Map)['display_name'],
      'Big Pack',
    );
  });

  test('deleting a pack empties its state and its everywhere entry', () async {
    client.serverAccountData[emoteRoomsEventType] = {
      'rooms': {
        _otherId: {'': {}},
      },
    };
    await packs.deleteRoomPack(const PackRef.room(_otherId, ''));
    expect(backend.serverState['$_otherId|$roomPackEventType|'], isEmpty);
    expect(parseEmoteRooms(client.serverAccountData[emoteRoomsEventType]), {});
  });

  test('stickers go through the guarded room-event send', () async {
    await packs.sendSticker(
      _roomId,
      PackImage(
        shortcode: 'roo',
        url: Uri.parse('mxc://example.org/roo'),
        info: const {'w': 128, 'h': 96, 'mimetype': 'image/webp'},
      ),
    );
    expect(backend.sent.single.type, 'm.sticker');
    expect(backend.sent.single.content, {
      'body': 'roo',
      'url': 'mxc://example.org/roo',
      'info': {'w': 128, 'h': 96, 'mimetype': 'image/webp'},
    });
  });

  test('uploads return a validated mxc URI', () async {
    final url = await packs.uploadPackImage(
      Uint8List.fromList([1, 2, 3]),
      fileName: 'roo.png',
      mimeType: 'image/png',
    );
    expect(url, Uri.parse('mxc://example.org/uploaded'));
    expect(client.uploads, ['roo.png image/png']);
  });

  test('sync updates for pack data notify listeners', () async {
    packs.availablePacks(_roomId); // attaches to the client
    var notified = 0;
    packs.addListener(() => notified++);
    client.onSync.add(
      matrix.SyncUpdate(
        nextBatch: '1',
        accountData: [matrix.BasicEvent(type: 'm.direct', content: const {})],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notified, 0);
    client.onSync.add(
      matrix.SyncUpdate(
        nextBatch: '2',
        accountData: [
          matrix.BasicEvent(type: userPackEventType, content: const {}),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notified, 1);
  });

  test('offline keeps the session\'s local packs; sign-out clears them', () {
    final online = packs.availablePacks(_roomId);
    backend.offline = true;
    expect(identical(packs.availablePacks(_roomId), online), isTrue);
    backend
      ..offline = false
      ..current = false;
    expect(packs.availablePacks(_roomId).isEmpty, isTrue);
  });

  test('signed out: nothing is available and images are not fetched', () async {
    backend.current = false;
    expect(packs.availablePacks(_roomId).isEmpty, isTrue);
    expect(
      await packs.loadPackImage(Uri.parse('mxc://example.org/wave')),
      isNull,
    );
    expect(
      await packs.loadPackImage(Uri.parse('https://evil.example/x.png')),
      isNull,
    );
    await expectLater(
      packs.updatePack(const PackRef.personal(), (p) => p),
      throwsStateError,
    );
  });
}
