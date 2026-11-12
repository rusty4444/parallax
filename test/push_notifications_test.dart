import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_model.dart'
    show maxLinesPerRoom;
import 'package:parallax/features/platform/background_connection.dart';
import 'package:parallax/push_notifications.dart';
import 'package:parallax/push_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const options = FirebaseOptions(
  apiKey: 'test-not-a-live-key',
  appId: '1:123456:android:abcdef123456',
  messagingSenderId: '123456',
  projectId: 'test-project',
);
final configuration = PushConfiguration(
  gatewayUrl: Uri.parse('https://push.example.org/_matrix/push/v1/notify'),
  appId: 'org.example.parallax',
  firebaseOptions: options,
);

class _Connection implements BackgroundConnectionPlatform {
  @override
  Future<bool> start() async => true;
  @override
  Future<void> stop() async {}
  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;
  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;
}

class MemoryPushStore implements PushStateStore {
  String? value;
  bool failDeletion = false;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async {
    if (value == null && failDeletion) throw StateError('store unavailable');
    if (value != null && writeGate != null) {
      writeStarted?.complete();
      await writeGate!.future;
    }
    this.value = value;
  }
}

class FakePushDriver implements PushDriver {
  final tokens = StreamController<String>.broadcast(sync: true);
  final received = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  int initializations = 0;
  int permissions = 0;
  int tokenReads = 0;
  int deactivations = 0;
  final shown = <PushEnvelope>[];
  final configurations = <PushConfiguration>[];
  PushPermission permission = PushPermission.authorized;
  Completer<PushPermission>? permissionGate;
  @override
  Stream<String> get tokenChanges => tokens.stream;
  @override
  Stream<Map<String, dynamic>> get messages => received.stream;
  @override
  Stream<Map<String, dynamic>> get openedMessages => opened.stream;
  @override
  Future<void> initialize(PushConfiguration configuration) async {
    initializations++;
    configurations.add(configuration);
  }

  @override
  Future<PushPermission> requestPermission() async {
    permissions++;
    return permissionGate == null ? permission : await permissionGate!.future;
  }

  @override
  Future<String?> getToken() async {
    tokenReads++;
    return 'token-a';
  }

  @override
  Future<void> showNotification(PushEnvelope envelope) async =>
      shown.add(envelope);
  @override
  Future<void> deactivate() async {
    deactivations++;
  }
}

