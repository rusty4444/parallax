import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/push_notifications.dart';
import 'package:parallax/push_settings_screen.dart';

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
    push = PushNotifications(driver: driver, store: store);
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
}
