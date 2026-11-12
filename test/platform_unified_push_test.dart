import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parallax/features/platform/unified_push.dart';
import 'package:parallax/push_notifications.dart';
import 'package:parallax/push_settings_screen.dart';

class _Store implements PushStateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

class _FakeApi implements UnifiedPushApi {
  List<String> installed = ['io.heckel.ntfy'];
  String? saved;
  String endpoint = 'https://ntfy.example.org/upABC123?up=1';
  bool answer = true;
  String? failWith;
  final registered = <String>[];
  final unregistered = <String>[];
  void Function(String, String)? onNewEndpoint;
  void Function(String, String)? onRegistrationFailed;
  void Function(String)? onUnregistered;
  void Function(Uint8List, String)? onMessage;

  @override
  Future<void> initialize({
    required void Function(String endpoint, String instance) onNewEndpoint,
    required void Function(String reason, String instance) onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(Uint8List content, String instance) onMessage,
  }) async {
    this.onNewEndpoint = onNewEndpoint;
    this.onRegistrationFailed = onRegistrationFailed;
    this.onUnregistered = onUnregistered;
    this.onMessage = onMessage;
  }

  @override
  Future<List<String>> distributors() async => installed;
  @override
  Future<String?> savedDistributor() async => saved;
  @override
  Future<void> saveDistributor(String distributor) async => saved = distributor;

  @override
  Future<void> register(String instance) async {
    registered.add(instance);
    if (!answer) return;
    scheduleMicrotask(() {
      final failure = failWith;
      if (failure != null) {
        onRegistrationFailed!(failure, instance);
      } else {
        onNewEndpoint!(endpoint, instance);
      }
    });
  }

  @override
  Future<void> unregister(String instance) async => unregistered.add(instance);
}

class _FakeAlerts implements PushAlertSurface {
  bool permission = true;
  int cancelled = 0;
  final shown = <PushEnvelope>[];
  void Function(Map<String, dynamic>)? onOpen;
  void Function(Map<String, dynamic>)? onMarkRead;

  @override
  Future<void> initialize({
    required void Function(Map<String, dynamic>) onOpen,
    required void Function(Map<String, dynamic>) onMarkRead,
  }) async {
    this.onOpen = onOpen;
    this.onMarkRead = onMarkRead;
  }

  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<void> show(PushEnvelope envelope) async => shown.add(envelope);
  @override
  Future<void> cancelAll() async => cancelled++;
}

/// Completes [future] by alternately pumping the widget test's fake-async
/// zone and yielding a real event-loop turn: cleanup awaits
/// `StreamSubscription.cancel()`, which can complete through a root-zone
/// future that fake time never runs.
Future<void> pumpUntilDone(WidgetTester tester, Future<void> future) async {
  var done = false;
  Object? error;
  unawaited(
    future.then(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(done, isTrue, reason: 'future did not complete');
  if (error != null) throw error!;
}

const _discovered = '{"unifiedpush":{"gateway":"matrix"}}';

Uint8List _relayed(
  String registrationId, {
  String appId = unifiedPushAppId,
  String roomId = '!room:example.org',
  String? eventId = r'$event',
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'notification': {
        'event_id': ?eventId,
        'room_id': roomId,
        'sender': '@secret:example.org',
        'content': {'body': 'Private message MUST NOT be shown'},
        'counts': {'unread': 2},
        'devices': [
          {
            'app_id': appId,
            'pushkey': 'https://ntfy.example.org/upABC123?up=1',
            'data': {
              'format': 'event_id_only',
              'registration_id': registrationId,
            },
          },
        ],
      },
    }),
  ),
);

