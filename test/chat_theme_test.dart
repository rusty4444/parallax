import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/features/appearance/chat_theme.dart';
import 'package:parallax/features/notifications/matrix_push_projection.dart';
import 'package:parallax/features/rich_timeline/state_event_text.dart';
import 'package:parallax/room_background_store.dart';
import 'package:parallax/room_events.dart';
import 'package:parallax/timeline_kinds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduled_fakes.dart'
    show RecordingTransport, ScheduledDatabase, jsonResponse;

const _me = '@sam:matrix.example';
const _them = '@alex:matrix.example';
const _roomId = '!room:matrix.example';
const _createId = r'$create';
const _relationsPath =
    '/_matrix/client/v1/rooms/!room%3Amatrix.example/relations/'
    '%24create/net.samrusselltech.parallax.chat_theme';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

class _Server {
  List<Map<String, Object?>> relations = [];
  bool offline = false;
  final requests = <http.Request>[];

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    if (offline) return jsonResponse({'errcode': 'M_UNKNOWN'}, 500);
    if (request.url.path == _relationsPath) {
      return jsonResponse({'chunk': relations});
    }
    if (request.method == 'PUT') return jsonResponse({});
    return jsonResponse({'errcode': 'M_NOT_FOUND', 'error': 'none'}, 404);
  }
}

class _Client extends matrix.Client {
  _Client(http.Client transport)
    : super(
        'theme-test',
        database: ScheduledDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  final uploads = <Uint8List>[];

  @override
  String? get userID => _me;
  @override
  String? get deviceID => 'DEVICE';

  @override
  Future<Uri> uploadContent(
    Uint8List file, {
    String? filename,
    String? contentType,
  }) async {
    uploads.add(file);
    return Uri.parse('mxc://matrix.example/up${uploads.length}');
  }

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Sent {
  _Sent(this.roomId, this.type, this.content);
  final String roomId;
  final String type;
  final Map<String, Object?> content;
}

class _Backend implements MatrixSdkAccess, RoomEventFeatures {
  _Backend(this.client);
  final matrix.Client client;
  final sent = <_Sent>[];
  Object? sendError;

  @override
  matrix.Client? get sdkClient => client;
  @override
  bool isSessionCurrent(matrix.Client client) => identical(client, this.client);

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    if (sendError != null) throw sendError!;
    sent.add(
      _Sent(
        roomId,
        type,
        jsonDecode(jsonEncode(content)) as Map<String, Object?>,
      ),
    );
    return '\$sent${sent.length}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Server server;
  late _Client client;
  late _Backend backend;
  late matrix.Room room;
  late ChatThemeStore store;
  late Directory root;
  var clock = 5000;
  final plaintext = <String, Uint8List>{};

  ChatThemeSync themes() => ChatThemeSync(
    backend,
    store: store,
    now: () => clock,
    prepareImage: (_) async => null,
    encrypt: (bytes) async {
      final k = 'key${plaintext.length}';
      plaintext[k] = bytes;
      return matrix.EncryptedFile(
        data: Uint8List.fromList(utf8.encode(k)),
        k: k,
        iv: 'iv',
        sha256: 'hash-$k',
      );
    },
    download: (client, mxc, maxBytes) async =>
        Uint8List.fromList(utf8.encode('cipher')),
    decrypt: (file) async =>
        file.sha256 == 'hash-${file.k}' ? plaintext[file.k] : null,
  );

  Map<String, Object?> themeEvent({
    required String id,
    required int ts,
    String sender = _them,
    Map<String, Object?> content = const {},
  }) => {
    'type': chatThemeEventType,
    'event_id': id,
    'sender': sender,
    'origin_server_ts': ts,
    'room_id': _roomId,
    'content': {
      'version': 1,
      'm.relates_to': {'rel_type': chatThemeEventType, 'event_id': _createId},
      ...content,
    },
  };

  Map<String, Object?> pictureFile(String k) => {
    'file': {
      'url': 'mxc://matrix.example/$k',
      'key': {'k': k},
      'iv': 'iv',
      'hashes': {'sha256': 'hash-$k'},
      'v': 'v2',
    },
  };

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final parent = Directory('build/chat_theme_tests');
    await parent.create(recursive: true);
    root = await parent.createTemp('case-');
    store = ChatThemeStore(
      preferences: prefs,
      pictures: RoomBackgroundStore(root: root, folder: 'themes'),
    );
    server = _Server();
    client = _Client(RecordingTransport(server.respond));
    backend = _Backend(client);
    room = matrix.Room(
      id: _roomId,
      client: client,
      membership: matrix.Membership.join,
    );
    room.setState(
      matrix.Event.fromJson({
        'type': matrix.EventTypes.RoomCreate,
        'state_key': '',
        'event_id': _createId,
        'sender': _me,
        'origin_server_ts': 1,
        'content': {},
      }, room),
    );
    client.rooms.add(room);
    clock = 5000;
    plaintext.clear();
  });
  tearDown(() async => root.delete(recursive: true));

