import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/scheduled/delayed_events.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/matrix_send_guard.dart';

import 'scheduled_fakes.dart';

const _content = {'msgtype': 'm.text', 'body': 'Later'};

Map<String, dynamic> _megolm(Map<String, dynamic> payload) => {
  'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2,
  'ciphertext': 'opaque-${payload.length}',
  'device_id': 'DEVICE',
  'sender_key': 'curve',
  'session_id': 'session',
  'm.relates_to': ?payload['m.relates_to'],
};

void main() {
  group('putDelayedRoomEvent request shape', () {
    test('unencrypted: PUT /send with the MSC4140 delay parameter', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'syd_abc'}),
      );
      final client = ScheduledClient(transport);
      final id = await putDelayedRoomEvent(
        client,
        roomId: scheduledRoomId,
        type: 'm.room.message',
        content: _content,
        delay: const Duration(minutes: 30),
        encrypted: false,
        transactionId: 'txn1',
      );
      expect(id, 'syd_abc');
      final request = transport.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.pathSegments, [
        '_matrix',
        'client',
        'v3',
        'rooms',
        scheduledRoomId,
        'send',
        'm.room.message',
        'txn1',
      ]);
      expect(request.url.queryParameters, {delayQueryParameter: '1800000'});
      expect(request.headers['Authorization'], 'Bearer test-token');
      expect(jsonDecode(request.body), _content);
    });

    test('encrypted: only the Megolm payload leaves the device', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'syd_enc'}),
      );
      final client = ScheduledClient(transport);
      Map<String, dynamic>? plaintext;
      final id = await putDelayedRoomEvent(
        client,
        roomId: scheduledRoomId,
        type: 'm.room.message',
        content: {
          ..._content,
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$parent'},
          },
        },
        delay: const Duration(hours: 2),
        encrypted: true,
        encrypt: (payload) async {
          plaintext = payload;
          return _megolm(payload);
        },
        transactionId: 'txn2',
      );
      expect(id, 'syd_enc');
      expect(plaintext!['body'], 'Later');
      final request = transport.requests.single;
      expect(request.url.pathSegments[6], 'm.room.encrypted');
      expect(request.url.queryParameters[delayQueryParameter], '7200000');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['ciphertext'], startsWith('opaque'));
      expect(body.containsKey('body'), isFalse);
      expect(request.body, isNot(contains('Later')));
      // Relations stay cleartext, exactly as for normal encrypted sends.
      expect(body['m.relates_to'], {
        'm.in_reply_to': {'event_id': r'$parent'},
      });
    });

    test('encryption that returns plaintext fails closed', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'x'}),
      );
      final client = ScheduledClient(transport);
      for (final encrypt
          in <Future<Map<String, dynamic>> Function(Map<String, dynamic>)?>[
            null,
            (payload) async => payload,
          ]) {
        await expectLater(
          putDelayedRoomEvent(
            client,
            roomId: scheduledRoomId,
            type: 'm.room.message',
            content: _content,
            delay: const Duration(minutes: 5),
            encrypted: true,
            encrypt: encrypt,
          ),
          throwsA(
            isA<DelayedEventException>().having(
              (e) => e.kind,
              'kind',
              DelayedEventFailure.encryptionUnavailable,
            ),
          ),
        );
      }
      expect(transport.requests, isEmpty);
    });

    test('the final HTTP guard refuses a plaintext delayed send '
        'into an encrypted room', () async {
      final inner = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'x'}),
      );
      final guard = MatrixSendGuard(
        inner,
        encryptionAvailable: () => true,
        isEncryptedRoom: (id) => id == scheduledRoomId,
      );
      final client = ScheduledClient(guard);
      await expectLater(
        putDelayedRoomEvent(
          client,
          roomId: scheduledRoomId,
          type: 'm.room.message',
          content: _content,
          delay: const Duration(minutes: 5),
          encrypted: false,
        ),
        throwsStateError,
      );
      expect(inner.requests, isEmpty);

      var recipientChecks = 0;
      final id = await guard.protect(
        scheduledRoomId,
        () => putDelayedRoomEvent(
          client,
          roomId: scheduledRoomId,
          type: 'm.room.message',
          content: _content,
          delay: const Duration(minutes: 5),
          encrypted: true,
          encrypt: (payload) async => _megolm(payload),
        ),
        ownerCurrent: () => true,
        validateRecipients: () async => recipientChecks++,
      );
      expect(id, 'x');
      expect(recipientChecks, 1);
      expect(
        inner.requests.single.url.pathSegments,
        contains('m.room.encrypted'),
      );
    });

    test(
      'invalid targets, delays and oversized content send nothing',
      () async {
        final transport = RecordingTransport(
          (_) async => jsonResponse({'delay_id': 'x'}),
        );
        final client = ScheduledClient(transport);
        Future<String> put({
          String type = 'm.room.message',
          Duration delay = const Duration(minutes: 1),
          Map<String, Object?> content = _content,
        }) => putDelayedRoomEvent(
          client,
          roomId: scheduledRoomId,
          type: type,
          content: content,
          delay: delay,
          encrypted: false,
        );
        await expectLater(put(type: 'm.room.encrypted'), throwsArgumentError);
        await expectLater(put(delay: Duration.zero), throwsArgumentError);
        await expectLater(
          put(delay: maxScheduleDelay + const Duration(days: 1)),
          throwsArgumentError,
        );
        await expectLater(
          put(content: {'msgtype': 'm.text', 'body': 'x' * 70000}),
          throwsArgumentError,
        );
        expect(transport.requests, isEmpty);
      },
    );
  });

  group('delayed send errors', () {
    Future<Object> failure(http.Response response) async {
      final client = ScheduledClient(RecordingTransport((_) async => response));
      try {
        await putDelayedRoomEvent(
          client,
          roomId: scheduledRoomId,
          type: 'm.room.message',
          content: _content,
          delay: const Duration(days: 3),
          encrypted: false,
        );
      } catch (error) {
        return error;
      }
      fail('expected an error');
    }

    Matcher kind(DelayedEventFailure kind, {Duration? maxDelay}) =>
        isA<DelayedEventException>()
            .having((e) => e.kind, 'kind', kind)
            .having((e) => e.maxDelay, 'maxDelay', maxDelay);

    test('legacy and current "delay too large" shapes', () async {
      expect(
        await failure(
          jsonResponse({
            'errcode': 'M_UNKNOWN',
            'error': 'The requested delay exceeds the allowed maximum.',
            'org.matrix.msc4140.errcode': 'M_MAX_DELAY_EXCEEDED',
            'org.matrix.msc4140.max_delay': 86400000,
          }, 400),
        ),
        kind(
          DelayedEventFailure.delayTooLarge,
          maxDelay: const Duration(days: 1),
        ),
      );
      expect(
        await failure(
          jsonResponse({
            'errcode': 'M_MAX_DELAY_EXCEEDED',
            'max_delay': 3600000,
          }, 400),
        ),
        kind(
          DelayedEventFailure.delayTooLarge,
          maxDelay: const Duration(hours: 1),
        ),
      );
      expect(
        await failure(
          jsonResponse({'errcode': 'ORG.MATRIX.MSC4140_DELAY_TOO_LARGE'}, 400),
        ),
        kind(DelayedEventFailure.delayTooLarge),
      );
      expect(
        await failure(jsonResponse({'errcode': 'M_DELAY_TOO_LARGE'}, 400)),
        kind(DelayedEventFailure.delayTooLarge),
      );
    });

    test('unsupported, limited and other errors', () async {
      expect(
        await failure(jsonResponse({'errcode': 'M_UNRECOGNIZED'}, 400)),
        kind(DelayedEventFailure.unsupported),
      );
      expect(
        await failure(jsonResponse({'errcode': 'M_LIMIT_EXCEEDED'}, 429)),
        kind(DelayedEventFailure.limited),
      );
      expect(
        await failure(jsonResponse({'errcode': 'M_FORBIDDEN'}, 403)),
        isA<matrix.MatrixException>(),
      );
    });

    test('a server that ignores the delay is reported, not retried', () async {
      expect(
        await failure(jsonResponse({'event_id': r'$sent'})),
        kind(DelayedEventFailure.sentImmediately),
      );
      expect(
        await failure(jsonResponse({})),
        kind(DelayedEventFailure.invalidResponse),
      );
    });
  });

  group('capability', () {
    Future<DelayedEventsCapability> probe(Map<String, http.Response> routes) =>
        probeDelayedEvents(
          ScheduledClient(
            RecordingTransport(
              (request) async =>
                  routes[request.url.path] ?? jsonResponse({}, 500),
            ),
          ),
        );

    test('m.delayed_events capability advertises limits', () async {
      final capability = await probe({
        '/_matrix/client/v3/capabilities': jsonResponse({
          'capabilities': {
            'm.delayed_events': {
              'max_delay_ms': 604800000,
              'max_scheduled': 100,
            },
          },
        }),
      });
      expect(capability.supported, isTrue);
      expect(capability.maxDelay, const Duration(days: 7));
      expect(capability.maxScheduled, 100);
    });

    test('an explicit zero disables delayed events', () async {
      final capability = await probe({
        '/_matrix/client/v3/capabilities': jsonResponse({
          'capabilities': {
            'org.matrix.msc4140.delayed_events': {
              'max_delay_ms': 0,
              'max_scheduled': 100,
            },
          },
        }),
        '/_matrix/client/versions': jsonResponse({
          'versions': ['v1.11'],
          'unstable_features': {'org.matrix.msc4140': true},
        }),
      });
      expect(capability.supported, isFalse);
    });

    test('older Synapse: only /versions unstable_features', () async {
      final capability = await probe({
        '/_matrix/client/v3/capabilities': jsonResponse({'capabilities': {}}),
        '/_matrix/client/versions': jsonResponse({
          'versions': ['v1.11'],
          'unstable_features': {'org.matrix.msc4140': true},
        }),
      });
      expect(capability.supported, isTrue);
      expect(capability.maxDelay, isNull);
    });

    test(
      'no advertisement means unsupported; no answer is a failure',
      () async {
        expect(
          (await probe({
            '/_matrix/client/versions': jsonResponse({
              'versions': ['v1.11'],
            }),
          })).supported,
          isFalse,
        );
        await expectLater(
          probe({}),
          throwsA(
            isA<DelayedEventException>().having(
              (e) => e.kind,
              'kind',
              DelayedEventFailure.probeFailed,
            ),
          ),
        );
      },
    );
  });

  group('server list', () {
    test('pages, skips malformed items and computes send times', () async {
      final transport = RecordingTransport((request) async {
        final from = request.url.queryParameters['from'];
        if (from == null) {
          return jsonResponse({
            'delayed_events': [
              {
                'delay_id': 'syd_a',
                'room_id': scheduledRoomId,
                'type': 'm.room.encrypted',
                'delay': 60000,
                'running_since': 1000000,
                'content': {'ciphertext': 'x'},
              },
              {'delay_id': 'broken'},
              {
                'delay_id': 'syd_call',
                'room_id': scheduledRoomId,
                'type': 'org.matrix.msc3401.call.member',
                'state_key': '_@sam:matrix.example_DEVICE',
                'delay': 8000,
                'running_since': 1000000,
                'content': {},
              },
            ],
            'next_batch': 'page2',
          });
        }
        return jsonResponse({
          'scheduled': [
            {
              'delay_id': 'syd_b',
              'room_id': scheduledRoomId,
              'type': 'm.room.message',
              'delay': 1000,
              'running_since': 5000,
              'content': {'msgtype': 'm.text', 'body': 'hi'},
            },
          ],
        });
      });
      final list = await fetchScheduledDelayedEvents(
        ScheduledClient(transport),
      );
      expect(list.complete, isTrue);
      expect(list.events.map((e) => e.delayId), ['syd_a', 'syd_call', 'syd_b']);
      expect(list.events.first.sendAt, DateTime.utc(1970, 1, 1, 0, 17, 40));
      expect(list.events[1].isTimelineEvent, isFalse);
      expect(transport.requests.first.url.path, endsWith(delayedEventsPath));
      expect(transport.requests.last.url.queryParameters['from'], 'page2');
    });

    test('a capped scan is incomplete; a repeated token ends it', () async {
      final list = await fetchScheduledDelayedEvents(
        ScheduledClient(
          RecordingTransport(
            (request) async => jsonResponse({
              'delayed_events': [],
              'next_batch': '${request.url.queryParameters['from'] ?? ''}x',
            }),
          ),
        ),
        maxPages: 2,
      );
      expect(list.complete, isFalse);
      final repeated = await fetchScheduledDelayedEvents(
        ScheduledClient(
          RecordingTransport(
            (_) async =>
                jsonResponse({'delayed_events': [], 'next_batch': 'same'}),
          ),
        ),
      );
      expect(repeated.complete, isTrue);
    });
  });

  group('manage', () {
    test('send now / cancel post the action for the delay ID', () async {
      final transport = RecordingTransport((_) async => jsonResponse({}));
      final client = ScheduledClient(transport);
      await manageScheduledEvent(client, 'syd_abc', DelayedEventCommand.send);
      await manageScheduledEvent(client, 'syd_abc', DelayedEventCommand.cancel);
      expect(transport.requests.map((r) => r.method), ['POST', 'POST']);
      expect(
        transport.requests.first.url.path,
        '/_matrix/client/unstable/org.matrix.msc4140/delayed_events/syd_abc',
      );
      expect(jsonDecode(transport.requests.first.body), {'action': 'send'});
      expect(jsonDecode(transport.requests.last.body), {'action': 'cancel'});
    });

    test('unknown IDs map to notFound; unsafe IDs are refused', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'errcode': 'M_NOT_FOUND'}, 404),
      );
      final client = ScheduledClient(transport);
      await expectLater(
        manageScheduledEvent(client, 'syd_gone', DelayedEventCommand.cancel),
        throwsA(
          isA<DelayedEventException>().having(
            (e) => e.kind,
            'kind',
            DelayedEventFailure.notFound,
          ),
        ),
      );
      await expectLater(
        manageScheduledEvent(client, '../x', DelayedEventCommand.cancel),
        throwsArgumentError,
      );
      expect(transport.requests, hasLength(1));
    });
  });

  group('MatrixBackend.sendRoomEventDelayed', () {
    test('unencrypted rooms send through the owned guard path', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'syd_backend'}),
      );
      final client = ScheduledClient(transport);
      scheduledRoom(client);
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      final id = await backend.sendRoomEventDelayed(
        scheduledRoomId,
        'm.room.message',
        _content,
        const Duration(minutes: 45),
      );
      expect(id, 'syd_backend');
      final request = transport.requests.single;
      expect(request.url.queryParameters[delayQueryParameter], '2700000');
      expect(jsonDecode(request.body), _content);
    });

    test('encrypted rooms without working encryption fail closed', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'x'}),
      );
      final client = ScheduledClient(transport);
      scheduledRoom(client, encrypted: true);
      expect(client.encryptionEnabled, isFalse);
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      await expectLater(
        backend.sendRoomEventDelayed(
          scheduledRoomId,
          'm.room.message',
          _content,
          const Duration(minutes: 5),
        ),
        throwsStateError,
      );
      expect(transport.requests, isEmpty);
    });

    test('rooms that are not joined and bad types send nothing', () async {
      final transport = RecordingTransport(
        (_) async => jsonResponse({'delay_id': 'x'}),
      );
      final client = ScheduledClient(transport);
      scheduledRoom(client, membership: matrix.Membership.invite);
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      await expectLater(
        backend.sendRoomEventDelayed(
          scheduledRoomId,
          'm.room.message',
          _content,
          const Duration(minutes: 5),
        ),
        throwsStateError,
      );
      await expectLater(
        backend.sendRoomEventDelayed(
          scheduledRoomId,
          'm.room.encrypted',
          _content,
          const Duration(minutes: 5),
        ),
        throwsArgumentError,
      );
      expect(transport.requests, isEmpty);
    });
  });
}
