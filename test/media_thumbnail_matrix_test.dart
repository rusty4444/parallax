import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/matrix_thumbnail_sync.dart';
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/features/media/thumbnail_sync.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/media_disk_cache.dart';
import 'package:parallax/room_events.dart';

import 'widget_test.dart' show FakeBackend;

const _roomId = '!r:example.org';

/// Stored timeline for one room (newest first), as JSON so each client
/// builds its own events.
final _stored = <Map<String, Object?>>[
  _image(r'$photo', {
    'url': 'mxc://example.org/full',
    'info': {
      'size': 5 * 1024 * 1024,
      'thumbnail_url': 'mxc://example.org/thumb',
      'thumbnail_info': {'size': 3},
    },
  }),
  _image(r'$small', {
    'url': 'mxc://example.org/small',
    'info': {'size': 3},
  }),
  // Too big to keep without a thumbnail.
  _image(r'$huge', {
    'url': 'mxc://example.org/huge',
    'info': {'size': 10 * 1024 * 1024},
  }),
  {
    'type': 'm.room.message',
    'event_id': r'$video',
    'sender': '@alice:example.org',
    'origin_server_ts': 3,
    'content': {
      'msgtype': 'm.video',
      'body': 'clip.mp4',
      'url': 'mxc://example.org/video',
      'info': {'thumbnail_url': 'mxc://example.org/vthumb'},
    },
  },
  {
    'type': 'm.sticker',
    'event_id': r'$sticker',
    'sender': '@alice:example.org',
    'origin_server_ts': 2,
    'content': {
      'body': 'wave',
      'url': 'mxc://example.org/sticker',
      'info': {'size': 3},
    },
  },
  {
    'type': 'm.room.message',
    'event_id': r'$text',
    'sender': '@alice:example.org',
    'origin_server_ts': 1,
    'content': {'msgtype': 'm.text', 'body': 'hello'},
  },
];

Map<String, Object?> _image(String id, Map<String, Object?> media) => {
  'type': 'm.room.message',
  'event_id': id,
  'sender': '@alice:example.org',
  'origin_server_ts': 5,
  'content': {'msgtype': 'm.image', 'body': 'photo.jpg', ...media},
};

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  int get maxFileSize => 0;

  @override
  Future<void> close() async {}

  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => [
    for (final json in _stored.take(limit ?? _stored.length))
      matrix.Event.fromJson(json, room),
  ];

  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async {
    for (final json in _stored) {
      if (json['event_id'] == eventId) return matrix.Event.fromJson(json, room);
    }
    return null;
  }

  @override
  Future<({Map<String, Object?> content, DateTime savedAt})?>
  getCustomCacheObject(String cacheKey) async => null;

  @override
  Future<void> cacheCustomObject(
    String cacheKey,
    Map<String, Object?> object,
  ) async {}
}

/// The room list as the inbox shows it, over a real [MatrixBackend].
class _Inbox extends FakeBackend implements MatrixSdkAccess, MediaCacheAccess {
  _Inbox(this.matrixBackend);
  final MatrixBackend matrixBackend;

  @override
  matrix.Client? get sdkClient => matrixBackend.sdkClient;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      matrixBackend.isSessionCurrent(client);

  @override
  Future<ThumbnailStore?> thumbnailStore() => matrixBackend.thumbnailStore();

  @override
  Future<Uint8List?> loadAvatar(Uri url) => matrixBackend.loadAvatar(url);
}

