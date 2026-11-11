import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/home/app_lock/app_lock_controller.dart';
import 'package:parallax/features/home/app_lock/app_lock_gate.dart';
import 'package:parallax/features/home/app_lock/app_lock_settings_screen.dart';
import 'package:parallax/features/home/app_lock/pin_hash.dart';
import 'package:parallax/secure_store.dart';

import 'home_fakes.dart';

class _Store implements SecureValueStore {
  final values = <String, String>{};
  bool fail = false;

  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Biometrics implements BiometricUnlock {
  bool available = true;
  bool succeed = true;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeed;
  }
}

void main() {
  late _Store store;
  late _Biometrics biometrics;
  late DateTime now;

  AppLockController controller() => AppLockController(
    store: store,
    biometrics: biometrics,
    clock: () => now,
    hasher: (pin) async => PinHash.create(pin, iterations: 2),
    verifier: (hash, pin) async => hash.verify(pin),
  );

  setUp(() {
    store = _Store();
    biometrics = _Biometrics()..available = false;
    now = DateTime(2026, 11, 12, 9);
  });

  group('PIN hash', () {
    test('verifies, round-trips and never stores the PIN', () {
      final hash = PinHash.create('2580', iterations: 3);
      expect(hash.verify('2580'), isTrue);
      expect(hash.verify('2581'), isFalse);
      final encoded = hash.encode();
      expect(encoded, isNot(contains('2580')));
      final decoded = PinHash.decode(encoded)!;
      expect(decoded.verify('2580'), isTrue);
      expect(PinHash.create('2580', iterations: 3).encode(), isNot(encoded));
      expect(PinHash.decode('{"v":1,"salt":"AA==","hash":"AA=="}'), isNull);
      expect(PinHash.decode('not json'), isNull);
    });

    test('PBKDF2-HMAC-SHA256 matches the RFC 7914 test vector', () {
      final out = pbkdf2('passwd'.codeUnits, 'salt'.codeUnits, 1);
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc',
      );
    });
  });

  group('controller', () {
    test('rejects short and forbidden PINs', () {
      expect(AppLockController.validatePin('12'), PinProblem.length);
      expect(AppLockController.validatePin('12a4'), PinProblem.length);
      expect(AppLockController.validatePin('0000'), PinProblem.forbidden);
      expect(AppLockController.validatePin('1234'), PinProblem.forbidden);
      expect(AppLockController.validatePin('2580'), isNull);
    });

    test('wrong attempts persist across restarts and lock at start', () async {
      final first = controller();
      await first.load();
      expect(first.locked, isFalse);
      await first.setPin('2580');
      expect(store.values.values.join(), isNot(contains('2580')));
      expect(await first.verifyPin('1111'), isFalse);
      expect(first.remainingAttempts, 2);
      first.dispose();

      final second = controller();
      await second.load();
      expect(second.locked, isTrue);
      expect(second.remainingAttempts, 2);
      expect(await second.verifyPin('2580'), isTrue);
      expect(second.locked, isFalse);
      expect(second.remainingAttempts, AppLockConfig.maxAttempts);
      await second.clear();
      expect(store.values, isEmpty);
      second.dispose();
    });

    test('locks only after the background grace period', () async {
      final lock = controller();
      addTearDown(lock.dispose);
      await lock.load();
      await lock.setPin('2580');
      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 1));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isFalse);
      lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 2));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('unreadable storage reports an error instead of trapping', () async {
      store.fail = true;
      final lock = controller();
      addTearDown(lock.dispose);
      await lock.load();
      expect(lock.loaded, isTrue);
      expect(lock.locked, isFalse);
      expect(lock.loadError, isNotNull);
    });
  });

  group('lock screen', () {
    late HomeFakeBackend backend;
    late AppLockController lock;

    Future<void> pumpGate(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          builder: (context, child) => AppLockGate(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            controller: lock,
            child: child!,
          ),
          home: const Scaffold(body: Text('Secret inbox')),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> enter(WidgetTester tester, String pin) async {
      for (final digit in pin.split('')) {
        await tester.tap(find.byKey(ValueKey('pin-key-$digit')));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    setUp(() async {
      backend = HomeFakeBackend();
      final setup = controller();
      await setup.load();
      await setup.setPin('2580');
      setup.dispose();
      lock = controller();
    });

    tearDown(() => lock.dispose());

    testWidgets('a configured PIN hides content until unlocked', (
      tester,
    ) async {
      await pumpGate(tester);
      expect(find.text('Parallax is locked'), findsOneWidget);
      expect(find.text('Secret inbox'), findsNothing);
      await enter(tester, '1111');
      expect(find.textContaining('Wrong PIN. You have 2 more'), findsOneWidget);
      await enter(tester, '2580');
      expect(find.text('Parallax is locked'), findsNothing);
      expect(find.text('Secret inbox'), findsOneWidget);
    });

    testWidgets('three wrong PINs sign out and remove the PIN', (tester) async {
      await pumpGate(tester);
      for (var i = 0; i < AppLockConfig.maxAttempts; i++) {
        await enter(tester, '1111');
      }
      expect(backend.logouts, 1);
      expect(store.values, isEmpty);
    });

    testWidgets('forgot PIN asks before signing out', (tester) async {
      await pumpGate(tester);
      await tester.tap(find.text('Forgot PIN?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.logouts, 0);
      await tester.tap(find.text('Forgot PIN?'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(backend.logouts, 1);
    });

    testWidgets('enabled biometrics prompt and unlock', (tester) async {
      biometrics.available = true;
      store.values['parallax.app_lock.v1.biometric'] = 'true';
      await pumpGate(tester);
      expect(biometrics.prompts, 1);
      expect(find.text('Secret inbox'), findsOneWidget);
    });

    testWidgets('settings set up a PIN with confirmation and biometrics', (
      tester,
    ) async {
      store.values.clear();
      biometrics.available = true;
      await lock.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: AppLockSettingsScreen(
            controller: lock,
            palette: paletteFor(VisualTheme.parallax),
          ),
        ),
      );
      await tester.tap(find.text('Set up PIN'));
      await tester.pumpAndSettle();
      await enter(tester, '1234');
      expect(find.textContaining('security reasons'), findsOneWidget);
      await enter(tester, '2580');
      expect(find.text('Confirm PIN'), findsOneWidget);
      await enter(tester, '2581');
      expect(find.textContaining('PINs don’t match'), findsOneWidget);
      await enter(tester, '2580');
      await enter(tester, '2580');
      expect(find.text('Allow biometric unlock'), findsWidgets);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Allow biometric unlock'),
      );
      await tester.pumpAndSettle();
      expect(lock.pinSet, isTrue);
      expect(lock.biometricEnabled, isTrue);
      expect(find.text('Change PIN'), findsOneWidget);
      await tester.tap(find.text('Remove PIN'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(lock.pinSet, isFalse);
      expect(store.values, isEmpty);
    });
  });
}
