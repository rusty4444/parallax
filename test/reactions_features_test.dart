import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/forward_content.dart';
import 'package:parallax/features/reactions/matrix_message_actions.dart';
import 'package:parallax/features/reactions/message_action_features.dart';
import 'package:parallax/features/reactions/message_previews.dart';
import 'package:parallax/room_events.dart';

const _roomId = '!room:matrix.example';
const _me = '@sam:matrix.example';

void main() {
  group('forwardPayloadFor', () {
    ChatEntry entry({
      String id = r'$event',
      String type = 'm.room.message',
      Map<String, Object?> content = const {'msgtype': 'm.text', 'body': 'hi'},
      String body = 'hi',
      String? replyToId,
      bool redacted = false,
      EntryKind? kind,
    }) => ChatEntry(
      id: id,
      sender: '@alice:matrix.example',
      body: body,
      time: DateTime(2026),
      mine: false,
      eventType: type,
      content: content,
      replyToId: replyToId,
      redacted: redacted,
      kind: kind,
    );

    test('text drops relations, mentions and the reply fallback', () {
      final payload = forwardPayloadFor(
        entry(
          replyToId: r'$parent',
          body: 'my answer',
          content: {
            'msgtype': 'm.text',
            'body': '> <@bob:matrix.example> question\n\nmy answer',
            'format': 'org.matrix.custom.html',
            'formatted_body':
                '<mx-reply><blockquote>question</blockquote></mx-reply>'
                '<b>my answer</b>',
            'm.relates_to': {
              'm.in_reply_to': {'event_id': r'$parent'},
            },
            'm.mentions': {
              'user_ids': ['@bob:matrix.example'],
            },
          },
        ),
      )!;
      expect(payload.type, 'm.room.message');
      expect(payload.content, {
        'msgtype': 'm.text',
        'body': 'my answer',
        'format': 'org.matrix.custom.html',
        'formatted_body': '<b>my answer</b>',
      });
    });

    test('encrypted media is re-sent with the same file info', () {
      final file = {
        'url': 'mxc://matrix.example/abc',
        'key': {'k': 'secret', 'alg': 'A256CTR'},
        'iv': 'iv',
        'hashes': {'sha256': 'hash'},
        'v': 'v2',
      };
      final payload = forwardPayloadFor(
        entry(
          content: {
            'msgtype': 'm.image',
            'body': 'photo.jpg',
            'file': file,
            'info': {'mimetype': 'image/jpeg', 'w': 10, 'h': 10},
          },
          kind: EntryKind.image,
        ),
      )!;
      expect(payload.content['file'], file);
      expect(payload.content['msgtype'], 'm.image');
    });

    test('rejects what Element X cannot forward', () {
      expect(forwardPayloadFor(entry(id: 'local-txn')), isNull);
      expect(forwardPayloadFor(entry(redacted: true)), isNull);
      expect(
        forwardPayloadFor(
          entry(type: 'm.poll.start', content: {'body': 'poll'}),
        ),
        isNull,
      );
      expect(
        forwardPayloadFor(
          entry(type: 'm.room.encrypted', content: const {'body': 'x'}),
        ),
        isNull,
      );
      expect(
        forwardPayloadFor(entry(content: {'msgtype': 'm.image', 'body': 'x'})),
        isNull,
        reason: 'media without a source',
      );
      expect(
        forwardPayloadFor(
          entry(content: {'msgtype': 'm.location', 'body': 'here'}),
        ),
        isNull,
      );
      expect(
        forwardPayloadFor(
          entry(content: {'msgtype': 'm.text', 'body': 'x' * 70000}),
        ),
        isNull,
        reason: 'oversized content',
      );
    });

    test('stickers keep their type', () {
      final payload = forwardPayloadFor(
        entry(
          type: 'm.sticker',
          content: {'body': 'cat', 'url': 'mxc://matrix.example/cat'},
          kind: EntryKind.sticker,
        ),
      )!;
      expect(payload.type, 'm.sticker');
    });
  });

  test('preview text labels media and trims long bodies', () {
    ChatEntry make(EntryKind kind, String body) => ChatEntry(
      id: r'$e',
      sender: '@a:x',
      body: body,
      time: DateTime(2026),
      mine: false,
      kind: kind,
    );
    expect(messagePreviewText(make(EntryKind.image, 'a.jpg')), 'Image');
    expect(messagePreviewText(make(EntryKind.file, 'a.pdf')), 'File: a.pdf');
    expect(messagePreviewText(make(EntryKind.text, 'one\n two')), 'one two');
    expect(
      messagePreviewText(make(EntryKind.text, '😀' * 300)).runes.length,
      201,
    );
  });

  test('pinnedIdsFrom ignores malformed and duplicate entries', () {
    expect(pinnedIdsFrom([r'$a', 'bad', 3, r'$a', r'$b']), [r'$a', r'$b']);
    expect(pinnedIdsFrom('nope'), isEmpty);
  });

  group('MatrixMessageActions', () {
    late _Harness h;
    setUp(() => h = _Harness());

    test('resolver caches one implementation per backend', () {
      final first = messageActionFeaturesOf(h.backend);
      expect(first, isA<MatrixMessageActions>());
      expect(identical(first, messageActionFeaturesOf(h.backend)), isTrue);
    });

    test('pin re-reads server state and preserves other pins', () async {
      h.state = {
        'pinned': [r'$a', r'$a', 'junk'],
        'other': 1,
      };
      await h.features.setPinned(_roomId, r'$b', pinned: true);
      expect(h.writes.single, {
        'pinned': [r'$a', r'$b'],
        'other': 1,
      });
      await h.features.setPinned(_roomId, r'$a', pinned: false);
      expect(h.writes.last['pinned'], [r'$b']);
      // Unpinning something already gone does not write.
      await h.features.setPinned(_roomId, r'$zzz', pinned: false);
      expect(h.writes, hasLength(2));
    });

    test('concurrent pins are serialised so neither is lost', () async {
      h.state = {'pinned': <String>[]};
      h.readGate = Completer<void>();
      final first = h.features.setPinned(_roomId, r'$a', pinned: true);
      final second = h.features.setPinned(_roomId, r'$b', pinned: true);
      await Future<void>.delayed(Duration.zero);
      expect(h.reads, 1, reason: 'second write waits for the first');
      h.readGate!.complete();
      await Future.wait([first, second]);
      expect(h.state['pinned'], [r'$a', r'$b']);
    });

    test('no pin permission fails before any read or write', () async {
      h.room.setState(
        matrix.Event.fromJson({
          'type': matrix.EventTypes.RoomPowerLevels,
          'state_key': '',
          'sender': '@admin:matrix.example',
          'event_id': r'$pl',
          'origin_server_ts': 1,
          'content': {
            'state_default': 50,
            'users': {'@admin:matrix.example': 100},
          },
        }, h.room),
      );
      expect(h.features.permissions(_roomId).canPin, isFalse);
      expect(h.features.permissions(_roomId).canRedactOthers, isFalse);
      await expectLater(
        h.features.setPinned(_roomId, r'$a', pinned: true),
        throwsStateError,
      );
      expect(h.reads, 0);
      expect(h.writes, isEmpty);
    });

    test('a session change during the read prevents the write', () async {
      h.state = {'pinned': <String>[]};
      h.readGate = Completer<void>();
      final pinning = h.features.setPinned(_roomId, r'$a', pinned: true);
      await Future<void>.delayed(Duration.zero);
      h.backend.current = false;
      h.readGate!.complete();
      await expectLater(pinning, throwsStateError);
      expect(h.writes, isEmpty);
    });

    test('reaction senders page through relations, plaintext and '
        'encrypted alike, with cached names', () async {
      h.room.setState(
        matrix.Event.fromJson({
          'type': matrix.EventTypes.RoomMember,
          'state_key': '@alice:matrix.example',
          'sender': '@alice:matrix.example',
          'event_id': r'$m',
          'origin_server_ts': 1,
          'content': {
            'membership': 'join',
            'displayname': 'Alice',
            'avatar_url': 'mxc://matrix.example/alicePhoto',
          },
        }, h.room),
      );
      Map<String, Object?> reaction(
        String id,
        String sender,
        String key, {
        String type = 'm.reaction',
        String target = r'$target',
      }) => {
        'type': type,
        'event_id': id,
        'sender': sender,
        'room_id': _roomId,
        'origin_server_ts': 1000 + id.length,
        'content': {
          if (type == 'm.room.encrypted') 'ciphertext': 'opaque',
          'm.relates_to': {
            'rel_type': 'm.annotation',
            'event_id': target,
            'key': key,
          },
        },
      };
      h.respond = (request) async {
        expect(
          Uri.decodeFull(request.url.path),
          '/_matrix/client/v1/rooms/$_roomId/relations/\$target/m.annotation',
        );
        final from = request.url.queryParameters['from'];
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(
              from == null
                  ? {
                      'chunk': [
                        reaction(r'$1', '@alice:matrix.example', '👍'),
                        reaction(r'$2', '@alice:matrix.example', '👍'),
                        reaction(r'$3', '@bob:matrix.example', '👍'),
                      ],
                      'next_batch': 'page2',
                    }
                  : {
                      'chunk': [
                        reaction(
                          r'$4',
                          '@carol:matrix.example',
                          '🎉',
                          type: 'm.room.encrypted',
                        ),
                        reaction(
                          r'$5',
                          '@dave:matrix.example',
                          '🎉',
                          target: r'$other',
                        ),
                      ],
                    },
            ),
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      };
      final senders = await h.features.reactionSenders(_roomId, r'$target');
      expect(senders.map((s) => '${s.emoji} ${s.label}'), [
        '👍 Alice',
        '👍 @bob:matrix.example',
        '🎉 @carol:matrix.example',
      ]);
      // Photos come from the same cached membership (no extra requests).
      expect(senders.map((s) => s.avatarUrl?.toString()), [
        'mxc://matrix.example/alicePhoto',
        null,
        null,
      ]);
      expect(h.requests, hasLength(2));
    });

    test('report posts the reason to the event report endpoint', () async {
      await h.features.reportContent(_roomId, r'$bad', reason: 'Spam');
      final request = h.requests.single;
      expect(request.method, 'POST');
      expect(
        Uri.decodeFull(request.url.path),
        '/_matrix/client/v3/rooms/$_roomId/report/\$bad',
      );
      expect(jsonDecode(request.body), {'reason': 'Spam'});
    });

    test('ignore merges the server copy of the ignored list', () async {
      h.respond = (request) async {
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'ignored_users': {'@old:matrix.example': {}},
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      };
      await h.features.ignoreUser('@troll:matrix.example');
      final put = h.requests.last;
      expect(put.method, 'PUT');
      expect(
        Uri.decodeFull(put.url.path),
        '/_matrix/client/v3/user/$_me/account_data/m.ignored_user_list',
      );
      expect(jsonDecode(put.body), {
        'ignored_users': {
          '@old:matrix.example': {},
          '@troll:matrix.example': {},
        },
      });
    });

    test('ignore starts a list when none exists and rejects self', () async {
      h.respond = (request) async => request.method == 'GET'
          ? http.Response(
              jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'none'}),
              404,
            )
          : http.Response('{}', 200);
      await h.features.ignoreUser('@troll:matrix.example');
      expect(jsonDecode(h.requests.last.body), {
        'ignored_users': {'@troll:matrix.example': {}},
      });
      expect(() => h.features.ignoreUser(_me), throwsArgumentError);
    });

    test('forward and remove go through RoomEventFeatures', () async {
      await h.features.forwardEvent(_roomId, 'm.room.message', {
        'msgtype': 'm.text',
        'body': 'hi',
      });
      expect(h.sent.single.$1, 'm.room.message');
      expect(h.sent.single.$2, {'msgtype': 'm.text', 'body': 'hi'});
      await h.features.removeEvent(_roomId, r'$x', reason: '  spam ');
      await h.features.removeEvent(_roomId, r'$y', reason: '   ');
      expect(h.redactions, [(r'$x', 'spam'), (r'$y', null)]);
    });

    test('loadEvent fetches once and projects the event', () async {
      h.respond = (request) async => http.Response(
        jsonEncode({
          'type': 'm.room.message',
          'event_id': r'$pin',
          'sender': '@alice:matrix.example',
          'room_id': _roomId,
          'origin_server_ts': 5000,
          'content': {'msgtype': 'm.text', 'body': 'Remember this'},
        }),
        200,
      );
      final entry = await h.features.loadEvent(_roomId, r'$pin');
      expect(entry!.body, 'Remember this');
      expect(entry.kind, EntryKind.text);
      await h.features.loadEvent(_roomId, r'$pin');
      expect(h.requests, hasLength(1));
    });

    test('loadEvent leaves an uncaptioned image body empty', () async {
      h.respond = (request) async => http.Response(
        jsonEncode({
          'type': 'm.room.message',
          'event_id': r'$image',
          'sender': '@whatsapp_lid-123:matrix.example',
          'room_id': _roomId,
          'origin_server_ts': 5000,
          'content': {
            'msgtype': 'm.image',
            'url': 'mxc://matrix.example/forecast',
          },
        }),
        200,
      );

      final entry = await h.features.loadEvent(_roomId, r'$image');

      expect(entry!.kind, EntryKind.image);
      expect(entry.body, isEmpty);
      expect(messagePreviewText(entry), 'Image');
    });
  });
}