void main() {
  late Directory root;
  final downloads = <String>[];
  var offline = false;

  setUp(() {
    final base = Directory('build/test_media_thumbnail_matrix')
      ..createSync(recursive: true);
    root = base.createTempSync('run');
    downloads.clear();
    offline = false;
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  (matrix.Client, MatrixBackend) session() {
    final client = matrix.Client(
      'thumbnail-sync-test',
      database: _Database(),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.contains('/versions')) {
          return http.Response(
            '{"versions":["v1.11"]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.contains('/media/')) {
          if (offline) return http.Response('offline', 503);
          downloads.add(path);
          // Each media ID serves its own name as bytes.
          return http.Response.bytes(
            request.url.pathSegments.last.codeUnits.take(3).toList(),
            200,
            headers: {'content-type': 'image/jpeg'},
          );
        }
        return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
      }),
    )..homeserver = Uri.parse('https://matrix.example');
    client.accessToken = 'token';
    final room = matrix.Room(id: _roomId, client: client);
    room.setState(
      matrix.Event(
        type: matrix.EventTypes.RoomMember,
        stateKey: '@alice:example.org',
        senderId: '@alice:example.org',
        content: {
          'membership': 'join',
          'avatar_url': 'mxc://example.org/alice',
        },
        room: room,
        eventId: r'$member',
        originServerTs: DateTime(2026),
      ),
    );
    client.rooms.add(room);
    final backend = MatrixBackend.withClient(
      client,
      openMediaCache: (account) => MediaDiskCache.open(account, root: root),
    );
    return (client, backend);
  }

  test('a sync saves what chats show; a restart reads it offline', () async {
    final (_, first) = session();
    addTearDown(first.dispose);
    final inbox = _Inbox(first)
      ..roomList = [
        ChatRoom(
          id: _roomId,
          name: 'Weekend crew',
          preview: '',
          lastActivity: null,
          avatarUrl: Uri.parse('mxc://example.org/roomavatar'),
          heroes: [
            ChatAvatar(name: 'Bo', url: Uri.parse('mxc://example.org/hero')),
          ],
        ),
        // Invitations are skipped.
        ChatRoom(
          id: '!invite:example.org',
          name: 'Stranger',
          preview: '',
          lastActivity: null,
          invited: true,
          avatarUrl: Uri.parse('mxc://example.org/stranger'),
        ),
      ];
    final sync = ThumbnailSync(MatrixThumbnailSyncSource(inbox));
    addTearDown(sync.dispose);

    await sync.start();

    final state = sync.state;
    expect(state.error, isNull);
    expect(state.finished, isTrue);
    expect(state.roomsTotal, 1);
    // Room picture, hero, sender, photo thumbnail, small original, video
    // thumbnail, sticker.
    expect(state.saved, 7, reason: '$downloads');
    expect(state.failed, 0);
    expect(downloads.where((p) => p.contains('stranger')), isEmpty);
    expect(downloads.where((p) => p.contains('/full')), isEmpty);
    expect(downloads.where((p) => p.contains('/huge')), isEmpty);
    expect(downloads.where((p) => p.endsWith('/video')), isEmpty);

    // A second pass finds everything saved.
    downloads.clear();
    await sync.start();
    expect(sync.state.saved, 0);
    expect(sync.state.alreadySaved, 7);
    expect(downloads, isEmpty);

    // "Restart": a new client and backend, no network.
    offline = true;
    final (_, second) = session();
    addTearDown(second.dispose);
    final media = mediaFeaturesOf(second)!;
    expect(await media.loadPreview(_roomId, r'$photo'), 'thu'.codeUnits);
    expect(await media.loadPreview(_roomId, r'$video'), 'vth'.codeUnits);
    expect(await media.loadPreview(_roomId, r'$sticker'), 'sti'.codeUnits);
    expect(
      await second.loadAvatar(Uri.parse('mxc://example.org/roomavatar')),
      'roo'.codeUnits,
    );
    expect(
      await second.loadAvatar(Uri.parse('mxc://example.org/alice')),
      'ali'.codeUnits,
    );
    expect(downloads, isEmpty);
  });

  test('previews seen in the app are saved for the next launch', () async {
    final (_, first) = session();
    addTearDown(first.dispose);
    expect(
      await mediaFeaturesOf(first)!.loadPreview(_roomId, r'$photo'),
      'thu'.codeUnits,
    );
    expect(
      await first.loadAvatar(Uri.parse('mxc://example.org/hero')),
      'her'.codeUnits,
    );
    // Saving runs in the background.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    offline = true;
    final (_, second) = session();
    addTearDown(second.dispose);
    expect(
      await mediaFeaturesOf(second)!.loadPreview(_roomId, r'$photo'),
      'thu'.codeUnits,
    );
    expect(
      await second.loadAvatar(Uri.parse('mxc://example.org/hero')),
      'her'.codeUnits,
    );
  });

  test('preview selection follows the timeline', () {
    final client = matrix.Client('preview-test', database: _Database());
    final room = matrix.Room(id: _roomId, client: client);
    Uri? pick(Map<String, Object?> json) =>
        previewMxcFor(matrix.Event.fromJson(json, room));
    expect(pick(_stored[0]).toString(), 'mxc://example.org/thumb');
    expect(pick(_stored[1]).toString(), 'mxc://example.org/small');
    expect(pick(_stored[2]), isNull);
    expect(pick(_stored[3]).toString(), 'mxc://example.org/vthumb');
    expect(pick(_stored[4]).toString(), 'mxc://example.org/sticker');
    expect(pick(_stored[5]), isNull);
    // A video without a thumbnail has nothing to show.
    expect(
      pick({
        'type': 'm.room.message',
        'event_id': r'$v2',
        'sender': '@a:example.org',
        'origin_server_ts': 1,
        'content': {
          'msgtype': 'm.video',
          'body': 'v',
          'url': 'mxc://example.org/v2',
        },
      }),
      isNull,
    );
  });
}
