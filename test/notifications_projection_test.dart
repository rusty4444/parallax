import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/notifications/matrix_push_projection.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_media.dart';

const _me = '@me:example.org';

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async => null;
}

class _Client extends matrix.Client {
  _Client([MockClientHandler? handler])
    : super(
        'notifications-test',
        database: _Database(),
        httpClient: MockClient(
          handler ?? (_) async => http.Response('{}', 500),
        ),
      ) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
  }

  @override
  String? get userID => _me;

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

matrix.Event _state(
  matrix.Room room,
  String type,
  String stateKey,
  Map<String, Object?> content, {
  String sender = '@alice:example.org',
}) => matrix.Event(
  type: type,
  stateKey: stateKey,
  content: content,
  senderId: sender,
  eventId: '\$state-$type-$stateKey',
  originServerTs: DateTime(2026, 11, 12),
  room: room,
);

matrix.Room _groupRoom(matrix.Client client) {
  final room = matrix.Room(id: '!group:example.org', client: client);
  room.setState(_state(room, 'm.room.name', '', {'name': 'Book club'}));
  room.setState(
    _state(room, 'm.room.member', '@alice:example.org', {
      'membership': 'join',
      'displayname': 'Alice',
      'avatar_url': 'mxc://example.org/alice',
    }),
  );
  return room;
}

matrix.Event _message(
  matrix.Room room,
  Map<String, Object?> content, {
  String type = 'm.room.message',
}) => matrix.Event(
  type: type,
  content: content,
  senderId: '@alice:example.org',
  eventId: r'$msg',
  originServerTs: DateTime(2026, 11, 12, 9, 30),
  room: room,
);

Uint8List _png(int width, int height) =>
    img.encodePng(img.Image(width: width, height: height));

