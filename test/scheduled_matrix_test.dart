import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/features/scheduled/matrix_scheduled.dart';
import 'package:parallax/features/scheduled/scheduled_features.dart';
import 'package:parallax/features/scheduled/scheduled_store.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/room_events.dart';

import 'scheduled_fakes.dart';
import 'widget_test.dart' show FakeBackend;

class _Access implements MatrixSdkAccess {
  _Access(this.client);
  matrix.Client client;
  bool current = true;
  @override
  matrix.Client? get sdkClient => current ? client : null;
  @override
  bool isSessionCurrent(matrix.Client client) =>
      current && identical(client, this.client);
}

class _Sent {
  _Sent(this.roomId, this.type, this.content, this.delay);
  final String roomId;
  final String type;
  final Map<String, Object?> content;
  final Duration delay;
}

class _Sender implements DelayedRoomEventSender {
  final sent = <_Sent>[];
  var next = 0;
  Object? error;
  Completer<void>? gate;
  @override
  Future<String> sendRoomEventDelayed(
    String roomId,
    String type,
    Map<String, Object?> content,
    Duration delay,
  ) async {
    await gate?.future;
    if (error != null) throw error!;
    sent.add(_Sent(roomId, type, content, delay));
    return 'syd_new${next++}';
  }
}

/// Homeserver double: capabilities, the delayed-event list and management.
class _Server {
  Map<String, Object?>? capabilities = {
    'm.delayed_events': {'max_delay_ms': 7 * 86400000, 'max_scheduled': 100},
  };
  bool versionsAdvertise = false;
  List<Map<String, Object?>>? listed = [];
  final managed = <String>[];
  final manageErrors = <String, Map<String, Object?>>{};
  Completer<void>? listGate;

  late final transport = RecordingTransport(_respond);

  Future<http.Response> _respond(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/capabilities')) {
      final value = capabilities;
      return value == null
          ? jsonResponse({'capabilities': {}})
          : jsonResponse({'capabilities': value});
    }
    if (path.endsWith('/client/versions')) {
      return jsonResponse({
        'versions': ['v1.11'],
        'unstable_features': {'org.matrix.msc4140': versionsAdvertise},
      });
    }
    if (path.endsWith('/org.matrix.msc4140/delayed_events') &&
        request.method == 'GET') {
      await listGate?.future;
      final items = listed;
      return items == null
          ? jsonResponse({'errcode': 'M_UNKNOWN'}, 500)
          : jsonResponse({'delayed_events': items});
    }
    if (path.contains('/org.matrix.msc4140/delayed_events/') &&
        request.method == 'POST') {
      final id = request.url.pathSegments.last;
      final action = jsonDecode(request.body)['action'];
      managed.add('$action:$id');
      final error = manageErrors[id];
      if (error != null) return jsonResponse(error, 404);
      listed?.removeWhere((item) => item['delay_id'] == id);
      return jsonResponse({});
    }
    if (path.contains('/event/')) {
      return jsonResponse({
        'type': 'm.room.message',
        'event_id': r'$parent',
        'room_id': scheduledRoomId,
        'sender': '@friend:matrix.example',
        'origin_server_ts': 1000,
        'content': {'msgtype': 'm.text', 'body': 'Parent'},
      });
    }
    return jsonResponse({'errcode': 'M_UNRECOGNIZED'}, 404);
  }
}

Map<String, Object?> _listed(String id, {DateTime? sendAt, String? body}) => {
  'delay_id': id,
  'room_id': scheduledRoomId,
  'type': body == null ? 'm.room.encrypted' : 'm.room.message',
  'delay': 60000,
  'running_since':
      (sendAt ?? DateTime.utc(2026, 11, 13, 9)).millisecondsSinceEpoch - 60000,
  'content': body == null
      ? {'ciphertext': 'x'}
      : {'msgtype': 'm.text', 'body': body},
};

const _account = '["https://matrix.example","@sam:matrix.example"]';

