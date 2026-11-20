// Exercises MatrixSavedFeatures against the real SDK request builders with a
// mock homeserver. These prove request shapes, read-modify-write ordering and
// session guards, not live homeserver or cross-client interoperability.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/saved/matrix_saved_features.dart';
import 'package:parallax/features/saved/saved_features.dart';
import 'package:parallax/features/saved/saved_models.dart';
import 'package:parallax/matrix_backend.dart';

const me = '@me:example.org';
const noteType = SavedAccountData.noteToSelf;
const bookmarkType = SavedAccountData.bookmarks;
const folderType = SavedAccountData.folders;

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async =>
      null;
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super('saved', database: _Database(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
  }
  bool cryptoAvailable = true;
  @override
  String get userID => me;
  @override
  String get deviceID => 'DEVICE';
  @override
  bool get encryptionEnabled => cryptoAvailable;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Request {
  _Request(this.method, this.segments, this.body);
  final String method;
  final List<String> segments;
  final Map<String, Object?>? body;
  String get path => segments.join('/');
  @override
  String toString() => '$method $path';
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _notFound() =>
    _json({'errcode': 'M_NOT_FOUND', 'error': 'Not found'}, 404);

/// A tiny homeserver: account data store, createRoom, joined_rooms, events.
class _Server {
  final accountData = <String, Map<String, Object?>>{};
  final log = <_Request>[];
  final joinedRooms = <String>[];
  final events = <String, Map<String, Object?>>{};
  int created = 0;
  void Function(String roomId)? onCreated;
  void Function(String type, Map<String, Object?> body)? onPut;
  FutureOr<void> Function()? onJoinedRooms;

  http.Response handle(_Request request) {
    final s = request.segments;
    if (s.length >= 7 && s[3] == 'user' && s[5] == 'account_data') {
      expect(s[4], me);
      final type = s[6];
      if (request.method == 'GET') {
        final value = accountData[type];
        return value == null ? _notFound() : _json(value);
      }
      accountData[type] = request.body!;
      onPut?.call(type, request.body!);
      return _json({});
    }
    if (request.path.endsWith('/createRoom')) {
      created++;
      final roomId = '!created$created:example.org';
      onCreated?.call(roomId);
      return _json({'room_id': roomId});
    }
    if (request.path.endsWith('/joined_rooms')) {
      onJoinedRooms?.call();
      return _json({'joined_rooms': joinedRooms});
    }
    if (s.length >= 7 && s[3] == 'rooms' && s[5] == 'event') {
      final event = events[s[6]];
      return event == null ? _notFound() : _json(event);
    }
    return _notFound();
  }
}

({MatrixBackend backend, _Client client, _Server server}) _setup() {
  final server = _Server();
  final client = _Client(
    MockClient((request) async {
      final entry = _Request(
        request.method,
        request.url.pathSegments,
        request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map<String, Object?>,
      );
      server.log.add(entry);
      return server.handle(entry);
    }),
  );
  final backend = MatrixBackend.withClient(client);
  addTearDown(backend.dispose);
  return (backend: backend, client: client, server: server);
}

void _sync(matrix.Client client, String type, Map<String, Object?> content) {
  client.accountData[type] = matrix.BasicEvent(type: type, content: content);
}

List<String> _writes(_Server server) => [
  for (final request in server.log)
    if (request.method != 'GET') request.toString(),
];

void main() {
  test('resolver caches one live adapter per backend', () {
    final setup = _setup();
    final features = savedFeaturesOf(setup.backend);
    expect(features, isA<MatrixSavedFeatures>());
    expect(savedFeaturesOf(setup.backend), same(features));
  });

  group('note to self', () {
    test('creates a private encrypted room with nobody else, records it '
        'and marks it as a DM with yourself', () async {
      final setup = _setup();
      setup.server.onCreated = (roomId) =>
          setup.client.rooms.add(matrix.Room(id: roomId, client: setup.client));
      final features = savedFeaturesOf(setup.backend)!;

      final roomId = await features.openNoteToSelf();

      expect(roomId, '!created1:example.org');
      final create = setup.server.log.singleWhere(
        (r) => r.path.endsWith('/createRoom'),
      );
      expect(create.method, 'POST');
      expect(create.body!['name'], 'Note to self');
      expect(create.body!['preset'], 'private_chat');
      expect(create.body!['is_direct'], true);
      expect(create.body!.containsKey('invite'), isFalse);
      expect(create.body!.containsKey('invite_3pid'), isFalse);
      expect(create.body!['initial_state'], [
        {
          'content': {'algorithm': 'm.megolm.v1.aes-sha2'},
          'state_key': '',
          'type': 'm.room.encryption',
        },
      ]);
      // Record first (the reuse anchor), then m.direct.
      expect(_writes(setup.server), [
        'POST _matrix/client/v3/createRoom',
        'PUT _matrix/client/v3/user/$me/account_data/$noteType',
        'PUT _matrix/client/v3/user/$me/account_data/m.direct',
      ]);
      expect(setup.server.accountData[noteType], {'room_id': roomId});
      expect(setup.server.accountData['m.direct'], {
        me: [roomId],
      });
      // The local overlay shows the room before sync echoes account data.
      expect(features.noteToSelfRoomId, roomId);
    });

    test('reuses the synced record without any request', () async {
      final setup = _setup();
      const roomId = '!note:example.org';
      setup.client.rooms.add(matrix.Room(id: roomId, client: setup.client));
      _sync(setup.client, noteType, {'room_id': roomId});
      _sync(setup.client, 'm.direct', {
        me: [roomId],
      });
      final features = savedFeaturesOf(setup.backend)!;

      expect(features.noteToSelfRoomId, roomId);
      expect(await features.openNoteToSelf(), roomId);
      expect(setup.server.log, isEmpty);
    });

    test(
      'adopts a note created on another device since the last sync',
      () async {
        final setup = _setup();
        const roomId = '!elsewhere:example.org';
        setup.client.rooms.add(matrix.Room(id: roomId, client: setup.client));
        setup.server.accountData[noteType] = {'room_id': roomId, 'x': 1};
        setup.server.accountData['m.direct'] = {
          me: [roomId],
        };
        _sync(setup.client, 'm.direct', {
          me: [roomId],
        });
        final features = savedFeaturesOf(setup.backend)!;
        expect(features.noteToSelfRoomId, isNull);

        expect(await features.openNoteToSelf(), roomId);
        expect(setup.server.created, 0);
        expect(_writes(setup.server), isEmpty);
        expect(features.noteToSelfRoomId, roomId);
      },
    );

    test('recovers an earlier self-DM whose record write failed instead of '
        'creating another room', () async {
      final setup = _setup();
      const roomId = '!old:example.org';
      setup.client.rooms.add(
        matrix.Room(
          id: roomId,
          client: setup.client,
          summary: matrix.RoomSummary.fromJson({'m.joined_member_count': 1}),
        ),
      );
      _sync(setup.client, 'm.direct', {
        me: [roomId],
      });
      final features = savedFeaturesOf(setup.backend)!;

      expect(await features.openNoteToSelf(), roomId);
      expect(setup.server.created, 0);
      expect(setup.server.accountData[noteType], {'room_id': roomId});
    });

    test(
      'a self-DM with another member is not mistaken for the note',
      () async {
        final setup = _setup();
        setup.server.onCreated = (roomId) => setup.client.rooms.add(
          matrix.Room(id: roomId, client: setup.client),
        );
        setup.client.rooms.add(
          matrix.Room(
            id: '!shared:example.org',
            client: setup.client,
            summary: matrix.RoomSummary.fromJson({'m.joined_member_count': 2}),
          ),
        );
        _sync(setup.client, 'm.direct', {
          me: ['!shared:example.org'],
        });
        setup.server.accountData['m.direct'] = {
          me: ['!shared:example.org'],
          '@alex:example.org': ['!dm:example.org'],
        };
        final features = savedFeaturesOf(setup.backend)!;

        expect(await features.openNoteToSelf(), '!created1:example.org');
        // m.direct is re-read from the server and other DMs are kept.
        expect(setup.server.accountData['m.direct'], {
          me: ['!shared:example.org', '!created1:example.org'],
          '@alex:example.org': ['!dm:example.org'],
        });
      },
    );

    test('fails closed without creating a room when encryption is '
        'unavailable', () async {
      final setup = _setup()..client.cryptoAvailable = false;
      final features = savedFeaturesOf(setup.backend)!;

      await expectLater(
        features.openNoteToSelf(),
        throwsA(isA<NoteToSelfUnavailable>()),
      );
      expect(setup.server.created, 0);
      expect(_writes(setup.server), isEmpty);
    });

    test('concurrent opens share one creation request', () async {
      final setup = _setup();
      setup.server.onCreated = (roomId) =>
          setup.client.rooms.add(matrix.Room(id: roomId, client: setup.client));
      final features = savedFeaturesOf(setup.backend)!;

      final results = await Future.wait([
        features.openNoteToSelf(),
        features.openNoteToSelf(),
      ]);
      expect(results, ['!created1:example.org', '!created1:example.org']);
      expect(setup.server.created, 1);
    });

    test('a slow sync reports not-synced, and the retry reuses the room '
        'instead of creating a second one', () async {
      final setup = _setup();
      final features = MatrixSavedFeatures(
        setup.backend,
        setup.backend,
        syncWait: const Duration(milliseconds: 30),
      );

      await expectLater(
        features.openNoteToSelf(),
        throwsA(isA<NoteToSelfNotSynced>()),
      );
      expect(setup.server.created, 1);
      const roomId = '!created1:example.org';
      expect(setup.server.accountData[noteType], {'room_id': roomId});

      // The server lists the room as joined; it then arrives through sync.
      setup.server.joinedRooms.add(roomId);
      setup.server.onJoinedRooms = () {
        Timer(const Duration(milliseconds: 5), () {
          setup.client.rooms.add(matrix.Room(id: roomId, client: setup.client));
          setup.client.onSyncStatus.add(
            const matrix.SyncStatusUpdate(matrix.SyncStatus.finished),
          );
        });
      };
      expect(await features.openNoteToSelf(), roomId);
      expect(setup.server.created, 1);
    });

    test('unpinning is synced and keeps the record\'s other fields', () async {
      final setup = _setup();
      setup.server.accountData[noteType] = {
        'room_id': '!note:example.org',
        'future': true,
      };
      final features = savedFeaturesOf(setup.backend)!;
      expect(features.noteToSelfPinned, isTrue);

      await features.setNoteToSelfPinned(false);
      expect(setup.server.accountData[noteType], {
        'room_id': '!note:example.org',
        'future': true,
        'unpinned': true,
      });
      expect(features.noteToSelfPinned, isFalse);

      // Pinned is the default, so pinning again drops the key.
      await features.setNoteToSelfPinned(true);
      expect(setup.server.accountData[noteType], {
        'room_id': '!note:example.org',
        'future': true,
      });
      expect(features.noteToSelfPinned, isTrue);
    });

    test('dismissing the prompt keeps the record\'s other fields', () async {
      final setup = _setup();
      setup.server.accountData[noteType] = {'future': true};
      final features = savedFeaturesOf(setup.backend)!;
      expect(features.noteToSelfPromptDismissed, isFalse);

      await features.dismissNoteToSelfPrompt();
      expect(setup.server.accountData[noteType], {
        'future': true,
        'prompt_dismissed': true,
      });
      expect(features.noteToSelfPromptDismissed, isTrue);
    });
  });

  group('bookmarks', () {
    const room = '!room:example.org';

    test('saving re-reads the server, writes identifiers only and puts the '
        'newest first', () async {
      final setup = _setup();
      setup.server.accountData[bookmarkType] = {
        'bookmarks': [
          {'room_id': room, 'event_id': r'$old', 'saved_ts': 100},
        ],
        'version': 2,
      };
      final features = savedFeaturesOf(setup.backend)!;
      expect(features.bookmarks.isEmpty, isTrue); // Not synced yet.

      await features.setSaved(room, r'$new', saved: true);

      final written = setup.server.accountData[bookmarkType]!;
      expect(written['version'], 2);
      final list = written['bookmarks']! as List;
      expect(
        [for (final b in list) (b as Map)['event_id']],
        [r'$new', r'$old'],
      );
      expect((list.first as Map).keys.toSet(), {
        'room_id',
        'event_id',
        'saved_ts',
      });
      expect(features.bookmarks.contains(room, r'$new'), isTrue);
      expect(features.bookmarks.contains(room, r'$old'), isTrue);
    });

    test('quick successive changes are serialised and none is lost', () async {
      final setup = _setup();
      final features = savedFeaturesOf(setup.backend)!;
      await Future.wait([
        features.setSaved(room, r'$a', saved: true, savedAt: DateTime(2026)),
        features.setSaved(room, r'$b', saved: true, savedAt: DateTime(2026, 2)),
        features.setSaved(room, r'$a', saved: false),
      ]);
      final list = BookmarkList.fromJson(
        setup.server.accountData[bookmarkType],
      );
      expect([for (final b in list.bookmarks) b.eventId], [r'$b']);
      final puts = setup.server.log.where((r) => r.method == 'PUT').length;
      expect(puts, 3);
    });

    test('newer account data from sync replaces the local copy', () async {
      final setup = _setup();
      final features = savedFeaturesOf(setup.backend)!;
      await features.setSaved(room, r'$mine', saved: true);
      expect(features.bookmarks.contains(room, r'$mine'), isTrue);

      // Another device removed it and added something else.
      _sync(setup.client, bookmarkType, {
        'bookmarks': [
          {'room_id': room, 'event_id': r'$theirs', 'saved_ts': 5},
        ],
      });
      expect(features.bookmarks.contains(room, r'$mine'), isFalse);
      expect(features.bookmarks.contains(room, r'$theirs'), isTrue);
    });

    test('rejects local echoes and invalid identifiers', () async {
      final setup = _setup();
      final features = savedFeaturesOf(setup.backend)!;
      await expectLater(
        features.setSaved(room, 'txn-1', saved: true),
        throwsArgumentError,
      );
      expect(setup.server.log, isEmpty);
    });

    test('a write that completes after sign-out is not adopted', () async {
      final setup = _setup();
      setup.server.onPut = (_, _) => setup.client.accessToken = null;
      final features = savedFeaturesOf(setup.backend)!;
      await expectLater(
        features.setSaved(room, r'$e', saved: true),
        throwsStateError,
      );
      expect(features.bookmarks.isEmpty, isTrue);
    });

    test('loads saved events from the server and reports left rooms and '
        'missing events', () async {
      final setup = _setup();
      setup.client.rooms.add(matrix.Room(id: room, client: setup.client));
      setup.server.events[r'$e'] = {
        'type': 'm.room.message',
        'event_id': r'$e',
        'room_id': room,
        'sender': '@alex:example.org',
        'origin_server_ts': 1700000000000,
        'content': {'msgtype': 'm.text', 'body': 'Remember the milk'},
      };
      final features = savedFeaturesOf(setup.backend)!;

      final loaded = await features.loadSavedEvent(room, r'$e');
      expect(loaded.status, SavedEventStatus.available);
      expect(loaded.entry!.body, 'Remember the milk');
      expect(loaded.entry!.sender, '@alex:example.org');

      expect(
        (await features.loadSavedEvent(room, r'$gone')).status,
        SavedEventStatus.notFound,
      );
      expect(
        (await features.loadSavedEvent('!left:example.org', r'$e')).status,
        SavedEventStatus.roomUnavailable,
      );
      // Cached: no second fetch of the same event.
      final fetches = setup.server.log.length;
      await features.loadSavedEvent(room, r'$e');
      expect(setup.server.log.length, fetches);
    });
  });

  group('folders', () {
    test('updates apply to the fresh server value and keep unknown '
        'fields', () async {
      final setup = _setup();
      setup.server.accountData[folderType] = {
        'folders': [
          {
            'id': 'work',
            'name': 'Work',
            'include_rooms': ['!a:example.org'],
            'colour': 'red',
          },
        ],
        'schema': 1,
      };
      final features = savedFeaturesOf(setup.backend)!;

      final written = await features.updateFolders(
        (current) => current.withUpserted(
          const ChatFolder(
            id: 'home',
            name: 'Home',
            include: FolderIncludes(people: true),
          ),
        ),
      );
      expect([for (final f in written.folders) f.id], ['work', 'home']);
      final stored = setup.server.accountData[folderType]!;
      expect(stored['schema'], 1);
      expect(((stored['folders']! as List).first as Map)['colour'], 'red');
      expect(features.folders.byId('home')?.include.people, isTrue);
    });

    test('a malformed record cannot break the inbox', () {
      final setup = _setup();
      _sync(setup.client, folderType, {'folders': 'nope'});
      _sync(setup.client, bookmarkType, {'bookmarks': 42});
      final features = savedFeaturesOf(setup.backend)!;
      expect(features.folders.isEmpty, isTrue);
      expect(features.bookmarks.isEmpty, isTrue);
    });
  });
}
