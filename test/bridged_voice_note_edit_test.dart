// Google Messages (mautrix-gmessages) posts a voice note as a placeholder
// and then edits the converted Ogg Opus file in (m.replace, m.new_content,
// com.beeper.dont_render_edited). Playing must fetch the edit's file.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_actions.dart';
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/matrix_backend.dart';

const _roomId = '!room:matrix.example';
const _me = '@sam:matrix.example';
const _ghost = '@gmessages_1:matrix.example';

/// Media the fake homeserver serves, by media ID.
final media = <String, Uint8List>{};

/// What the relations endpoint returns (raw edit events).
var relations = <Map<String, Object?>>[];

final _ogg = Uint8List.fromList('OggS-converted-voice-note'.codeUnits);
final _amr = Uint8List.fromList('#!AMR-raw-recording'.codeUnits);

/// Without [url], the bridge's real placeholder: a notice with no file.
Map<String, Object?> _original({String? url}) => {
  'event_id': r'$voice',
  'type': 'm.room.message',
  'sender': _ghost,
  'origin_server_ts': 9000,
  'room_id': _roomId,
  'content': url == null
      ? {
          'body': 'Waiting for attachment 2948',
          'msgtype': 'm.notice',
          'm.mentions': <String, Object?>{},
          'com.beeper.disappearing_timer': <String, Object?>{},
        }
      : {
          'msgtype': 'm.audio',
          'body': '2948.amr',
          'url': url,
          'info': {'mimetype': 'audio/amr'},
        },
};

/// The bridge's edit, shaped like a live mautrix-gmessages one.
Map<String, Object?> _edit() => {
  'event_id': r'$voice-edit',
  'type': 'm.room.message',
  'sender': _ghost,
  'origin_server_ts': 9500,
  'room_id': _roomId,
  'content': {
    'url': 'mxc://matrix.example/converted',
    'body': '2948.ogg',
    'msgtype': 'm.audio',
    'm.mentions': <String, Object?>{},
    'm.relates_to': {'event_id': r'$voice', 'rel_type': 'm.replace'},
    'm.new_content': {
      'url': 'mxc://matrix.example/converted',
      'body': '2948.ogg',
      'info': {'size': 25, 'mimetype': 'audio/ogg'},
      'msgtype': 'm.audio',
      'm.mentions': <String, Object?>{},
      'org.matrix.msc3245.voice': <String, Object?>{},
    },
    'com.beeper.dont_render_edited': true,
  },
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

  @override
  int get maxFileSize => 0;

  @override
  Future<Uint8List?> getFile(Uri mxcUri) async => null;

  @override
  Future<void> storeFile(Uri mxcUri, Uint8List bytes, int time) async {}

  @override
  Future<void> cacheCustomObject(
    String cacheKey,
    Map<String, Object?> content,
  ) async {}

  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async {
    for (final json in cached) {
      if (json['event_id'] == eventId) return matrix.Event.fromJson(json, room);
    }
    return null;
  }
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
          final path = Uri.decodeComponent(request.url.path);
          if (path.endsWith('/versions')) {
            return http.Response(
              jsonEncode({
                'versions': ['v1.11'],
              }),
              200,
            );
          }
          if (path.contains('/download/')) {
            final id = path.split('/').last;
            final bytes = media[id];
            if (bytes == null) return http.Response('{}', 404);
            return http.Response.bytes(bytes, 200);
          }
          if (path.contains('/relations/')) {
            return http.Response(jsonEncode({'chunk': relations}), 200);
          }
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
  setUp(() {
    media
      ..clear()
      ..['converted'] = _ogg
      ..['raw'] = _amr;
    relations = [];
  });

  for (final (label, url) in [
    ('the "Waiting for attachment" notice', null),
    ('the raw recording', 'mxc://matrix.example/raw'),
  ]) {
    test('plays the edited-in voice note, not $label', () async {
      final h = _Harness(
        cached: [
          _edit(),
          _original(url: url),
        ],
      );
      addTearDown(h.backend.dispose);
      await h.backend.openRoom(_roomId);

      final entry = h.backend.messages.single;
      expect(entry.id, r'$voice');
      expect(entry.kind, EntryKind.voice);
      // The bridge asked for its media fix-up not to read as an edit.
      expect(entry.edited, isFalse);

      final file = await h.backend.loadAttachment(_roomId, r'$voice');
      expect(file.bytes, _ogg);
      expect(file.mimeType, 'audio/ogg');
      expect(file.name, '2948.ogg');
    });
  }

  test('outside the open room, the latest edit is fetched too', () async {
    final h = _Harness(cached: [_original(url: 'mxc://matrix.example/raw')]);
    addTearDown(h.backend.dispose);
    relations = [_edit()];
    final features = mediaFeaturesOf(h.backend)!;
    final file = await features.loadOriginal(_roomId, r'$voice');
    expect(file.bytes, _ogg);
    expect(file.mimeType, 'audio/ogg');
    // And through the loader the inline player uses.
    final viaLoader = await mediaLoaderFor(h.backend, _roomId, r'$voice')();
    expect(viaLoader.bytes, _ogg);
  });

  test('an edit by someone else is ignored', () async {
    final h = _Harness(cached: [_original(url: 'mxc://matrix.example/raw')]);
    addTearDown(h.backend.dispose);
    relations = [
      {..._edit(), 'sender': '@mallory:matrix.example'},
    ];
    final file = await mediaFeaturesOf(
      h.backend,
    )!.loadOriginal(_roomId, r'$voice');
    expect(file.bytes, _amr);
  });

  test('ordinary edits still read as edited', () async {
    final edit = _edit();
    (edit['content'] as Map).remove('com.beeper.dont_render_edited');
    final h = _Harness(cached: [edit, _original()]);
    addTearDown(h.backend.dispose);
    await h.backend.openRoom(_roomId);
    expect(h.backend.messages.single.edited, isTrue);
  });
}
