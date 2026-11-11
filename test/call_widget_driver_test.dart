import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/call/widget_capabilities.dart';
import 'package:parallax/features/call/widget_driver.dart';

import 'call_test_fakes.dart';

const _widgetId = 'widget-1';

class _Harness {
  _Harness({bool encrypted = true})
    : matrix = FakeCallMatrix(encrypted: encrypted) {
    driver = CallWidgetDriver(
      widgetId: _widgetId,
      matrix: matrix,
      send: (json) => sent.add(jsonDecode(json) as Map<String, Object?>),
      allowedCapabilities: elementCallAllowedCapabilities(
        userId: testUser,
        deviceId: testDevice,
        roomId: testRoom,
      ),
      onContentLoaded: () => events.add('loaded'),
      onJoined: () => events.add('joined'),
      onHangup: () => events.add('hangup'),
      onClose: () => events.add('close'),
      onAlwaysOnScreen: (value) => events.add('aos:$value'),
      requestTimeout: const Duration(milliseconds: 200),
    );
  }

  final FakeCallMatrix matrix;
  late final CallWidgetDriver driver;
  final sent = <Map<String, Object?>>[];
  final events = <String>[];
  var _ids = 0;

  /// Sends a fromWidget request and returns its request ID.
  String fromWidget(String action, [Map<String, Object?> data = const {}]) {
    final id = 'req-${++_ids}';
    driver.handleMessage(
      jsonEncode({
        'api': 'fromWidget',
        'widgetId': _widgetId,
        'requestId': id,
        'action': action,
        'data': data,
      }),
    );
    return id;
  }

  Map<String, Object?>? responseTo(String requestId) {
    for (final message in sent) {
      if (message['api'] == 'fromWidget' &&
          message['requestId'] == requestId &&
          message.containsKey('response')) {
        return message['response'] as Map<String, Object?>;
      }
    }
    return null;
  }

  List<Map<String, Object?>> toWidget(String action) => [
    for (final message in sent)
      if (message['api'] == 'toWidget' &&
          message['action'] == action &&
          !message.containsKey('response'))
        message,
  ];

  void answer(Map<String, Object?> request, Map<String, Object?> response) {
    driver.handleMessage(jsonEncode({...request, 'response': response}));
  }

  Future<void> negotiate(List<String> requested) async {
    fromWidget('content_loaded');
    await pumpEventQueue();
    final request = toWidget('capabilities').single;
    answer(request, {'capabilities': requested});
    await pumpEventQueue();
  }
}

List<String> _elementCallRequest() => [
  capRequiresClient,
  capSendDelayedEvent,
  capUpdateDelayedEvent,
  readStateCapability('org.matrix.msc3401.call.member'),
  readStateCapability('m.room.member'),
  readEventCapability(callEncryptionKeysType),
  sendEventCapability(callEncryptionKeysType),
  sendEventCapability('org.matrix.msc4075.rtc.notification'),
  sendEventCapability('m.room.redaction'),
  sendStateCapability(
    'org.matrix.msc3401.call.member',
    '_${testUser}_$testDevice',
  ),
  readToDeviceCapability(callEncryptionKeysType),
  sendToDeviceCapability(callEncryptionKeysType),
  // Not on the allow-list: must be denied.
  readEventCapability('m.room.message'),
  sendStateCapability('org.matrix.msc3401.call.member', '@other:example.org'),
  'org.matrix.msc4039.download_file',
];