  test('shared colours keep only readable text colours', () {
    final colours = sharedColours(
      const BubbleColours(
        mine: Color(0xFF000000),
        mineText: Color(0xFF111111),
        theirs: Color(0xFFFFFFFF),
        theirsText: Color(0xFF000000),
      ),
    );
    expect(colours.mineText, isNull, reason: 'black on black dropped');
    expect(colours.theirsText, const Color(0xFF000000));
    expect(
      sharedColours(const BubbleColours(mineText: Color(0xFF123456))).mineText,
      isNull,
      reason: 'a text colour needs its bubble colour',
    );
  });

  test('the newest theme wins, whatever order they arrive in', () async {
    final newer = ChatTheme.fromContent(
      eventId: r'$b',
      time: 20,
      sender: _them,
      content: {
        'bubbleColours': {'mine': '#00AA00'},
      },
    )!;
    final older = ChatTheme.fromContent(
      eventId: r'$a',
      time: 10,
      sender: _them,
      content: {
        'bubbleColours': {'mine': '#AA0000'},
      },
    )!;
    expect(await store.offer(_roomId, newer), isTrue);
    expect(await store.offer(_roomId, older), isFalse);
    expect(store.cached(_roomId)!.colours.mine, const Color(0xFF00AA00));

    store.clearMemory();
    expect((await store.load(_roomId))!.eventId, r'$b', reason: 'persisted');
  });

  test(
    'a theme arriving through sync is taken and its picture fetched',
    () async {
      final sync = themes()..attach();
      plaintext['remote'] = _jpeg;
      client.onTimelineEvent.add(
        matrix.Event.fromJson(
          themeEvent(
            id: r'$t1',
            ts: 100,
            content: {
              'change': 'theme',
              'bubbleColours': {'mine': '#112233', 'theirs': '#445566'},
              'background': pictureFile('remote'),
            },
          ),
          room,
        ),
      );
      await settle();

      final theme = store.cached(_roomId)!;
      expect(theme.sender, _them);
      expect(theme.colours.theirs, const Color(0xFF445566));
      final picture = await store.pictureFile(_roomId);
      expect(await picture!.readAsBytes(), _jpeg);
      await sync.detach();
    },
  );

  test(
    'a device that missed it finds the newest theme on the server',
    () async {
      server.relations = [
        themeEvent(
          id: r'$t2',
          ts: 200,
          content: {
            'change': 'colours',
            'bubbleColours': {'mine': '#0000CC'},
          },
        ),
        themeEvent(
          id: r'$t1',
          ts: 100,
          content: {
            'bubbleColours': {'mine': '#CC0000'},
          },
        ),
      ];

      final sync = themes();
      await sync.refresh(_roomId);

      expect(store.cached(_roomId)!.eventId, r'$t2');
      expect(store.cached(_roomId)!.colours.mine, const Color(0xFF0000CC));
      final lookup = server.requests.singleWhere(
        (r) => r.url.path == _relationsPath,
      );
      expect(lookup.url.queryParameters['dir'], 'b');

      // Once a session per room.
      await sync.refresh(_roomId);
      expect(
        server.requests.where((r) => r.url.path == _relationsPath),
        hasLength(1),
      );
    },
  );

