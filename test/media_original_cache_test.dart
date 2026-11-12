import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/matrix_backend.dart';

class _Database extends Fake implements matrix.DatabaseApi {
  final events = <String, matrix.Event>{};

  @override
  int get maxFileSize => 0;

  @override
  Future<void> close() async {}

  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async =>
      events[eventId];

  @override
  Future<({Map<String, Object?> content, DateTime savedAt})?>
  getCustomCacheObject(String cacheKey) async => null;

  @override
  Future<void> cacheCustomObject(
    String cacheKey,
    Map<String, Object?> object,
  ) async {}
}

void main() {
  test('small originals (timeline GIFs) download once, large ones every '
      'time', () async {
    var downloads = 0;
    final gif = Uint8List.fromList(List.filled(2048, 7));
    final database = _Database();
    final client = matrix.Client(
      'media-cache-test',
      database: database,
      httpClient: MockClient((request) async {
        if (request.url.path.contains('/versions')) {
          return http.Response(
            '{"versions":["v1.11"]}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('/media/')) {
          downloads++;
          return http.Response.bytes(
            gif,
            200,
            headers: {'content-type': 'image/gif'},
          );
        }
        return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
      }),
    )..homeserver = Uri.parse('https://matrix.example');
    client.accessToken = 'token';
    final room = matrix.Room(id: '!r:example.org', client: client);
    client.rooms.add(room);
    database.events[r'$gif'] = matrix.Event(
      type: matrix.EventTypes.Message,
      senderId: '@a:example.org',
      content: {
        'msgtype': matrix.MessageTypes.Image,
        'body': 'party.gif',
        'url': 'mxc://example.org/gif',
        'info': {'mimetype': 'image/gif', 'size': gif.length},
      },
      room: room,
      eventId: r'$gif',
      originServerTs: DateTime(2026, 11, 12),
    );
    final backend = MatrixBackend.withClient(client);
    addTearDown(backend.dispose);
    final media = mediaFeaturesOf(backend)!;

    final first = await media.loadOriginal(
      room.id,
      r'$gif',
      maxBytes: 4 * 1024 * 1024,
    );
    final second = await media.loadOriginal(
      room.id,
      r'$gif',
      maxBytes: 4 * 1024 * 1024,
    );
    expect(downloads, 1);
    // The same bytes, so the image cache reuses the decoded frames too.
    expect(identical(first.bytes, second.bytes), isTrue);

    // Downloads (viewer, save) of the full-size original aren't kept.
    await media.loadOriginal(room.id, r'$gif');
    await media.loadOriginal(room.id, r'$gif');
    expect(downloads, 3);
  });
}
