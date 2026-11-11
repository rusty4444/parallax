import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/matrix_send_guard.dart';
import 'package:parallax/reaction_summary.dart';

const _roomId = '!room:matrix.example';

void main() {
  group('reactionEventContent', () {
    test('plain rooms send the bare annotation', () {
      final content = reactionEventContent(r'$target', '👍', encrypted: false);
      expect(content, {
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': r'$target',
          'key': '👍',
        },
      });
    });

    test('encrypted rooms keep a non-relation payload for the SDK to encrypt '
        'while the relation stays intact for the cleartext envelope', () {
      final content = Map<String, Object?>.of(
        reactionEventContent(r'$target', '🎉', encrypted: true),
      );
      final relation = content.remove('m.relates_to');
      expect(relation, {
        'rel_type': 'm.annotation',
        'event_id': r'$target',
        'key': '🎉',
      });
      // Mirrors encryptGroupMessagePayload: a payload that is empty once the
      // relation is removed is sent unencrypted.
      expect(content, isNotEmpty);
      expect(content.keys, [encryptedReactionMarker]);
    });
  });

  test('SDK 14.1 sends relation-only payloads unencrypted, which is why '
      'encrypted rooms add the marker', () async {
    final client = _Client([]);
    client.rooms.add(_room(client, encrypted: true));
    final crypto = encryption.Encryption(client: client);
    final relation = {
      'rel_type': 'm.annotation',
      'event_id': r'$target',
      'key': '👍',
    };
    final bare = await crypto.encryptGroupMessagePayload(_roomId, {
      'm.relates_to': relation,
    }, type: matrix.EventTypes.Reaction);
    expect(bare, {'m.relates_to': relation});
    expect(bare.containsKey('ciphertext'), isFalse);
  });

  group('send guard and encrypted reactions', () {
    Uri send(String type) => Uri.parse(
      'https://matrix.example/_matrix/client/v3/rooms/'
      '${Uri.encodeComponent(_roomId)}/send/$type/txn',
    );

    test(
      'a relation-only plaintext m.reaction cannot leave an encrypted room',
      () async {
        final inner = _Recorder();
        final guard = MatrixSendGuard(
          inner,
          encryptionAvailable: () => true,
          isEncryptedRoom: (id) => id == _roomId,
        );
        await expectLater(
          guard.send(http.Request('PUT', send('m.reaction'))),
          throwsStateError,
        );
        expect(inner.requests, isEmpty);
      },
    );

    test('an encrypted reaction passes the protected send zone', () async {
      final inner = _Recorder();
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (id) => id == _roomId,
      );
      var checked = 0;
      await guard.protect(
        _roomId,
        () => guard.send(
          http.Request('PUT', send('m.room.encrypted'))
            ..body = jsonEncode({
              'algorithm': 'm.megolm.v1.aes-sha2',
              'ciphertext': 'opaque',
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': r'$target',
                'key': '👍',
              },
            }),
        ),
        ownerCurrent: () => true,
        validateRecipients: () async => checked++,
      );
      expect(checked, 1);
      expect(
        inner.requests.single.url.pathSegments,
        contains('m.room.encrypted'),
      );
    });

    test('crypto loss still blocks the encrypted reaction', () async {
      final inner = _Recorder();
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => false,
        isEncryptedRoom: (id) => id == _roomId,
      );
      await expectLater(
        guard.protect(
          _roomId,
          () => guard.send(http.Request('PUT', send('m.room.encrypted'))),
          ownerCurrent: () => true,
          validateRecipients: () async {},
        ),
        throwsStateError,
      );
      expect(inner.requests, isEmpty);
    });
  });

  group('typing', () {
    test('encrypted rooms send only the typing EDU, no key sharing', () async {
      final requests = <http.Request>[];
      final client = _Client(requests);
      client.rooms.add(_room(client, encrypted: true));
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);

      await backend.setTyping(_roomId, true);
      await backend.setTyping(_roomId, false);

      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'PUT');
        expect(
          Uri.decodeFull(request.url.path),
          '/_matrix/client/v3/rooms/$_roomId/typing/@sam:matrix.example',
        );
      }
      expect(jsonDecode(requests.first.body), {
        'typing': true,
        'timeout': 5000,
      });
      expect(jsonDecode(requests.last.body), {'typing': false});
      expect(
        requests.where(
          (r) =>
              r.url.path.contains('sendToDevice') ||
              r.url.path.contains('/keys/'),
        ),
        isEmpty,
      );
    });

    test('plain rooms keep the SDK typing call', () async {
      final requests = <http.Request>[];
      final client = _Client(requests);
      client.rooms.add(_room(client, encrypted: false));
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);

      await backend.setTyping(_roomId, true);

      expect(requests.single.url.path, contains('/typing/'));
      expect(jsonDecode(requests.single.body)['typing'], isTrue);
    });

    test('rooms not joined send nothing', () async {
      final requests = <http.Request>[];
      final client = _Client(requests);
      client.rooms.add(
        _room(client, encrypted: true, membership: matrix.Membership.invite),
      );
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);

      await backend.setTyping(_roomId, true);

      expect(requests, isEmpty);
    });
  });
}

matrix.Room _room(
  matrix.Client client, {
  required bool encrypted,
  matrix.Membership membership = matrix.Membership.join,
}) {
  final room = matrix.Room(id: _roomId, client: client, membership: membership);
  if (encrypted) {
    room.setState(
      matrix.Event.fromJson({
        'type': matrix.EventTypes.Encryption,
        'state_key': '',
        'sender': '@sam:matrix.example',
        'event_id': r'$encryption',
        'origin_server_ts': 1000,
        'content': {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
      }, room),
    );
  }
  return room;
}

class _Recorder extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

class _Database extends Fake implements matrix.DatabaseApi {}

class _Client extends matrix.Client {
  _Client(List<http.Request> requests)
    : super(
        'reactions-test',
        database: _Database(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  @override
  String? get userID => '@sam:matrix.example';

  @override
  String? get deviceID => 'DEVICE';

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}