class _Harness {
  _Harness() {
    client = _Client((request) {
      requests.add(request);
      return respond(request);
    });
    room = matrix.Room(
      id: _roomId,
      client: client,
      membership: matrix.Membership.join,
    );
    client.rooms.add(room);
    backend = _SdkBackend(this);
  }

  late final _Client client;
  late final matrix.Room room;
  late final _SdkBackend backend;
  MessageActionFeatures get features => messageActionFeaturesOf(backend)!;

  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request) respond = (_) async =>
      http.Response('{}', 200);

  Map<String, Object?> state = {};
  Completer<void>? readGate;
  int reads = 0;
  final writes = <Map<String, Object?>>[];
  final sent = <(String, Map<String, Object?>)>[];
  final redactions = <(String, String?)>[];
}

class _SdkBackend extends ChatBackend
    implements MatrixSdkAccess, RoomEventFeatures {
  _SdkBackend(this.h);
  final _Harness h;
  bool current = true;

  @override
  matrix.Client? get sdkClient => h.client;

  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, h.client);

  @override
  Future<Map<String, Object?>?> roomState(
    String roomId,
    String type, {
    String stateKey = '',
  }) async {
    h.reads++;
    final gate = h.readGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    return jsonDecode(jsonEncode(h.state)) as Map<String, Object?>;
  }

  @override
  Future<void> setRoomState(
    String roomId,
    String type,
    Map<String, Object?> content, {
    String stateKey = '',
  }) async {
    expect(type, 'm.room.pinned_events');
    h.writes.add(content);
    h.state = jsonDecode(jsonEncode(content)) as Map<String, Object?>;
    h.readGate = null;
  }

  @override
  Future<String> sendRoomEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    h.sent.add((type, content));
    return r'$sent';
  }

  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async => h.redactions.add((eventId, reason));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async =>
      null;
}

class _Client extends matrix.Client {
  _Client(Future<http.Response> Function(http.Request) handler)
    : super(
        'reactions-features-test',
        database: _Database(),
        httpClient: MockClient(handler),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
  }

  @override
  String? get userID => _me;
}