void main() {
  final now = DateTime(2026, 11, 12, 10);
  late _Server server;
  late ScheduledClient client;
  late _Access access;
  late _Sender sender;
  late MemoryStore storage;
  late ScheduledMessageStore store;
  late MatrixScheduledMessages features;

  setUp(() {
    server = _Server();
    client = ScheduledClient(server.transport);
    scheduledRoom(client, encrypted: true);
    access = _Access(client);
    sender = _Sender();
    storage = MemoryStore();
    store = ScheduledMessageStore(storage: storage);
    features = MatrixScheduledMessages(
      FakeBackend(),
      access,
      sender,
      store: store,
      clock: () => now,
    );
  });

  test('schedules the draft composed like a normal send', () async {
    final sendAt = DateTime(2026, 11, 13, 9);
    final message = await features.scheduleDraft(
      scheduledRoomId,
      const ComposerDraft(
        text: '  **Hi** @friend:matrix.example  ',
        replyToId: r'$parent',
      ),
      sendAt,
    );
    final sent = sender.sent.single;
    expect(sent.roomId, scheduledRoomId);
    expect(sent.type, 'm.room.message');
    expect(sent.delay, sendAt.difference(now));
    expect(sent.content['body'], '**Hi** @friend:matrix.example');
    expect(sent.content['format'], 'org.matrix.custom.html');
    expect(sent.content['formatted_body'], contains('<strong>Hi</strong>'));
    expect(
      (sent.content['m.mentions'] as Map)['user_ids'],
      contains('@friend:matrix.example'),
    );
    expect(sent.content['m.relates_to'], {
      'm.in_reply_to': {'event_id': r'$parent'},
    });
    expect(message.delayId, 'syd_new0');
    expect(message.encrypted, isTrue);
    expect(
      features.scheduledIn(scheduledRoomId).single.preview,
      contains('Hi'),
    );
    final stored = await store.read(_account);
    expect(
      stored['syd_new0']!.content['body'],
      '**Hi** @friend:matrix.example',
    );
  });

  test('thread drafts carry the thread relation', () async {
    await features.scheduleDraft(
      scheduledRoomId,
      const ComposerDraft(text: 'In thread', threadRootId: r'$root'),
      DateTime(2026, 11, 12, 11),
    );
    expect(sender.sent.single.content['m.relates_to'], {
      'rel_type': 'm.thread',
      'event_id': r'$root',
      'is_falling_back': true,
    });
  });

  test('unsupported homeservers are refused before anything is sent', () async {
    server.capabilities = null;
    await expectLater(
      features.scheduleDraft(
        scheduledRoomId,
        const ComposerDraft(text: 'x'),
        DateTime(2026, 11, 12, 11),
      ),
      throwsA(
        isA<DelayedEventException>().having(
          (e) => e.kind,
          'kind',
          DelayedEventFailure.unsupported,
        ),
      ),
    );
    expect(sender.sent, isEmpty);
    expect(
      scheduledErrorMessage(
        const DelayedEventException(DelayedEventFailure.unsupported),
      ),
      'Your homeserver doesn’t support scheduled messages.',
    );
  });

  test('advertised limits, past times and edits are checked locally', () async {
    server.capabilities = {
      'm.delayed_events': {'max_delay_ms': 86400000, 'max_scheduled': 10},
    };
    Future<void> attempt(DateTime when, Matcher matcher, {bool edit = false}) =>
        expectLater(
          features.scheduleDraft(
            scheduledRoomId,
            ComposerDraft(text: 'x', editing: edit),
            when,
          ),
          matcher,
        );
    await attempt(
      DateTime(2026, 11, 14, 10),
      throwsA(
        isA<DelayedEventException>()
            .having((e) => e.kind, 'kind', DelayedEventFailure.delayTooLarge)
            .having((e) => e.maxDelay, 'max', const Duration(days: 1)),
      ),
    );
    expect(
      scheduledErrorMessage(
        const DelayedEventException(
          DelayedEventFailure.delayTooLarge,
          maxDelay: Duration(days: 1),
        ),
      ),
      'Your homeserver only lets you schedule messages up to 24 hours ahead.',
    );
    await attempt(now, throwsA(isA<ScheduleInputError>()));
    await attempt(
      DateTime(2026, 11, 12, 11),
      throwsA(isA<ScheduleInputError>()),
      edit: true,
    );
    expect(sender.sent, isEmpty);
  });

  test('a server rejection of the delay clears cached limits', () async {
    sender.error = const DelayedEventException(
      DelayedEventFailure.delayTooLarge,
      maxDelay: Duration(hours: 1),
    );
    await expectLater(
      features.scheduleDraft(
        scheduledRoomId,
        const ComposerDraft(text: 'x'),
        DateTime(2026, 11, 12, 15),
      ),
      throwsA(isA<DelayedEventException>()),
    );
    final probes = server.transport.requests
        .where((r) => r.url.path.endsWith('/capabilities'))
        .length;
    await features.delayedEventsCapability();
    expect(
      server.transport.requests
          .where((r) => r.url.path.endsWith('/capabilities'))
          .length,
      probes + 1,
    );
  });

  test('refresh drops records the server no longer has', () async {
    await store.put(
      _account,
      ScheduledRecord(
        delayId: 'syd_kept',
        roomId: scheduledRoomId,
        type: 'm.room.message',
        content: {'msgtype': 'm.text', 'body': 'Kept secret'},
        sendAt: DateTime.utc(2026, 11, 13, 9),
        createdAt: DateTime.utc(2026, 11, 1),
        encrypted: true,
      ),
    );
    await store.put(
      _account,
      ScheduledRecord(
        delayId: 'syd_sent',
        roomId: scheduledRoomId,
        type: 'm.room.message',
        content: {'msgtype': 'm.text', 'body': 'Already sent'},
        sendAt: DateTime.utc(2026, 11, 12, 9),
        createdAt: DateTime.utc(2026, 11, 1),
        encrypted: true,
      ),
    );
    server.listed = [_listed('syd_kept')];
    features.ensureScheduledLoaded();
    expect(features.scheduledState, ScheduledLoadState.idle);
    await features.refreshScheduled();
    expect(features.scheduledState, ScheduledLoadState.ready);
    final items = features.scheduledIn(scheduledRoomId);
    expect(items.single.delayId, 'syd_kept');
    expect(items.single.preview, 'Kept secret');
    expect((await store.read(_account)).keys, ['syd_kept']);

    // A failed list never deletes and shows the local record unconfirmed.
    server.listed = null;
    await features.refreshScheduled();
    expect(features.scheduledState, ScheduledLoadState.failed);
    expect(features.scheduledIn(scheduledRoomId).single.confirmed, isFalse);
    expect((await store.read(_account)).keys, ['syd_kept']);
  });

  test('send now and cancel manage the delay and forget the record', () async {
    server.listed = [_listed('syd_a', body: 'A'), _listed('syd_b', body: 'B')];
    await features.refreshScheduled();
    final items = features.scheduledIn(scheduledRoomId);
    await features.sendScheduledNow(items.first);
    await features.cancelScheduled(items.last);
    expect(server.managed, ['send:syd_a', 'cancel:syd_b']);
    expect(features.scheduledIn(scheduledRoomId), isEmpty);
  });

  test('an already finalised message is forgotten and reported', () async {
    server.listed = [_listed('syd_a', body: 'A')];
    await features.refreshScheduled();
    server.manageErrors['syd_a'] = {'errcode': 'M_NOT_FOUND'};
    await expectLater(
      features.cancelScheduled(features.scheduledIn(scheduledRoomId).single),
      throwsA(
        isA<DelayedEventException>().having(
          (e) => e.kind,
          'kind',
          DelayedEventFailure.notFound,
        ),
      ),
    );
    expect(features.scheduledIn(scheduledRoomId), isEmpty);
  });

  test('reschedule creates the copy before cancelling the original', () async {
    await features.scheduleDraft(
      scheduledRoomId,
      const ComposerDraft(text: 'Move me'),
      DateTime(2026, 11, 12, 18),
    );
    server.listed = [_listed('syd_new0')];
    final original = features.scheduledIn(scheduledRoomId).single;
    final copy = await features.rescheduleScheduled(
      original,
      DateTime(2026, 11, 13, 9),
    );
    expect(copy.delayId, 'syd_new1');
    expect(sender.sent.last.content['body'], 'Move me');
    expect(sender.sent.last.delay, DateTime(2026, 11, 13, 9).difference(now));
    expect(server.managed, ['cancel:syd_new0']);
    expect(features.scheduledIn(scheduledRoomId).map((m) => m.delayId), [
      'syd_new1',
    ]);
    expect((await store.read(_account)).keys, ['syd_new1']);
  });

  test('if the original already went out, the copy is withdrawn', () async {
    await features.scheduleDraft(
      scheduledRoomId,
      const ComposerDraft(text: 'Too late'),
      DateTime(2026, 11, 12, 18),
    );
    final original = features.scheduledIn(scheduledRoomId).single;
    server.manageErrors['syd_new0'] = {'errcode': 'M_NOT_FOUND'};
    await expectLater(
      features.rescheduleScheduled(original, DateTime(2026, 11, 13, 9)),
      throwsA(isA<DelayedEventException>()),
    );
    expect(server.managed, ['cancel:syd_new0', 'cancel:syd_new1']);
    expect(features.scheduledIn(scheduledRoomId), isEmpty);
    expect(await store.read(_account), isEmpty);
  });

  test('a replaced session never receives an old refresh', () async {
    server.listed = [_listed('syd_old', body: 'Old account')];
    server.listGate = Completer<void>();
    final refreshing = features.refreshScheduled();
    await pumpEventQueue();
    final replacement = ScheduledClient(_Server().transport);
    scheduledRoom(replacement);
    access.client = replacement;
    server.listGate!.complete();
    await refreshing;
    expect(features.scheduledIn(scheduledRoomId), isEmpty);
    expect(features.scheduledState, ScheduledLoadState.idle);
  });

  test('a local save failure keeps the message listed this session', () async {
    storage.failWrite = true;
    await features.scheduleDraft(
      scheduledRoomId,
      const ComposerDraft(text: 'Unsaved'),
      DateTime(2026, 11, 12, 18),
    );
    server.listed = [_listed('syd_new0')];
    await features.refreshScheduled();
    expect(features.scheduledIn(scheduledRoomId).single.preview, 'Unsaved');
  });
}
