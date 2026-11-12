import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parallax/features/notifications/background_push.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notification_store.dart';
import 'package:parallax/features/notifications/push_handoff.dart';
import 'package:parallax/features/notifications/rich_push_handler.dart';
import 'package:parallax/features/platform/unified_push.dart';
import 'package:parallax/push_notifications.dart';

import 'notifications_fakes.dart';

const _registration = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _room = '!room:example.org';

class _BindingStore implements PushStateStore {
  _BindingStore(this.value);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

String _bindingJson() => jsonEncode({
  'consent': true,
  'user_id': '@me:example.org',
  'device_id': 'DEVICE',
  'registration_id': _registration,
  'configuration': PushConfiguration.unifiedPush(
    gatewayUrl: Uri.parse('https://gw.example.org/_matrix/push/v1/notify'),
  ).toJson(),
});

ResolvedPushEvent _resolved() => ResolvedPushEvent(
  roomId: _room,
  eventId: r'$event',
  kind: NotifiableEventKind.message,
  roomName: 'Book club',
  isDirect: false,
  line: NotificationLine(
    eventId: r'$event',
    senderId: '@alice:example.org',
    senderName: 'Alice',
    text: 'Background hello',
    timestamp: DateTime.now(),
  ),
);

void main() {
  late Directory directory;
  late NotificationStore store;
  late FakeSurface surface;
  late List<(String, Map<String, Object?>)> handoffs;
  late HandoffResult handoffResult;
  late PushEventResolver resolver;

  BackgroundPushEnvironment environment() => BackgroundPushEnvironment(
    handOff: (kind, payload) async {
      handoffs.add((kind, payload));
      return handoffResult;
    },
    surface: () async => surface,
    store: () async => store,
    resolver: (_) async => resolver,
    contentUriFor: () async =>
        (path) => 'content://test$path',
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('parallax_background');
    store = NotificationStore(directory);
    surface = FakeSurface();
    handoffs = [];
    handoffResult = HandoffResult.unavailable;
    resolver = (_, _) async => _resolved();
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  final binding = PushBackgroundBinding.parse(_bindingJson())!;
  final envelope = binding.envelope({
    'registration_id': _registration,
    'room_id': _room,
    'event_id': r'$event',
  })!;

  group('background push', () {
    test(
      'a running main isolate gets the push; nothing is shown here',
      () async {
        handoffResult = HandoffResult.accepted;
        var resolved = false;
        resolver = (_, _) async {
          resolved = true;
          return _resolved();
        };
        final outcome = await handleBackgroundPushEnvelope(
          binding: binding,
          envelope: envelope,
          stillBound: () async => true,
          environment: environment(),
        );
        expect(outcome, isNull);
        expect(resolved, isFalse);
        expect(handoffs.single.$1, handoffKindPush);
        // Only routing fields are handed over.
        expect(handoffs.single.$2.keys.toSet(), {
          'registration_id',
          'room_id',
          'event_id',
        });
        expect(surface.shown, isEmpty);
        expect(surface.generic, isEmpty);
      },
    );

    test('a refusing main isolate is final', () async {
      handoffResult = HandoffResult.rejected;
      expect(
        await handleBackgroundPushEnvelope(
          binding: binding,
          envelope: envelope,
          stillBound: () async => true,
          environment: environment(),
        ),
        isNull,
      );
      expect(surface.shown, isEmpty);
      expect(surface.generic, isEmpty);
    });

    test('without a main isolate it resolves and renders here', () async {
      final outcome = await handleBackgroundPushEnvelope(
        binding: binding,
        envelope: envelope,
        stillBound: () async => true,
        environment: environment(),
      );
      expect(outcome, RichPushOutcome.rich);
      final shown = surface.byId(roomNotificationId(_room))!;
      expect(shown.body, 'Alice: Background hello');
      // Appended to the shared private history for later pushes.
      expect(
        (await store.threads(
          notificationAccountKey('@me:example.org', 'DEVICE'),
        )).single.lines.single.text,
        'Background hello',
      );
    });

    test(
      'a failed background client falls back to the generic alert',
      () async {
        resolver = (_, _) async => throw StateError('database busy');
        expect(
          await handleBackgroundPushEnvelope(
            binding: binding,
            envelope: envelope,
            stillBound: () async => true,
            environment: environment(),
          ),
          RichPushOutcome.generic,
        );
        expect(surface.generic.single.eventId, r'$event');
      },
    );

    test('a binding revoked meanwhile posts nothing', () async {
      expect(
        await handleBackgroundPushEnvelope(
          binding: binding,
          envelope: envelope,
          stillBound: () async => false,
          environment: environment(),
        ),
        RichPushOutcome.skipped,
      );
      expect(surface.shown, isEmpty);
      expect(surface.generic, isEmpty);
    });

    test('UnifiedPush background messages use the same flow', () async {
      final bindingStore = _BindingStore(_bindingJson());
      final content = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'notification': {
              'room_id': _room,
              'event_id': r'$event',
              'devices': [
                {
                  'app_id': unifiedPushAppId,
                  'pushkey': 'https://up.example.org/x',
                  'data': {'registration_id': _registration},
                },
              ],
            },
          }),
        ),
      );
      await handleUnifiedPushBackgroundMessage(
        content,
        unifiedPushInstance,
        store: bindingStore,
        environment: environment(),
      );
      expect(surface.byId(roomNotificationId(_room))!.title, 'Book club');
    });
  });

  group('quick reply from the action isolate', () {
    NotificationResponse reply(String text, {String? actionId}) =>
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          actionId: actionId ?? pushReplyActionId,
          input: text,
          payload: jsonEncode({
            'registration_id': _registration,
            'room_id': _room,
            'event_id': r'$event',
          }),
        );

    test('is handed to the main isolate, never sent here', () async {
      handoffResult = HandoffResult.accepted;
      await handleBackgroundNotificationAction(
        reply('  On my way  '),
        environment: environment(),
        bindingStore: _BindingStore(_bindingJson()),
      );
      expect(handoffs.single.$1, handoffKindReply);
      expect(handoffs.single.$2['text'], 'On my way');
      expect(handoffs.single.$2['room_id'], _room);
      expect(surface.shown, isEmpty);
      expect(await store.takePendingReplies(), isEmpty);
    });

    test('without a main isolate it waits privately for the app', () async {
      // Seed the room's history as a previous push would have.
      await store.appendEvent(
        notificationAccountKey('@me:example.org', 'DEVICE'),
        _resolved(),
      );
      await handleBackgroundNotificationAction(
        reply('On my way'),
        environment: environment(),
        bindingStore: _BindingStore(_bindingJson()),
      );
      final pending = await store.takePendingReplies();
      expect(pending.single.text, 'On my way');
      expect(pending.single.roomId, _room);
      expect(pending.single.userId, '@me:example.org');
      final shown = surface.byId(roomNotificationId(_room))!;
      final messages =
          (shown.details.android!.styleInformation!
                  as MessagingStyleInformation)
              .messages!;
      expect(messages.map((m) => m.text), [
        'Background hello',
        'On my way',
        quickReplyPendingLine,
      ]);
    });

    test('a stale registration or refusal reports failure', () async {
      handoffResult = HandoffResult.rejected;
      await handleBackgroundNotificationAction(
        reply('hello'),
        environment: environment(),
        bindingStore: _BindingStore(_bindingJson()),
      );
      expect(await store.takePendingReplies(), isEmpty);
      expect(
        surface.byId(roomNotificationId(_room))!.body,
        quickReplyFailedLine,
      );
      surface.shown.clear();
      handoffResult = HandoffResult.unavailable;
      await handleBackgroundNotificationAction(
        reply('hello'),
        environment: environment(),
        bindingStore: _BindingStore(null),
      );
      expect(await store.takePendingReplies(), isEmpty);
      expect(
        surface.byId(roomNotificationId(_room))!.body,
        quickReplyFailedLine,
      );
    });

    test('other actions and empty replies are ignored', () async {
      await handleBackgroundNotificationAction(
        reply('x', actionId: pushMarkReadActionId),
        environment: environment(),
      );
      await handleBackgroundNotificationAction(
        reply('   '),
        environment: environment(),
      );
      expect(handoffs, isEmpty);
      expect(surface.shown, isEmpty);
    });
  });

  group('background client lock', () {
    test(
      'one background client at a time; stale locks are reclaimed',
      () async {
        final first = await BackgroundClientLock.acquire(directory.path);
        expect(first, isNotNull);
        expect(await BackgroundClientLock.acquire(directory.path), isNull);
        await first!.release();
        final again = await BackgroundClientLock.acquire(directory.path);
        expect(again, isNotNull);
        BackgroundClientLock.fileIn(directory.path).setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 5)),
        );
        expect(await BackgroundClientLock.acquire(directory.path), isNotNull);
      },
    );

    test('the main isolate waits for the lock, bounded', () async {
      final lock = (await BackgroundClientLock.acquire(directory.path))!;
      var waited = false;
      final waiting = waitForBackgroundPushClient(
        directory.path,
        poll: const Duration(milliseconds: 5),
      ).then((_) => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(waited, isFalse);
      await lock.release();
      await waiting;
      expect(waited, isTrue);

      await BackgroundClientLock.acquire(directory.path);
      final stopwatch = Stopwatch()..start();
      await waitForBackgroundPushClient(
        directory.path,
        maxWait: const Duration(milliseconds: 50),
        poll: const Duration(milliseconds: 5),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('event fetch', () {
    Future<Map<String, Object?>> fetch(http.Client client) => fetchPushEvent(
      httpClient: client,
      homeserver: Uri.parse('https://matrix.example.org'),
      accessToken: 'token',
      roomId: _room,
      eventId: r'$event',
    );

    test('uses the bearer token and validates the event identity', () async {
      late http.BaseRequest seen;
      final json = await fetch(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'event_id': r'$event',
              'room_id': _room,
              'type': 'm.room.encrypted',
              'sender': '@alice:example.org',
              'origin_server_ts': 1,
              'content': {'ciphertext': 'x'},
            }),
            200,
          );
        }),
      );
      expect(json['type'], 'm.room.encrypted');
      expect(seen.headers['authorization'], 'Bearer token');
      expect(
        seen.url.toString(),
        'https://matrix.example.org/_matrix/client/v3/rooms/'
        '!room:example.org/event/\$event',
      );
      expect(
        fetch(
          MockClient(
            (_) async => http.Response(
              jsonEncode({'event_id': r'$other', 'room_id': _room}),
              200,
            ),
          ),
        ),
        throwsStateError,
      );
      expect(
        fetch(MockClient((_) async => http.Response('{}', 403))),
        throwsStateError,
      );
      expect(
        fetch(
          MockClient(
            (_) async => http.Response.bytes(Uint8List(300 * 1024), 200),
          ),
        ),
        throwsStateError,
      );
    });
  });
}