void main() {
  late FakePushDriver driver;
  late MemoryPushStore store;
  late PushNotifications push;
  late List<PushRegistration> registered;
  late List<PushRegistration> removed;
  late List<PushNavigationRequest> navigated;

  PushSession session(
    String user, {
    Future<void> Function(PushRegistration)? register,
    Future<void> Function(PushRegistration)? remove,
    Future<void> Function(PushNavigationRequest)? navigate,
  }) => PushSession(
    userId: user,
    deviceId: 'DEVICE',
    registerPusher: register ?? (r) async => registered.add(r),
    removePusher: remove ?? (r) async => removed.add(r),
    onNavigate: navigate ?? (r) async => navigated.add(r),
  );

  Map<String, dynamic> payload(PushRegistration registration) => {
    'registration_id': registration.registrationId,
    'room_id': '!room:example.org',
    'event_id': r'$event',
    'body': 'Private message MUST NOT be shown',
    'sender': '@private:example.org',
  };

  setUp(() {
    driver = FakePushDriver();
    store = MemoryPushStore();
    registered = [];
    removed = [];
    navigated = [];
    // An incomplete Firebase setup, as before the built-in delivery existed.
    push = PushNotifications(
      driver: driver,
      store: store,
      configuration: const PushConfiguration(),
    );
  });
  tearDown(() async {
    await push.shutdown();
    await driver.tokens.close();
    await driver.received.close();
    await driver.opened.close();
  });

  test(
    'default and missing configuration make no Firebase or pusher contact',
    () async {
      expect(push.enabled, isFalse);
      expect(push.active, isFalse);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      expect(push.status, PushStatus.configurationRequired);
      expect(push.message, contains('HTTPS'));
      expect(driver.initializations, 0);
      expect(driver.permissions, 0);
      expect(driver.tokenReads, 0);
      expect(registered, isEmpty);
      expect(store.value, isNull);
    },
  );

  test('rejects HTTP, URL credentials and Firebase sender/app mismatches', () {
    expect(
      PushConfiguration(
        gatewayUrl: Uri.parse('http://example.org'),
        appId: 'org.example.app',
        firebaseOptions: options,
      ).issues,
      isNotEmpty,
    );
    expect(
      PushConfiguration(
        gatewayUrl: Uri.parse('https://user:pass@example.org'),
        appId: 'org.example.app',
        firebaseOptions: options,
      ).issues,
      isNotEmpty,
    );
    expect(
      PushConfiguration(
        gatewayUrl: configuration.gatewayUrl,
        appId: configuration.appId,
        firebaseOptions: const FirebaseOptions(
          apiKey: 'x',
          appId: '1:999:android:abcdef',
          messagingSenderId: '123456',
          projectId: 'p',
        ),
      ).issues,
      isNotEmpty,
    );
  });

  test(
    'configuration alone and rejected consent never contact driver',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: false);
      expect(push.status, PushStatus.disabled);
      expect(driver.initializations, 0);
      expect(registered, isEmpty);
    },
  );

  test('denied permission never creates token or claims active', () async {
    driver.permission = PushPermission.denied;
    await push.configure(configuration);
    await push.setSession(session('@alice:example.org'));
    await push.enable(consent: true);
    expect(push.status, PushStatus.permissionDenied);
    expect(driver.permissions, 1);
    expect(driver.tokenReads, 0);
    expect(registered, isEmpty);
    expect(push.active, isFalse);
  });

  test(
    'registers event_id_only and token rotation removes exact old pusher',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      final first = registered.single;
      expect(push.active, isTrue);
      expect(first.pusher.data.format, 'event_id_only');
      expect(first.pusher.data.url, configuration.gatewayUrl);
      expect(
        first.pusher.data.additionalProperties['registration_id'],
        first.registrationId,
      );
      driver.tokens.add('token-b');
      await push.settle();
      expect(registered.map((r) => r.token), ['token-a', 'token-b']);
      expect(removed.single, same(first));
      expect(registered.last.registrationId, isNot(first.registrationId));
      driver.opened.add(payload(first));
      await push.settle();
      expect(navigated, isEmpty);
      await push.disable();
      expect(push.active, isFalse);
      expect(push.enabled, isFalse);
      expect(removed.map((r) => r.token), ['token-a', 'token-b']);
      expect(driver.deactivations, 1);
      expect(store.value, isNull);
      driver.tokens.add('token-c');
      await push.settle();
      expect(registered, hasLength(2));
    },
  );

  test(
    'notifications discard private content and unsigned/unbound payloads',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      driver.received.add({'room_id': '!room:example.org', 'body': 'private'});
      driver.received.add(payload(registered.single));
      driver.opened.add(payload(registered.single));
      await push.settle();
      expect(driver.shown, hasLength(1));
      expect(driver.shown.single.toJson().containsKey('body'), isFalse);
      expect(
        PushEnvelope.notificationBody,
        'Open Parallax to read your messages.',
      );
      expect(navigated.single.roomId, '!room:example.org');
      expect(navigated.single.isCurrent, isTrue);
      final old = registered.single;
      await push.logout();
      driver.opened.add(payload(old));
      await push.settle();
      expect(navigated, hasLength(1));
      expect(navigated.single.isCurrent, isFalse);
    },
  );

  test(
    'logout joins in-flight registration then removes it using old account',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      await push.configure(configuration);
      await push.setSession(
        session(
          '@alice:example.org',
          register: (r) async {
            registered.add(r);
            started.complete();
            await gate.future;
          },
        ),
      );
      final enabling = push.enable(consent: true);
      await started.future;
      var loggedOut = false;
      final loggingOut = push.logout().then((_) => loggedOut = true);
      expect(push.enabled, isFalse);
      expect(push.active, isFalse);
      await Future<void>.value();
      expect(loggedOut, isFalse);
      gate.complete();
      await enabling;
      await loggingOut;
      expect(removed.single.userId, '@alice:example.org');
      expect(store.value, isNull);
      expect(push.active, isFalse);
    },
  );

  test('disable during permission wait cancels token creation', () async {
    final permission = Completer<PushPermission>();
    driver.permissionGate = permission;
    await push.configure(configuration);
    await push.setSession(session('@alice:example.org'));
    final enabling = push.enable(consent: true);
    while (driver.permissions == 0) {
      await Future<void>.value();
    }
    final disabling = push.disable();
    permission.complete(PushPermission.authorized);
    await enabling;
    await disabling;
    expect(driver.tokenReads, 0);
    expect(registered, isEmpty);
    expect(push.active, isFalse);
  });

  test(
    'account replacement discards old payloads and requires fresh consent',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      final old = registered.single;
      await push.setSession(session('@bob:example.org'));
      expect(push.enabled, isFalse);
      expect(push.active, isFalse);
      driver.opened.add(payload(old));
      await push.enable(consent: true);
      driver.opened.add(payload(old));
      await push.settle();
      expect(navigated, isEmpty);
      expect(registered.last.userId, '@bob:example.org');
      expect(registered.last.registrationId, isNot(old.registrationId));
    },
  );

  test(
    'logout invalidates and joins pending navigation before returning',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      var committed = false;
      await push.configure(configuration);
      await push.setSession(
        session(
          '@alice:example.org',
          navigate: (request) async {
            started.complete();
            await gate.future;
            if (request.isCurrent) committed = true;
          },
        ),
      );
      await push.enable(consent: true);
      driver.opened.add(payload(registered.single));
      await started.future;
      var finished = false;
      final logout = push.logout().then((_) => finished = true);
      await Future<void>.value();
      expect(finished, isFalse);
      gate.complete();
      await logout;
      expect(committed, isFalse);
    },
  );

  test(
    'complete config without authenticated session never contacts driver',
    () async {
      await push.configure(configuration);
      await push.enable(consent: true);
      expect(push.status, PushStatus.signedOut);
      expect(driver.initializations, 0);
      expect(driver.tokenReads, 0);
    },
  );

  test('foreground initialize clears only local background approval', () async {
    store.value = '{"previous_process":true}';
    await push.initialize();
    expect(store.value, isNull);
    expect(driver.initializations, 0);
    expect(push.enabled, isFalse);
  });

  test('configure then immediate enable uses only new configuration', () async {
    await push.setSession(session('@alice:example.org'));
    final saving = push.configure(configuration);
    final enabling = push.enable(consent: true);
    await saving;
    await enabling;
    expect(driver.configurations.single, same(configuration));
    expect(registered.single.configuration, same(configuration));
    expect(push.active, isTrue);
  });

  test(
    'rapid token refreshes coalesce without registering obsolete tokens',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      driver.tokens.add('token-b');
      driver.tokens.add('token-c');
      driver.tokens.add('token-c');
      await push.settle();
      expect(registered.map((r) => r.token), ['token-a', 'token-c']);
      expect(removed.map((r) => r.token), ['token-a']);
      expect(push.active, isTrue);
    },
  );

  test('ambiguous registration failure is removed and never active', () async {
    await push.configure(configuration);
    await push.setSession(
      session(
        '@alice:example.org',
        register: (r) async {
          registered.add(r);
          throw StateError('response lost');
        },
      ),
    );
    await push.enable(consent: true);
    expect(removed.single, same(registered.single));
    expect(push.active, isFalse);
    expect(push.status, PushStatus.error);
    expect(store.value, isNull);
    expect(driver.deactivations, 1);
  });

  test(
    'cleanup failure still deactivates token and exact removal is retryable',
    () async {
      var failing = true;
      await push.configure(configuration);
      await push.setSession(
        session(
          '@alice:example.org',
          remove: (r) async {
            if (failing) throw StateError('offline');
            removed.add(r);
          },
        ),
      );
      await push.enable(consent: true);
      await expectLater(push.disable(), throwsA(isA<PushCleanupException>()));
      expect(push.enabled, isFalse);
      expect(push.active, isFalse);
      expect(push.status, PushStatus.error);
      expect(driver.deactivations, 1);
      expect(store.value, isNull);
      failing = false;
      await push.disable();
      expect(removed.single, same(registered.single));
    },
  );

  test(
    'background revocation failure blocks new registration until retry',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      store.failDeletion = true;
      await expectLater(push.disable(), throwsA(isA<PushCleanupException>()));
      await push.enable(consent: true);
      expect(driver.initializations, 1);
      expect(registered, hasLength(1));
      expect(push.active, isFalse);
      store.failDeletion = false;
      await push.disable();
      expect(store.value, isNull);
    },
  );

  test(
    'logout joins in-flight storage write and revokes the eventual binding',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      store.writeGate = Completer<void>();
      store.writeStarted = Completer<void>();
      final enabling = push.enable(consent: true);
      await store.writeStarted!.future;
      final logout = push.logout();
      store.writeGate!.complete();
      await enabling;
      await logout;
      expect(push.active, isFalse);
      expect(store.value, isNull);
      expect(removed.single, same(registered.single));
    },
  );

  test(
    'background approval rejects missing config, consent, identity and stale nonce',
    () async {
      expect(PushBackgroundBinding.parse(null), isNull);
      expect(PushBackgroundBinding.parse('not json'), isNull);
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      final valid = jsonDecode(store.value!) as Map<String, dynamic>;
      final binding = PushBackgroundBinding.parse(store.value)!;
      expect(binding.userId, '@alice:example.org');
      expect(binding.envelope(payload(registered.single)), isNotNull);
      expect(
        binding.envelope({
          ...payload(registered.single),
          'registration_id': 'stale',
        }),
        isNull,
      );
      for (final invalid in [
        {...valid, 'consent': false},
        {...valid, 'configuration': const PushConfiguration().toJson()},
        {...valid, 'user_id': ''},
        {...valid, 'device_id': ''},
        {...valid, 'registration_id': ''},
      ]) {
        expect(PushBackgroundBinding.parse(jsonEncode(invalid)), isNull);
      }
      await push.logout();
      expect(PushBackgroundBinding.parse(store.value), isNull);
    },
  );

  test(
    'same-account re-login gets a new generation and rejects previous taps',
    () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      final previous = registered.single;
      await push.setSession(session('@alice:example.org'));
      expect(push.enabled, isFalse);
      await push.enable(consent: true);
      driver.opened.add(payload(previous));
      await push.settle();
      expect(navigated, isEmpty);
      expect(registered.last.registrationId, isNot(previous.registrationId));
    },
  );

  testWidgets('consent dialog cancellation never requests OS permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
    });
    await tester.pumpWidget(
      MaterialApp(home: PushSettingsScreen(notifications: push)),
    );
    await tester.tap(find.byType(SwitchListTile));
    // Consent is pending, so the settings busy indicator animates continuously.
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('I agree — enable'), findsOneWidget);
    expect(driver.initializations, 0);
    await tester.tap(find.text('Keep off'));
    await tester.pumpAndSettle();
    expect(driver.permissions, 0);
    expect(push.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stale consent cannot enable a replacement account', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
    });
    await tester.pumpWidget(
      MaterialApp(home: PushSettingsScreen(notifications: push)),
    );
    await tester.tap(find.byType(SwitchListTile));
    // Consent is pending, so the settings busy indicator animates continuously.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => push.setSession(session('@bob:example.org')));
    await tester.tap(find.text('I agree — enable'));
    await tester.pumpAndSettle();
    expect(driver.initializations, 0);
    expect(driver.permissions, 0);
    expect(push.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'settings default disabled, actionable no-config and no contact',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: PushSettingsScreen(notifications: push)),
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      expect(find.textContaining('own'), findsWidgets);
      expect(find.textContaining('HTTPS'), findsWidgets);
      expect(driver.initializations, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  group('built-in delivery', () {
    late FakePushDriver inApp;
    late PushNotifications builtIn;

    setUp(() {
      inApp = FakePushDriver();
      builtIn = PushNotifications(
        driver: driver,
        inAppDriver: inApp,
        store: store,
        configuration: const PushConfiguration.inApp(),
      );
    });
    tearDown(() async {
      await builtIn.shutdown();
      await inApp.tokens.close();
      await inApp.received.close();
      await inApp.opened.close();
    });

    test('is the default, complete, and survives a JSON round trip', () {
      expect(PushConfiguration.fromEnvironment().isInApp, isTrue);
      const config = PushConfiguration.inApp();
      expect(config.issues, isEmpty);
      expect(config.isComplete, isTrue);
      expect(config.toJson(), {'provider': 'in_app'});
      expect(PushConfiguration.fromJson(config.toJson())!.isInApp, isTrue);
      expect(PushProvider.inApp.label, 'Built in');
    });

    test('enables without registering a pusher or touching Firebase', () async {
      await builtIn.setSession(session('@alice:example.org'));
      await builtIn.enable(consent: true);
      expect(builtIn.active, isTrue);
      expect(builtIn.status, PushStatus.active);
      expect(builtIn.message, contains('stays connected'));
      expect(registered, isEmpty);
      expect(inApp.initializations, 1);
      expect(inApp.permissions, 1);
      expect(inApp.tokenReads, 1);
      expect(driver.initializations, 0);
      await builtIn.disable();
      expect(inApp.deactivations, 1);
      expect(removed, isEmpty);
    });

    test('denied permission keeps it off', () async {
      inApp.permission = PushPermission.denied;
      await builtIn.setSession(session('@alice:example.org'));
      await builtIn.enable(consent: true);
      expect(builtIn.active, isFalse);
      expect(builtIn.status, PushStatus.permissionDenied);
      expect(builtIn.message, contains('turn them on again'));
      expect(inApp.tokenReads, 0);
    });

    test('presents synced events through the rich renderer', () async {
      final rendered = <PushEnvelope>[];
      builtIn.richRenderer = (envelope, isCurrent) async {
        expect(isCurrent(), isTrue);
        rendered.add(envelope);
      };
      expect(
        builtIn.presentInApp(roomId: '!room:example.org', eventId: r'$e'),
        isFalse,
        reason: 'not active yet',
      );
      await builtIn.setSession(session('@alice:example.org'));
      await builtIn.enable(consent: true);
      expect(
        builtIn.presentInApp(roomId: '!room:example.org', eventId: r'$e'),
        isTrue,
      );
      expect(
        builtIn.presentInApp(roomId: 'not-a-room', eventId: r'$e'),
        isFalse,
      );
      await builtIn.settle();
      expect(rendered.single.roomId, '!room:example.org');
      expect(rendered.single.eventId, r'$e');
      // Taps on it verify against the live (pusher-less) registration.
      final request = builtIn.verifiedRequest(rendered.single.toJson());
      expect(request?.roomId, '!room:example.org');
      await builtIn.disable();
      expect(builtIn.verifiedRequest(rendered.single.toJson()), isNull);
      expect(
        builtIn.presentInApp(roomId: '!room:example.org', eventId: r'$e'),
        isFalse,
      );
    });

    testWidgets('turning it off is remembered and needs no consent', (
      tester,
    ) async {
      // Owned in the widget test's fake-async zone, so UI taps can chain its
      // queue.
      SharedPreferences.setMockInitialValues({});
      final owner = PushNotifications(
        driver: FakePushDriver(),
        inAppDriver: FakePushDriver(),
        store: MemoryPushStore(),
        configuration: const PushConfiguration.inApp(),
      );
      await owner.setSession(session('@alice:example.org'));
      await owner.enable(consent: true);
      expect(owner.active, isTrue);
      // Cancelling stream subscriptions completes through the root zone, so
      // alternate fake-time pumps with real event-loop turns.
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
      }

      tester.view
        ..physicalSize = const Size(900, 2600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: PushSettingsScreen(
            notifications: owner,
            connection: _Connection(),
          ),
        ),
      );
      await settle();
      expect(find.text('Notifications are on'), findsOneWidget);
      expect(find.text('Built in'), findsWidgets);
      expect(find.byKey(const ValueKey('push.battery')), findsOneWidget);
      // No distributor installed: suggest ntfy from Google Play.
      expect(find.byKey(const ValueKey('push.get_ntfy')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('push.enable')));
      await settle();
      expect(owner.enabled, isFalse);
      expect(find.text('Notifications are off'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(await InAppNotificationPreferences.turnedOff(), isTrue);
      await tester.tap(find.byKey(const ValueKey('push.enable')));
      await settle();
      expect(owner.active, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      expect(await InAppNotificationPreferences.turnedOff(), isFalse);
      await tester.pumpWidget(const SizedBox());
      var done = false;
      unawaited(owner.shutdown().whenComplete(() => done = true));
      for (var i = 0; i < 100 && !done; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(done, isTrue);
    });

    group('render queue', () {
      /// Lets queued jobs and microtasks run.
      Future<void> turns() async {
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      late List<String> started;
      late Map<String, Completer<void>> gates;
      late List<bool> currentAfter;
      var running = 0;
      var most = 0;

      setUp(() async {
        started = [];
        gates = {};
        currentAfter = [];
        running = 0;
        most = 0;
        builtIn.richRenderer = (envelope, isCurrent) async {
          final id = envelope.eventId!;
          started.add(id);
          running++;
          if (running > most) most = running;
          try {
            await (gates[id] ??= Completer<void>()).future;
            currentAfter.add(isCurrent());
          } finally {
            running--;
          }
        };
        await builtIn.setSession(session('@alice:example.org'));
        await builtIn.enable(consent: true);
      });

      void present(String room, String event) => expect(
        builtIn.presentInApp(roomId: '!$room:example.org', eventId: event),
        isTrue,
      );

      void release(Iterable<String> events) {
        for (final id in events) {
          (gates[id] ??= Completer<void>()).complete();
        }
      }

      test('renders two at once, oldest first, one per room', () async {
        present('a', r'$a1');
        present('a', r'$a2');
        present('b', r'$b1');
        present('c', r'$c1');
        await turns();
        // $a2 waits for $a1 (same room), so $b1 takes the second slot.
        expect(started, [r'$a1', r'$b1']);
        release([r'$a1']);
        await turns();
        expect(started, [r'$a1', r'$b1', r'$a2']);
        release([r'$b1']);
        await turns();
        expect(started, [r'$a1', r'$b1', r'$a2', r'$c1']);
        release([r'$a2', r'$c1']);
        await builtIn.settle();
        expect(most, PushNotifications.maxConcurrentRenders);
        expect(currentAfter, everyElement(isTrue));
        expect(inApp.shown, isEmpty);
      });

      test(
        'a long catch-up keeps each room’s newest events, once each',
        () async {
          // Dropping older events must not shorten the room's conversation.
          expect(
            PushNotifications.maxQueuedRendersPerRoom,
            greaterThan(maxLinesPerRoom),
          );
          const count = 20;
          release([for (var i = 1; i <= count; i++) '\$e$i']);
          present('a', r'$e0');
          for (var i = 1; i <= count; i++) {
            present('a', '\$e$i');
          }
          // Already waiting: not rendered twice.
          present('a', '\$e$count');
          await turns();
          expect(started, [r'$e0']);
          release([r'$e0']);
          await builtIn.settle();
          expect(started, [
            r'$e0',
            for (
              var i = count - PushNotifications.maxQueuedRendersPerRoom + 1;
              i <= count;
              i++
            )
              '\$e$i',
          ]);
        },
      );

      test('past the overall bound the busiest room gives way first', () async {
        // Two slow renders hold both slots while the queue fills up.
        present('x', r'$x');
        present('y', r'$y');
        present('z', r'$z1');
        present('z', r'$z2');
        const single = PushNotifications.maxQueuedRenders - 1;
        for (var i = 0; i < single; i++) {
          present('r$i', '\$r$i');
        }
        await turns();
        expect(started, [r'$x', r'$y']);
        release(gates.keys.toList());
        release([r'$z1', r'$z2', for (var i = 0; i < single; i++) '\$r$i']);
        await builtIn.settle();
        expect(started, isNot(contains(r'$z1')));
        expect(started, contains(r'$z2'));
        expect(started.where((id) => id.startsWith(r'$r')), hasLength(single));
      });

      test('waiting renders never run after sign-out', () async {
        present('a', r'$a');
        present('b', r'$b');
        present('c', r'$c');
        present('d', r'$d');
        await turns();
        expect(started, [r'$a', r'$b']);
        await builtIn.logout();
        expect(
          builtIn.presentInApp(roomId: '!e:example.org', eventId: r'$e'),
          isFalse,
        );
        // The next session renders at once: renders left over from the old
        // one hold no slot and post nothing.
        await builtIn.setSession(session('@bob:example.org'));
        await builtIn.enable(consent: true);
        present('a', r'$new');
        await turns();
        expect(started, [r'$a', r'$b', r'$new']);
        release([r'$a', r'$b', r'$new']);
        await builtIn.settle();
        expect(started, [r'$a', r'$b', r'$new']);
        expect(currentAfter, [false, false, true]);
        expect(inApp.shown, isEmpty);
      });
    });

    test('push providers ignore synced events', () async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      expect(push.active, isTrue);
      expect(
        push.presentInApp(roomId: '!room:example.org', eventId: r'$e'),
        isFalse,
      );
    });
  });

  group('rich notifications', () {
    Future<PushRegistration> enable() async {
      await push.configure(configuration);
      await push.setSession(session('@alice:example.org'));
      await push.enable(consent: true);
      return registered.single;
    }

    test(
      'verified pushes reach the rich renderer, not the generic alert',
      () async {
        final registration = await enable();
        final rendered = <PushEnvelope>[];
        push.richRenderer = (envelope, isCurrent) async {
          expect(isCurrent(), isTrue);
          rendered.add(envelope);
        };
        driver.received.add(payload(registration));
        driver.received.add({...payload(registration), 'registration_id': 'x'});
        await push.settle();
        expect(rendered.single.eventId, r'$event');
        // Only routing fields reach the renderer; content never comes from push.
        expect(rendered.single.toJson().keys, isNot(contains('body')));
        expect(driver.shown, isEmpty);
        expect(push.active, isTrue);
      },
    );

    test('a failing rich renderer falls back to the generic alert', () async {
      final registration = await enable();
      push.richRenderer = (_, _) async => throw StateError('no keys');
      driver.received.add(payload(registration));
      await push.settle();
      expect(driver.shown.single.roomId, '!room:example.org');
      expect(push.active, isTrue);
    });

    test('a render that outlives push posts nothing', () async {
      final registration = await enable();
      final gate = Completer<void>();
      bool? currentAfter;
      push.richRenderer = (_, isCurrent) async {
        await gate.future;
        currentAfter = isCurrent();
        throw StateError('stale');
      };
      driver.received.add(payload(registration));
      await Future<void>.delayed(Duration.zero);
      final disabling = push.disable();
      gate.complete();
      await disabling;
      await push.settle();
      expect(currentAfter, isFalse);
      expect(driver.shown, isEmpty);
    });

    test('background hand-offs are verified like foreground pushes', () async {
      final registration = await enable();
      final rendered = <PushEnvelope>[];
      push.richRenderer = (envelope, _) async => rendered.add(envelope);
      expect(
        push.acceptHandedOffPush({
          ...payload(registration),
          'registration_id': 'C' * 32,
        }),
        isFalse,
      );
      expect(push.acceptHandedOffPush(payload(registration)), isTrue);
      await push.settle();
      expect(rendered, hasLength(1));
      expect(
        push.verifiedRequest(payload(registration))?.roomId,
        '!room:example.org',
      );
      await push.disable();
      expect(push.acceptHandedOffPush(payload(registration)), isFalse);
      expect(push.verifiedRequest(payload(registration)), isNull);
    });
  });
}