void main() {
  test('answers supported_api_versions by echoing the request', () {
    final h = _Harness();
    final id = h.fromWidget('supported_api_versions');
    final response = h.responseTo(id)!;
    expect(response['supported_versions'], contains('org.matrix.msc2762'));
    expect(
      response['supported_versions'],
      contains('org.matrix.msc2762_update_state'),
    );
    final echoed = h.sent.single;
    expect(echoed['widgetId'], _widgetId);
    expect(echoed['action'], 'supported_api_versions');
  });

  test('ignores other widgets, malformed JSON and toWidget requests', () {
    final h = _Harness();
    h.driver.handleMessage('not json');
    h.driver.handleMessage('[1,2]');
    h.driver.handleMessage(
      jsonEncode({
        'api': 'fromWidget',
        'widgetId': 'someone-else',
        'requestId': 'x',
        'action': 'supported_api_versions',
      }),
    );
    h.driver.handleMessage(
      jsonEncode({
        'api': 'toWidget',
        'widgetId': _widgetId,
        'requestId': 'y',
        'action': 'capabilities',
      }),
    );
    expect(h.sent, isEmpty);
  });

  test('content_loaded negotiates only allowed capabilities', () async {
    final h = _Harness();
    h.matrix.state = {
      'org.matrix.msc3401.call.member': [
        stateEvent('org.matrix.msc3401.call.member', '_@alice:example.org_A', {
          'application': 'm.call',
          'call_id': '',
          'device_id': 'A',
        }),
      ],
      'm.room.member': [
        stateEvent('m.room.member', '@alice:example.org', {
          'membership': 'join',
        }),
      ],
    };
    await h.negotiate(_elementCallRequest());

    expect(h.events, contains('loaded'));
    expect(h.driver.negotiated, isTrue);
    final approved = h.driver.capabilities.all;
    expect(approved, isNot(contains(readEventCapability('m.room.message'))));
    expect(approved, isNot(contains('org.matrix.msc4039.download_file')));
    expect(
      approved,
      isNot(
        contains(
          sendStateCapability(
            'org.matrix.msc3401.call.member',
            '@other:example.org',
          ),
        ),
      ),
    );
    expect(approved, contains(capSendDelayedEvent));

    final notify = h.toWidget('notify_capabilities').single;
    final data = notify['data'] as Map<String, Object?>;
    expect((data['approved'] as List).toSet(), approved);
    expect(
      (data['requested'] as List),
      hasLength(_elementCallRequest().length),
    );

    final update = h.toWidget('update_state').single;
    final state = (update['data'] as Map)['state'] as List;
    expect(state, hasLength(2));
  });

  test('requests before negotiation are refused', () async {
    final h = _Harness();
    final id = h.fromWidget('send_event', {
      'type': 'org.matrix.msc4075.rtc.notification',
      'content': {'notification_type': 'ring'},
    });
    await pumpEventQueue();
    expect(h.responseTo(id)!['error'], isA<Map<String, Object?>>());
    expect(h.matrix.roomSends, isEmpty);
  });

  group('send_event', () {
    late _Harness h;
    setUp(() async {
      h = _Harness();
      await h.negotiate(_elementCallRequest());
    });

    test('message events use the guarded room send path', () async {
      final id = h.fromWidget('send_event', {
        'type': 'org.matrix.msc4075.rtc.notification',
        'content': {'notification_type': 'ring', 'lifetime': 30000},
      });
      await pumpEventQueue();
      expect(
        h.matrix.roomSends.single.$1,
        'org.matrix.msc4075.rtc.notification',
      );
      expect(h.responseTo(id), {'room_id': testRoom, 'event_id': r'$sent'});
    });

    test('own call membership state is sent; others are refused', () async {
      final own = h.fromWidget('send_event', {
        'type': 'org.matrix.msc3401.call.member',
        'state_key': '_${testUser}_$testDevice',
        'content': {'application': 'm.call'},
      });
      final other = h.fromWidget('send_event', {
        'type': 'org.matrix.msc3401.call.member',
        'state_key': '@other:example.org',
        'content': {},
      });
      await pumpEventQueue();
      expect(h.matrix.stateSends.single.$2, '_${testUser}_$testDevice');
      expect(h.responseTo(own)!['event_id'], r'$state');
      expect(h.responseTo(other)!['error'], isNotNull);
    });

    test('delayed state returns a delay ID that can be refreshed', () async {
      final id = h.fromWidget('send_event', {
        'type': 'org.matrix.msc3401.call.member',
        'state_key': '_${testUser}_$testDevice',
        'content': <String, Object?>{},
        'delay': 8000,
      });
      await pumpEventQueue();
      expect(h.responseTo(id), {'room_id': testRoom, 'delay_id': 'delay-1'});
      expect(h.matrix.delayedSends.single.$3, 8000);

      final restart = h.fromWidget('org.matrix.msc4157.update_delayed_event', {
        'action': 'restart',
        'delay_id': 'delay-1',
      });
      final unknown = h.fromWidget('org.matrix.msc4157.update_delayed_event', {
        'action': 'cancel',
        'delay_id': 'someone-elses',
      });
      await pumpEventQueue();
      expect(h.responseTo(restart), isEmpty);
      expect(h.responseTo(unknown)!['error'], isNotNull);
      expect(h.matrix.delayedUpdates, [('delay-1', 'restart')]);
    });

    test('delayed message events are refused (no unguarded sends)', () async {
      final id = h.fromWidget('send_event', {
        'type': 'org.matrix.msc4075.rtc.notification',
        'content': <String, Object?>{},
        'delay': 1000,
      });
      await pumpEventQueue();
      expect(h.responseTo(id)!['error'], isNotNull);
      expect(h.matrix.roomSends, isEmpty);
    });

    test('ordinary messages and other rooms are refused', () async {
      final message = h.fromWidget('send_event', {
        'type': 'm.room.message',
        'content': {'msgtype': 'm.text', 'body': 'hi'},
      });
      final elsewhere = h.fromWidget('send_event', {
        'type': 'org.matrix.msc4075.rtc.notification',
        'room_id': '!other:example.org',
        'content': <String, Object?>{},
      });
      await pumpEventQueue();
      expect(h.responseTo(message)!['error'], isNotNull);
      expect(h.responseTo(elsewhere)!['error'], isNotNull);
      expect(h.matrix.roomSends, isEmpty);
    });

    test(
      'redactions only target event IDs and use the redaction path',
      () async {
        final ok = h.fromWidget('send_event', {
          'type': 'm.room.redaction',
          'content': {'redacts': r'$reaction'},
        });
        final bad = h.fromWidget('send_event', {
          'type': 'm.room.redaction',
          'content': {'redacts': 'not-an-event'},
        });
        await pumpEventQueue();
        expect(h.matrix.redactions, [r'$reaction']);
        expect(h.responseTo(ok), {'room_id': testRoom});
        expect(h.responseTo(bad)!['error'], isNotNull);
      },
    );
  });

  test('get_openid returns allowed credentials or blocked', () async {
    final h = _Harness();
    final id = h.fromWidget('get_openid');
    await pumpEventQueue();
    expect(h.responseTo(id), {
      'state': 'allowed',
      'original_request_id': id,
      'access_token': 'openid-token',
      'expires_in': 3600,
      'matrix_server_name': 'example.org',
      'token_type': 'Bearer',
    });

    h.matrix.openIdError = StateError('offline');
    final blocked = h.fromWidget('get_openid');
    await pumpEventQueue();
    expect(h.responseTo(blocked), {
      'state': 'blocked',
      'original_request_id': blocked,
    });
  });

  test('send_to_device encrypts in encrypted rooms', () async {
    final h = _Harness();
    await h.negotiate(_elementCallRequest());
    final id = h.fromWidget('send_to_device', {
      'type': callEncryptionKeysType,
      'encrypted': false,
      'messages': {
        '@alice:example.org': {
          'A': {'keys': <Object?>[], 'room_id': testRoom},
        },
      },
    });
    final denied = h.fromWidget('send_to_device', {
      'type': 'm.room_key',
      'messages': <String, Object?>{},
    });
    await pumpEventQueue();
    expect(h.responseTo(id), isEmpty);
    expect(h.matrix.toDevice.single.$3, isTrue);
    expect(h.responseTo(denied)!['error'], isNotNull);
  });

  test('send_to_device honours plaintext only in unencrypted rooms', () async {
    final h = _Harness(encrypted: false);
    await h.negotiate(_elementCallRequest());
    h.fromWidget('send_to_device', {
      'type': callEncryptionKeysType,
      'messages': {
        '@alice:example.org': {'*': <String, Object?>{}},
      },
    });
    await pumpEventQueue();
    expect(h.matrix.toDevice.single.$3, isFalse);
  });

  test('pushes only readable room events and safe to-device events', () async {
    final h = _Harness();
    await h.negotiate(_elementCallRequest());
    h.sent.clear();

    h.matrix.roomEventController
      ..add({
        'type': callEncryptionKeysType,
        'sender': '@alice:example.org',
        'content': <String, Object?>{},
        'event_id': r'$keys',
        'room_id': testRoom,
      })
      ..add({
        'type': 'm.room.message',
        'sender': '@alice:example.org',
        'content': {'msgtype': 'm.text', 'body': 'secret'},
        'event_id': r'$msg',
        'room_id': testRoom,
      });
    h.matrix.stateController.add(
      stateEvent('org.matrix.msc3401.call.member', '_@bob:example.org_B', {}),
    );
    h.matrix.toDeviceController
      ..add({
        'type': callEncryptionKeysType,
        'sender': '@alice:example.org',
        'content': {'room_id': testRoom},
        'encrypted': true,
      })
      ..add({
        // Cleartext in an encrypted room: dropped.
        'type': callEncryptionKeysType,
        'sender': '@mallory:example.org',
        'content': {'room_id': testRoom},
        'encrypted': false,
      })
      ..add({
        // Keys for another room: dropped.
        'type': callEncryptionKeysType,
        'sender': '@alice:example.org',
        'content': {'room_id': '!other:example.org'},
        'encrypted': true,
      });
    await pumpEventQueue();

    final events = h.toWidget('send_event');
    expect(events, hasLength(1));
    expect((events.single['data'] as Map)['event_id'], r'$keys');
    expect(h.toWidget('update_state'), hasLength(1));
    final toDevice = h.toWidget('send_to_device');
    expect(toDevice, hasLength(1));
    expect((toDevice.single['data'] as Map)['encrypted'], isTrue);
  });

  test('read_events respects read capabilities', () async {
    final h = _Harness();
    h.matrix.state = {
      'm.room.member': [
        stateEvent('m.room.member', '@alice:example.org', {
          'membership': 'join',
        }),
      ],
    };
    h.matrix.history = [
      {
        'type': 'm.room.message',
        'content': {'body': 'secret'},
      },
    ];
    await h.negotiate(_elementCallRequest());
    final members = h.fromWidget('org.matrix.msc2876.read_events', {
      'type': 'm.room.member',
      'state_key': true,
    });
    final messages = h.fromWidget('org.matrix.msc2876.read_events', {
      'type': 'm.room.message',
    });
    await pumpEventQueue();
    expect((h.responseTo(members)!['events'] as List), hasLength(1));
    expect(h.responseTo(messages)!['error'], isNotNull);
  });

  test('Element actions are acknowledged and surfaced', () async {
    final h = _Harness();
    final join = h.fromWidget('io.element.join');
    h.fromWidget('set_always_on_screen', {'value': true});
    h.fromWidget('im.vector.hangup');
    h.fromWidget('io.element.close');
    final unknown = h.fromWidget('org.matrix.msc2931.navigate', {'uri': 'x'});
    expect(h.responseTo(join), isEmpty);
    expect(h.events, ['joined', 'aos:true', 'hangup', 'close']);
    expect(h.responseTo(unknown)!['error'], isNotNull);
  });

  test('hangUp sends im.vector.hangup and completes on the answer', () async {
    final h = _Harness();
    var done = false;
    final future = h.driver.hangUp().then((_) => done = true);
    final request = h.toWidget('im.vector.hangup').single;
    expect(done, isFalse);
    h.answer(request, const {});
    await future;
    expect(done, isTrue);
  });

  test('unanswered capability request fails closed', () async {
    final h = _Harness();
    h.fromWidget('content_loaded');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(h.driver.negotiated, isTrue);
    expect(h.driver.capabilities.all, isEmpty);
  });

  test('startIfIdle negotiates once when content_loaded was missed', () async {
    final h = _Harness();
    h.driver.startIfIdle();
    h.driver.startIfIdle();
    await pumpEventQueue();
    expect(h.toWidget('capabilities'), hasLength(1));
  });

  test('dispose stops forwarding and releases the room driver', () async {
    final h = _Harness();
    await h.negotiate(_elementCallRequest());
    h.driver.dispose();
    h.sent.clear();
    h.matrix.roomEventController.add({
      'type': callEncryptionKeysType,
      'content': <String, Object?>{},
    });
    h.fromWidget('supported_api_versions');
    await pumpEventQueue();
    expect(h.sent, isEmpty);
    expect(h.matrix.disposed, isTrue);
  });

  test('newCallWidgetId is random hex', () {
    final a = newCallWidgetId();
    final b = newCallWidgetId();
    expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(a, isNot(b));
  });
}