  test(
    'sharing colours keeps the chat background and relates to the room',
    () async {
      await store.offer(
        _roomId,
        ChatTheme.fromContent(
          eventId: r'$old',
          time: 10,
          sender: _them,
          content: {'background': pictureFile('kept')},
        )!,
      );

      await themes().share(
        _roomId,
        colours: const BubbleColours(mine: Color(0xFF00AA00)),
      );

      final sent = backend.sent.single;
      expect(sent.type, chatThemeEventType);
      expect(sent.content['change'], 'colours');
      expect(sent.content['bubbleColours'], {'mine': '#00AA00'});
      expect(
        (sent.content['background']! as Map)['file'],
        pictureFile('kept')['file'],
      );
      expect(sent.content['m.relates_to'], {
        'rel_type': chatThemeEventType,
        'event_id': _createId,
      });
      final theme = store.cached(_roomId)!;
      expect(theme.eventId, r'$sent1');
      expect(theme.sender, _me);
    },
  );

  test(
    'sharing a background uploads it encrypted and shows it at once',
    () async {
      await themes().share(_roomId, background: _jpeg);

      expect(client.uploads.single, utf8.encode('key0'));
      final content = backend.sent.single.content;
      expect(content['change'], 'background');
      final file = (content['background']! as Map)['file']! as Map;
      expect(file['url'], 'mxc://matrix.example/up1');
      expect((file['key']! as Map)['k'], 'key0');
      expect(
        await (await store.pictureFile(_roomId))!.readAsBytes(),
        _jpeg,
        reason: 'no download needed on the sending device',
      );
    },
  );

  test('removing the theme sends a reset', () async {
    await themes().share(_roomId, background: _jpeg);
    await themes().share(_roomId, reset: true);
    final content = backend.sent.last.content;
    expect(content['change'], 'reset');
    expect(content['bubbleColours'], isEmpty);
    expect(content.containsKey('background'), isFalse);
    expect(store.cached(_roomId)!.isEmpty, isTrue);
    expect(await store.pictureFile(_roomId), isNull);
  });

  test('a failed send changes nothing here', () async {
    backend.sendError = StateError('M_FORBIDDEN');
    await expectLater(
      themes().share(
        _roomId,
        colours: const BubbleColours(mine: Color(0xFF00AA00)),
      ),
      throwsStateError,
    );
    expect(store.cached(_roomId), isNull);
  });

  test('installs the push rule that keeps theme changes quiet', () async {
    await themes().ensurePushRule();
    final put = server.requests.singleWhere(
      (r) =>
          r.method == 'PUT' &&
          r.url.path ==
              '/_matrix/client/v3/pushrules/global/override/'
                  'net.samrusselltech.parallax.chat_theme',
    );
    final body = jsonDecode(put.body) as Map;
    expect(body['actions'], isEmpty);
    expect(body['conditions'], [
      {
        'kind': 'event_match',
        'key': r'content.m\.relates_to.rel_type',
        'pattern': chatThemeEventType,
      },
    ]);
  });

  test('theme changes never notify', () {
    expect(silentPushEventTypes, contains(chatThemeEventType));
  });

  test('room version 12 create event IDs come from the room ID', () {
    final v12 = matrix.Room(id: '!abcDEF', client: client);
    expect(createEventId(v12), r'$abcDEF');
    expect(createEventId(room), _createId);
  });

  group('timeline notice', () {
    ChatEntry entry(String change, {String sender = _them}) => ChatEntry(
      id: r'$e',
      sender: sender,
      senderName: 'Alex',
      body: '',
      time: DateTime(2026),
      mine: sender == _me,
      eventType: chatThemeEventType,
      content: {'change': change},
    );

    test('says who changed what', () {
      expect(
        entryKindFor(
          type: chatThemeEventType,
          msgtype: null,
          content: const {},
          redacted: false,
        ),
        EntryKind.state,
      );
      expect(isTimelineVisibleType(chatThemeEventType), isTrue);
      expect(
        describeStateEvent(entry('colours'), ownUserId: _me),
        'Alex changed the chat colours',
      );
      expect(
        describeStateEvent(entry('background'), ownUserId: _me),
        'Alex changed the chat background',
      );
      expect(
        describeStateEvent(entry('theme'), ownUserId: _me),
        'Alex changed the chat theme',
      );
      expect(
        describeStateEvent(entry('reset'), ownUserId: _me),
        'Alex removed the chat theme',
      );
      expect(
        describeStateEvent(entry('colours', sender: _me), ownUserId: _me),
        'You changed the chat colours',
      );
    });
  });
}