void main() {
  late _FakeApi api;
  late _FakeAlerts alerts;
  late _Store store;
  late List<Uri> gatewayRequests;
  late http.Response Function(http.Request) gatewayResponse;
  late PushNotifications push;
  late List<PushRegistration> registered;
  late List<PushRegistration> removed;
  late List<PushNavigationRequest> navigated;

  PushSession session(String user) => PushSession(
    userId: user,
    deviceId: 'DEVICE',
    registerPusher: (r) async => registered.add(r),
    removePusher: (r) async => removed.add(r),
    onNavigate: (r) async => navigated.add(r),
  );

  setUp(() {
    api = _FakeApi();
    alerts = _FakeAlerts();
    store = _Store();
    gatewayRequests = [];
    gatewayResponse = (_) => http.Response(_discovered, 200);
    registered = [];
    removed = [];
    navigated = [];
    push = PushNotifications(
      unifiedPushDriver: UnifiedPushDriver(
        api: api,
        alerts: alerts,
        httpClient: () => MockClient((request) async {
          gatewayRequests.add(request.url);
          return gatewayResponse(request);
        }),
      ),
      store: store,
      configuration: const PushConfiguration(),
    );
  });

  tearDown(() async {
    await push.shutdown();
  });

  Future<void> enableUnifiedPush([
    PushConfiguration configuration = const PushConfiguration.unifiedPush(),
  ]) async {
    await push.configure(configuration);
    await push.setSession(session('@alice:example.org'));
    await push.enable(consent: true);
    await push.settle();
  }

  group('registration', () {
    test('registers an http pusher on the discovered Matrix gateway', () async {
      await enableUnifiedPush();
      expect(push.active, isTrue);
      expect(push.provider, PushProvider.unifiedPush);
      final registration = registered.single;
      final pusher = registration.pusher;
      expect(pusher.appId, unifiedPushAppId);
      expect(pusher.kind, 'http');
      expect(pusher.pushkey, api.endpoint);
      expect(
        pusher.data.url,
        Uri.parse('https://ntfy.example.org/_matrix/push/v1/notify'),
      );
      // The backend's registration check requires event_id_only, which
      // also keeps message content away from the distributor's server.
      expect(pusher.data.format, 'event_id_only');
      expect(
        pusher.data.additionalProperties['registration_id'],
        registration.registrationId,
      );
      expect(
        gatewayRequests.single.toString(),
        'https://ntfy.example.org/_matrix/push/v1/notify',
      );
      expect(api.saved, 'io.heckel.ntfy');
      expect(api.registered, [unifiedPushInstance]);
      final binding = PushBackgroundBinding.parse(store.value)!;
      expect(binding.configuration.isUnifiedPush, isTrue);
      expect(binding.configuration.gatewayUrl, pusher.data.url);
      expect(binding.registrationId, registration.registrationId);
    });

    test('a manual gateway skips discovery', () async {
      final gateway = Uri.parse(
        'https://push.example.org/_matrix/push/v1/notify',
      );
      await enableUnifiedPush(
        PushConfiguration.unifiedPush(gatewayUrl: gateway),
      );
      expect(gatewayRequests, isEmpty);
      expect(registered.single.pusher.data.url, gateway);
      expect(push.active, isTrue);
    });

    test(
      'a server without a Matrix gateway uses the UnifiedPush public gateway',
      () async {
        gatewayResponse = (_) => http.Response('Not found', 404);
        await enableUnifiedPush();
        expect(push.active, isTrue);
        expect(registered.single.pusher.data.url, defaultUnifiedPushGateway);
      },
    );

    test(
      'a broken gateway answer explains why and registers nothing',
      () async {
        gatewayResponse = (_) => http.Response('Server error', 500);
        await enableUnifiedPush();
        expect(push.active, isFalse);
        expect(push.status, PushStatus.error);
        expect(push.message, contains('does not offer a Matrix gateway'));
        expect(registered, isEmpty);
        expect(api.unregistered, [unifiedPushInstance]);
        expect(store.value, isNull);
      },
    );

    test('several distributors require an explicit choice', () async {
      api.installed = [
        'io.heckel.ntfy',
        'org.unifiedpush.distributor.nextpush',
      ];
      await enableUnifiedPush();
      expect(push.status, PushStatus.error);
      expect(push.message, contains('Choose which UnifiedPush distributor'));
      expect(api.registered, isEmpty);
      await enableUnifiedPush(
        const PushConfiguration.unifiedPush(
          distributor: 'org.unifiedpush.distributor.nextpush',
        ),
      );
      expect(api.saved, 'org.unifiedpush.distributor.nextpush');
      expect(push.active, isTrue);
    });

    test('no installed distributor is explained', () async {
      api.installed = [];
      await enableUnifiedPush();
      expect(push.message, contains('No UnifiedPush distributor is installed'));
      expect(registered, isEmpty);
    });

    test('distributor registration failure is surfaced', () async {
      api.failWith = 'actionRequired';
      await enableUnifiedPush();
      expect(push.status, PushStatus.error);
      expect(push.message, contains('needs attention'));
      expect(registered, isEmpty);
    });

    test('denied notification permission never registers', () async {
      alerts.permission = false;
      await enableUnifiedPush();
      expect(push.status, PushStatus.permissionDenied);
      expect(api.registered, isEmpty);
      expect(registered, isEmpty);
    });

    test('endpoint rotation re-registers with a fresh nonce', () async {
      await enableUnifiedPush();
      final first = registered.single;
      api.onNewEndpoint!(
        'https://ntfy.example.org/upNEW?up=1',
        unifiedPushInstance,
      );
      await push.settle();
      expect(registered, hasLength(2));
      expect(registered.last.token, 'https://ntfy.example.org/upNEW?up=1');
      expect(registered.last.registrationId, isNot(first.registrationId));
      expect(removed.single, same(first));
      expect(push.active, isTrue);
    });
  });

  group('unregistration', () {
    test('logout removes the pusher and unregisters the instance', () async {
      await enableUnifiedPush();
      final registration = registered.single;
      await push.logout();
      expect(removed.single, same(registration));
      expect(api.unregistered, [unifiedPushInstance]);
      expect(alerts.cancelled, greaterThan(0));
      expect(store.value, isNull);
      expect(push.active, isFalse);
    });

    test('distributor unregistration stops push and cleans up', () async {
      await enableUnifiedPush();
      final registration = registered.single;
      api.onUnregistered!(unifiedPushInstance);
      await push.settle();
      expect(push.enabled, isFalse);
      expect(push.status, PushStatus.error);
      expect(push.message, contains('removed Parallax’s registration'));
      expect(removed.single, same(registration));
      expect(api.unregistered, [unifiedPushInstance]);
      expect(store.value, isNull);
    });

    test('switching to Firebase deactivates UnifiedPush', () async {
      await enableUnifiedPush();
      await push.configure(const PushConfiguration());
      expect(push.provider, PushProvider.firebase);
      expect(api.unregistered, [unifiedPushInstance]);
      expect(removed, hasLength(1));
      expect(push.enabled, isFalse);
    });
  });

  group('binding verification', () {
    test('only messages echoing this registration are shown', () async {
      await enableUnifiedPush();
      final registration = registered.single;
      api.onMessage!(_relayed('A' * 32), unifiedPushInstance);
      api.onMessage!(
        _relayed(registration.registrationId, appId: 'org.other.app'),
        unifiedPushInstance,
      );
      api.onMessage!(_relayed(registration.registrationId), 'other-instance');
      await push.settle();
      expect(alerts.shown, isEmpty);
      api.onMessage!(
        _relayed(registration.registrationId),
        unifiedPushInstance,
      );
      await push.settle();
      final envelope = alerts.shown.single;
      expect(envelope.roomId, '!room:example.org');
      expect(envelope.eventId, r'$event');
      expect(jsonEncode(envelope.toJson()), isNot(contains('Private')));
      expect(jsonEncode(envelope.toJson()), isNot(contains('secret')));
    });

    test('taps navigate only for the live registration', () async {
      await enableUnifiedPush();
      final registration = registered.single;
      final payload = {
        'registration_id': registration.registrationId,
        'room_id': '!room:example.org',
        'event_id': r'$event',
      };
      alerts.onOpen!(payload);
      await push.settle();
      expect(navigated.single.roomId, '!room:example.org');
      await push.logout();
      alerts.onOpen!(payload);
      await push.settle();
      expect(navigated, hasLength(1));
    });

    test(
      '"Mark as read" reaches the handler with a verified request',
      () async {
        final marked = <PushNavigationRequest>[];
        push.markReadHandler = (request) async => marked.add(request);
        await enableUnifiedPush();
        final registration = registered.single;
        alerts.onMarkRead!({
          'registration_id': 'B' * 32,
          'room_id': '!room:example.org',
          'event_id': r'$event',
        });
        alerts.onMarkRead!({
          'registration_id': registration.registrationId,
          'room_id': '!room:example.org',
        });
        await push.settle();
        expect(marked, isEmpty);
        alerts.onMarkRead!({
          'registration_id': registration.registrationId,
          'room_id': '!room:example.org',
          'event_id': r'$event',
        });
        await push.settle();
        expect(marked.single.eventId, r'$event');
        expect(marked.single.isCurrent, isTrue);
        expect(navigated, isEmpty);
        // A failing handler must not tear push down.
        push.markReadHandler = (_) async => throw StateError('offline');
        alerts.onMarkRead!({
          'registration_id': registration.registrationId,
          'room_id': '!room:example.org',
          'event_id': r'$event',
        });
        await push.settle();
        expect(push.active, isTrue);
      },
    );

    test('"Mark as read" without a handler opens the room', () async {
      await enableUnifiedPush();
      alerts.onMarkRead!({
        'registration_id': registered.single.registrationId,
        'room_id': '!room:example.org',
        'event_id': r'$event',
      });
      await push.settle();
      expect(navigated.single.roomId, '!room:example.org');
    });

    test(
      'background handler requires the stored UnifiedPush binding',
      () async {
        await enableUnifiedPush();
        final registration = registered.single;
        final raw = store.value!;
        final shown = <PushEnvelope>[];
        Future<void> show(PushEnvelope envelope) async => shown.add(envelope);
        final background = _Store()..value = raw;

        await handleUnifiedPushBackgroundMessage(
          _relayed('C' * 32),
          unifiedPushInstance,
          store: background,
          show: show,
        );
        await handleUnifiedPushBackgroundMessage(
          _relayed(registration.registrationId),
          'other-instance',
          store: background,
          show: show,
        );
        expect(shown, isEmpty);
        await handleUnifiedPushBackgroundMessage(
          _relayed(registration.registrationId),
          unifiedPushInstance,
          store: background,
          show: show,
        );
        expect(shown.single.roomId, '!room:example.org');

        // A Firebase binding never validates UnifiedPush deliveries.
        final firebase = jsonDecode(raw) as Map<String, dynamic>
          ..['configuration'] = PushConfiguration(
            gatewayUrl: Uri.parse(
              'https://gw.example.org/_matrix/push/v1/notify',
            ),
            appId: 'org.example.parallax',
          ).toJson();
        background.value = jsonEncode(firebase);
        await handleUnifiedPushBackgroundMessage(
          _relayed(registration.registrationId),
          unifiedPushInstance,
          store: background,
          show: show,
        );
        expect(shown, hasLength(1));

        background.value = raw;
        await handleUnifiedPushBackgroundUnregistered(
          unifiedPushInstance,
          store: background,
        );
        expect(background.value, isNull);
      },
    );
  });

  group('parseUnifiedPushMessage', () {
    test('accepts a notification exactly as ntfy.sh relays it', () {
      // Captured from https://ntfy.sh/_matrix/push/v1/notify on 12 Nov 2026:
      // ntfy forwards the Matrix push body unchanged as the message.
      const relayed =
          '{"notification": {"event_id": "\$evt:example.org", "room_id": '
          '"!room:example.org", "counts": {"unread": 2}, "devices": [{"app_id": '
          '"net.samrussell.parallax.up", "pushkey": '
          '"https://ntfy.sh/upKvy5ZDySH2ty?up=1", "data": {"registration_id": '
          '"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}]}}';
      final parsed = parseUnifiedPushMessage(
        Uint8List.fromList(utf8.encode(relayed)),
      )!;
      expect(parsed['registration_id'], 'A' * 32);
      expect(parsed['room_id'], '!room:example.org');
      expect(parsed['event_id'], r'$evt:example.org');
      expect(parsed['unread'], 2);
    });

    test('keeps routing fields only', () {
      final parsed = parseUnifiedPushMessage(_relayed('D' * 32))!;
      expect(parsed, {
        'registration_id': 'D' * 32,
        'room_id': '!room:example.org',
        'event_id': r'$event',
        'unread': 2,
      });
    });

    final invalid = <String, Uint8List>{
      'empty': Uint8List(0),
      'not JSON': Uint8List.fromList(utf8.encode('hello')),
      'not UTF-8': Uint8List.fromList([0xff, 0xfe, 0xfd]),
      'no notification': Uint8List.fromList(utf8.encode('{"a":1}')),
      'no devices': Uint8List.fromList(
        utf8.encode('{"notification":{"room_id":"!r:x.org"}}'),
      ),
      'other app': _relayed('E' * 32, appId: 'org.other.app'),
      'non-string nonce': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'notification': {
              'devices': [
                {
                  'app_id': unifiedPushAppId,
                  'data': {'registration_id': 7},
                },
              ],
            },
          }),
        ),
      ),
      'oversized': Uint8List(maxUnifiedPushMessageBytes + 1),
    };
    for (final MapEntry(:key, :value) in invalid.entries) {
      test(
        'rejects $key',
        () => expect(parseUnifiedPushMessage(value), isNull),
      );
    }
  });

  group('discoverUnifiedPushGateway', () {
    Future<Uri> discover(
      String endpoint,
      Future<http.Response> Function(http.Request) handler,
    ) => discoverUnifiedPushGateway(
      endpoint,
      client: MockClient(handler),
      timeout: const Duration(seconds: 2),
    );

    test('keeps the endpoint origin and port', () async {
      final requested = <Uri>[];
      final gateway = await discover(
        'https://ntfy.example.org:8443/upXYZ?up=1',
        (request) async {
          requested.add(request.url);
          expect(request.method, 'GET');
          return http.Response(_discovered, 200);
        },
      );
      expect(
        gateway,
        Uri.parse('https://ntfy.example.org:8443/_matrix/push/v1/notify'),
      );
      expect(requested.single, gateway);
    });

    final failures =
        <String, (String, Future<http.Response> Function(http.Request))>{
          'non-HTTPS endpoint': (
            'http://ntfy.example.org/up',
            (_) async => http.Response(_discovered, 200),
          ),
          'credentials in endpoint': (
            'https://user:pw@ntfy.example.org/up',
            (_) async => http.Response(_discovered, 200),
          ),
          'HTTP 500': (
            'https://ntfy.example.org/up',
            (_) async => http.Response('', 500),
          ),
          'malformed JSON': (
            'https://ntfy.example.org/up',
            (_) async => http.Response('not json', 200),
          ),
          'redirect': (
            'https://ntfy.example.org/up',
            (_) async =>
                http.Response('', 302, headers: {'location': 'https://x'}),
          ),
          'oversized body': (
            'https://ntfy.example.org/up',
            (_) async => http.Response('x' * (17 * 1024), 200),
          ),
          'network error': (
            'https://ntfy.example.org/up',
            (_) async => throw http.ClientException('offline'),
          ),
        };
    final fallbacks = <String, Future<http.Response> Function(http.Request)>{
      'another gateway type': (_) async =>
          http.Response('{"unifiedpush":{"gateway":"other"}}', 200),
      'HTTP 404': (_) async => http.Response('', 404),
      'HTTP 401': (_) async => http.Response('', 401),
      'HTTP 405': (_) async => http.Response('', 405),
    };
    for (final MapEntry(key: name, value: handler) in fallbacks.entries) {
      test('falls back to the public gateway for $name', () async {
        expect(
          await discover('https://ntfy.example.org/up', handler),
          defaultUnifiedPushGateway,
        );
      });
    }

    for (final MapEntry(key: name, value: (endpoint, handler))
        in failures.entries) {
      test('rejects $name', () async {
        await expectLater(
          discover(endpoint, handler),
          throwsA(isA<PushSetupException>()),
        );
      });
    }
  });

  group('configuration', () {
    test('UnifiedPush needs no secrets and round-trips through JSON', () {
      const plain = PushConfiguration.unifiedPush();
      expect(plain.isComplete, isTrue);
      expect(plain.appId, unifiedPushAppId);
      final configured = PushConfiguration.unifiedPush(
        gatewayUrl: Uri.parse('https://gw.example.org/_matrix/push/v1/notify'),
        distributor: 'io.heckel.ntfy',
      );
      final restored = PushConfiguration.fromJson(configured.toJson())!;
      expect(restored.isUnifiedPush, isTrue);
      expect(restored.gatewayUrl, configured.gatewayUrl);
      expect(restored.distributor, 'io.heckel.ntfy');
      expect(
        const PushConfiguration().toJson().containsKey('provider'),
        isFalse,
      );
    });

    test('rejects insecure gateways and malformed distributors', () {
      expect(
        PushConfiguration.unifiedPush(
          gatewayUrl: Uri.parse('http://gw.example.org/_matrix/push/v1/notify'),
        ).issues,
        isNotEmpty,
      );
      expect(
        PushConfiguration.unifiedPush(
          gatewayUrl: Uri.parse('https://gw.example.org/other'),
        ).issues,
        isNotEmpty,
      );
      expect(
        const PushConfiguration.unifiedPush(distributor: '../evil').issues,
        isNotEmpty,
      );
      expect(
        PushConfiguration.fromJson({
          'provider': 'unifiedpush',
          'app_id': 'org.other.app',
        }),
        isNull,
      );
    });
  });

  group('notification actions', () {
    test('"Mark as read" appears only when the event is known', () {
      final withEvent = genericPushNotificationDetails(
        const PushEnvelope(
          registrationId: 'x',
          roomId: '!r:x.org',
          eventId: r'$e',
        ),
      );
      final action = withEvent.android!.actions!.single;
      expect(action.id, pushMarkReadActionId);
      expect(action.title, 'Mark as read');
      expect(action.showsUserInterface, isTrue);
      final withoutEvent = genericPushNotificationDetails(
        const PushEnvelope(registrationId: 'x', roomId: '!r:x.org'),
      );
      expect(withoutEvent.android!.actions, isNull);
      expect(withoutEvent.android!.visibility, NotificationVisibility.private);
    });

    test('responses route taps and actions separately', () {
      final opened = <Map<String, dynamic>>[];
      final marked = <Map<String, dynamic>>[];
      void route(String? actionId, String? payload) =>
          routePushNotificationResponse(
            NotificationResponse(
              notificationResponseType: actionId == null
                  ? NotificationResponseType.selectedNotification
                  : NotificationResponseType.selectedNotificationAction,
              actionId: actionId,
              payload: payload,
            ),
            onOpen: opened.add,
            onMarkRead: marked.add,
          );
      const payload = '{"registration_id":"x","room_id":"!r:x.org"}';
      route(null, payload);
      route(pushMarkReadActionId, payload);
      route('unknown', payload);
      route(null, 'not json');
      expect(opened, hasLength(1));
      expect(marked, hasLength(1));
    });
  });

  group('settings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    // Everything here runs in the widget test's fake-async zone: the shared
    // owner from setUp lives in the real zone, and chaining its queue from UI
    // taps would strand real-zone microtasks.
    PushNotifications fakeZonePush() => PushNotifications(
      unifiedPushDriver: UnifiedPushDriver(
        api: api,
        alerts: alerts,
        httpClient: () =>
            MockClient((_) async => http.Response(_discovered, 200)),
      ),
      store: _Store(),
      configuration: const PushConfiguration(),
    );

    testWidgets(
      'switches to UnifiedPush and enables when a distributor is picked',
      (tester) async {
        api.installed = [
          'io.heckel.ntfy',
          'org.unifiedpush.distributor.nextpush',
        ];
        final local = fakeZonePush();
        await local.setSession(session('@alice:example.org'));
        await tester.pumpWidget(
          MaterialApp(home: PushSettingsScreen(notifications: local)),
        );
        expect(find.text('Your gateway and Firebase configuration'), findsOne);
        await tester.tap(find.text('UnifiedPush'));
        // Two distributors and none chosen yet: it tries, then asks for one.
        await tester.pump();
        await pumpUntilDone(tester, local.settle());
        await tester.pumpAndSettle();
        expect(local.provider, PushProvider.unifiedPush);
        expect(local.active, isFalse);
        expect(
          find.text('Your gateway and Firebase configuration'),
          findsNothing,
        );
        await tester.scrollUntilVisible(
          find.text('NextPush'),
          80,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('ntfy'), findsOneWidget);
        await tester.ensureVisible(find.text('NextPush'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('NextPush'));
        await tester.pump();
        await pumpUntilDone(tester, local.settle());
        await tester.pumpAndSettle();
        expect(
          local.configuration.distributor,
          'org.unifiedpush.distributor.nextpush',
        );
        // No opt-in: picking the distributor registers straight away.
        await pumpUntilDone(tester, local.settle());
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(local.active, isTrue);
        expect(api.saved, 'org.unifiedpush.distributor.nextpush');
        expect(registered.single.pusher.appId, unifiedPushAppId);
        await tester.pumpWidget(const SizedBox());
        await pumpUntilDone(tester, local.shutdown());
        expect(removed, hasLength(1));
      },
    );

    testWidgets('no distributor shows how to get one and registers nothing', (
      tester,
    ) async {
      api.installed = [];
      final local = fakeZonePush();
      await local.setSession(session('@alice:example.org'));
      await tester.pumpWidget(
        MaterialApp(home: PushSettingsScreen(notifications: local)),
      );
      await tester.tap(find.text('UnifiedPush'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Find a distributor'),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('No UnifiedPush distributor found'),
        findsOneWidget,
      );
      expect(api.registered, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await pumpUntilDone(tester, local.shutdown());
    });
  });
}