void main() {
  late _Client client;
  setUp(() => client = _Client());

  test('names the sender and room and keeps the event identity', () async {
    final room = _groupRoom(client);
    final resolved = await projectPushEvent(
      event: _message(room, {'msgtype': 'm.text', 'body': 'Chapter 3 tonight'}),
      room: room,
      myUserId: _me,
      isDirect: false,
      highlight: true,
    );
    expect(resolved.roomId, '!group:example.org');
    expect(resolved.eventId, r'$msg');
    expect(resolved.roomName, 'Book club');
    expect(resolved.kind, NotifiableEventKind.message);
    expect(resolved.line.senderName, 'Alice');
    expect(resolved.line.senderId, '@alice:example.org');
    expect(resolved.line.text, 'Chapter 3 tonight');
    expect(resolved.line.highlight, isTrue);
    expect(resolved.line.timestamp, DateTime(2026, 11, 12, 9, 30));
    expect(resolved.line.imagePath, isNull);
  });

  test(
    'a sender not loaded yet is named from the server, not their ID',
    () async {
      const ghost = '@whatsapp_lid-100000000000001:example.org';
      final requested = <String>[];
      final client = _Client((request) async {
        requested.add(request.url.path);
        if (request.url.path.endsWith(
          '/state/m.room.member/${Uri.encodeComponent(ghost)}',
        )) {
          return http.Response(
            '{"membership":"join","displayname":"Gen (WA)"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.url.path.contains('/profile/')) {
          return http.Response(
            '{"displayname":"Gen (WA)"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
      });
      final room = _groupRoom(client);
      final event = matrix.Event(
        type: 'm.room.message',
        content: const {'msgtype': 'm.text', 'body': 'Love our little bmfer'},
        senderId: ghost,
        eventId: r'$ghost',
        originServerTs: DateTime(2026, 11, 12, 18, 50),
        room: room,
      );
      final resolved = await projectPushEvent(
        event: event,
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
      );
      expect(resolved.line.senderName, 'Gen (WA)');
      expect(requested, isNotEmpty);
      // Kept for the next notification and the room list.
      expect(
        room.getState('m.room.member', ghost)?.content['displayname'],
        'Gen (WA)',
      );
    },
  );

  test(
    'a stale stored name is replaced by the server\'s current one',
    () async {
      final client = _Client((request) async {
        if (request.url.path.contains('/state/m.room.member/')) {
          return http.Response(
            '{"membership":"join","displayname":"Alice Smith"}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
      });
      // _groupRoom holds the old name, "Alice" (as the database would).
      final room = _groupRoom(client);
      final resolved = await projectPushEvent(
        event: _message(room, {'msgtype': 'm.text', 'body': 'Hi'}),
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
      );
      expect(resolved.line.senderName, 'Alice Smith');
    },
  );

  test('emotes use the display name', () async {
    final room = _groupRoom(client);
    final resolved = await projectPushEvent(
      event: _message(room, {'msgtype': 'm.emote', 'body': 'waves'}),
      room: room,
      myUserId: _me,
      isDirect: true,
      highlight: false,
    );
    expect(resolved.line.text, '* Alice waves');
    expect(resolved.isDirect, isTrue);
  });

  test('still-encrypted and unknown events cannot be described', () async {
    final room = _groupRoom(client);
    await expectLater(
      projectPushEvent(
        event: _message(room, {
          'algorithm': 'm.megolm.v1.aes-sha2',
          'ciphertext': 'x',
        }, type: 'm.room.encrypted'),
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
      ),
      throwsA(isA<UndescribablePushEvent>()),
    );
  });

  test('only DM ring notifications ring', () async {
    final room = _groupRoom(client);
    final event = matrix.Event(
      type: 'm.rtc.notification',
      content: {
        'notification_type': 'ring',
        'sender_ts': DateTime.now().millisecondsSinceEpoch,
        'lifetime': 30000,
      },
      senderId: '@alice:example.org',
      eventId: r'$call',
      originServerTs: DateTime.now(),
      room: room,
    );
    final group = await projectPushEvent(
      event: event,
      room: room,
      myUserId: _me,
      isDirect: false,
      highlight: false,
    );
    expect(group.ringing, isFalse);
    expect(group.line.text, 'Incoming call');
    final direct = await projectPushEvent(
      event: event,
      room: room,
      myUserId: _me,
      isDirect: true,
      highlight: false,
    );
    expect(direct.ringing, isTrue);
    expect(direct.kind, NotifiableEventKind.call);
  });

  test('invites come from the stripped invite state', () async {
    final room = matrix.Room(
      id: '!invite:example.org',
      client: client,
      membership: matrix.Membership.invite,
    );
    room.setState(
      _state(room, 'm.room.name', '', {'name': 'Climbing'}, sender: '@bob:x'),
    );
    room.setState(
      _state(room, 'm.room.member', '@bob:x', {
        'membership': 'join',
        'displayname': 'Bob',
      }, sender: '@bob:x'),
    );
    room.setState(
      _state(room, 'm.room.member', _me, {
        'membership': 'invite',
      }, sender: '@bob:x'),
    );
    final invite = await projectInvite(
      room: room,
      myUserId: _me,
      eventId: r'$invite',
    );
    expect(invite.kind, NotifiableEventKind.invite);
    expect(invite.line.text, 'Bob invited you to Climbing');
    expect(invite.line.senderId, '@bob:x');
  });

  test('push rules decide highlights', () {
    final room = _groupRoom(client);
    final evaluator = matrix.PushruleEvaluator.fromRuleset(
      matrix.PushRuleSet.fromJson({
        'content': [
          {
            'rule_id': 'pizza',
            'default': false,
            'enabled': true,
            'pattern': 'pizza',
            'actions': [
              'notify',
              {'set_tweak': 'highlight'},
            ],
          },
        ],
      }),
    );
    expect(
      pushEventHighlights(
        evaluator,
        _message(room, {'msgtype': 'm.text', 'body': 'pizza tonight?'}),
      ),
      isTrue,
    );
    expect(
      pushEventHighlights(
        evaluator,
        _message(room, {'msgtype': 'm.text', 'body': 'pasta tonight?'}),
      ),
      isFalse,
    );
  });

  group('media', () {
    late Directory cache;
    setUp(() => cache = Directory.systemTemp.createTempSync('parallax_media'));
    tearDown(() {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    test('previews and avatars are fetched with auth, bounded and cached '
        'privately', () async {
      final requests = <http.BaseRequest>[];
      final loader = NotificationMediaLoader(
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(_png(1200, 800), 200);
        }),
        homeserver: Uri.parse('https://matrix.example.org'),
        accessToken: 'token',
        cacheRoot: cache,
        process: (job) async => processNotificationImage(job),
      );
      final room = _groupRoom(client);
      final resolved = await projectPushEvent(
        event: _message(room, {
          'msgtype': 'm.image',
          'body': 'photo.png',
          'url': 'mxc://example.org/photo',
          'info': {'mimetype': 'image/png'},
        }),
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
        media: loader,
      );
      expect(resolved.line.text, 'Image');
      final preview = File(resolved.line.imagePath!);
      expect(preview.existsSync(), isTrue);
      expect(p(preview.path), contains('/notification_media/'));
      final decoded = img.decodeJpg(preview.readAsBytesSync())!;
      expect(decoded.width, notificationPreviewEdge);
      expect(File(resolved.line.senderAvatarPath!).existsSync(), isTrue);
      final thumbnailRequest = requests.firstWhere(
        (r) => r.url.path.contains('/photo'),
      );
      expect(
        thumbnailRequest.url.path,
        '/_matrix/client/v1/media/thumbnail/example.org/photo',
      );
      expect(thumbnailRequest.headers['authorization'], 'Bearer token');
      expect(
        notificationContentUri(preview.path, cache.path),
        startsWith('content://$notificationFileProviderAuthority/'),
      );
      // Avatars are cached by URI: a second lookup makes no request.
      final before = requests.length;
      await loader.avatar(Uri.parse('mxc://example.org/alice'));
      expect(requests.length, before);
    });

    test('previews are skipped when media is off and fail soft', () async {
      var requests = 0;
      final loader = NotificationMediaLoader(
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('nope', 404);
        }),
        homeserver: Uri.parse('https://matrix.example.org'),
        accessToken: 'token',
        cacheRoot: cache,
        process: (job) async => processNotificationImage(job),
      );
      final room = _groupRoom(client);
      final event = _message(room, {
        'msgtype': 'm.image',
        'body': 'photo.png',
        'url': 'mxc://example.org/photo',
      });
      final noMedia = await projectPushEvent(
        event: event,
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
        media: loader,
        loadMediaPreview: false,
      );
      expect(noMedia.line.imagePath, isNull);
      final failed = await projectPushEvent(
        event: event,
        room: room,
        myUserId: _me,
        isDirect: false,
        highlight: false,
        media: loader,
      );
      expect(failed.line.imagePath, isNull);
      expect(failed.line.text, 'Image');
      expect(requests, greaterThan(0));
    });

    test('oversized downloads are refused', () async {
      final loader = NotificationMediaLoader(
        httpClient: MockClient(
          (_) async => http.Response.bytes(
            Uint8List(maxNotificationMediaBytes + 1),
            200,
          ),
        ),
        homeserver: Uri.parse('https://matrix.example.org'),
        accessToken: 'token',
        cacheRoot: cache,
        process: (job) async => processNotificationImage(job),
      );
      expect(
        await loader.preview(
          NotificationMediaRef(
            mxc: Uri.parse('mxc://example.org/big'),
            thumbnail: true,
          ),
          r'$big',
        ),
        isNull,
      );
    });

    test('image processing bounds and sanitises input', () {
      expect(
        processNotificationImage(
          NotificationImageJob(Uint8List.fromList([1, 2, 3]), edge: 640),
        ),
        isNull,
      );
      final avatar = processNotificationImage(
        NotificationImageJob(_png(300, 200), edge: 128, square: true),
      )!;
      final decoded = img.decodePng(avatar)!;
      expect(decoded.width, decoded.height);
      expect(decoded.width, 128);
      final small = processNotificationImage(
        NotificationImageJob(_png(100, 50), edge: 640),
      )!;
      expect(img.decodeJpg(small)!.width, 100);
    });
  });
}

String p(String path) => path.replaceAll(r'\', '/');
