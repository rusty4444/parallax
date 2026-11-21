import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/chat_lock/chat_lock_gate.dart';
import 'package:parallax/features/chat_lock/chat_lock_store.dart';
import 'package:parallax/features/home/app_lock/app_lock_controller.dart';
import 'package:parallax/features/home/app_lock/pin_hash.dart';
import 'package:parallax/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecure implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FakeBiometrics implements BiometricUnlock {
  bool available = false;
  bool succeed = true;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String reason) async => available && succeed;
}

void main() {
  late _FakeSecure secure;
  late _FakeBiometrics biometrics;
  late ChatLockStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = _FakeSecure();
    biometrics = _FakeBiometrics();
    store = ChatLockStore(secureStore: secure, biometrics: biometrics);
  });

  test('locks persist per account and survive a rebind', () async {
    await store.bindAccount('account-a');
    await store.setLocked('!room:example.org', true);
    expect(store.isLocked('!room:example.org'), isTrue);
    expect(store.needsUnlock('!room:example.org'), isTrue);

    // A fresh store for the same account reads the persisted set.
    final reopened = ChatLockStore(secureStore: secure, biometrics: biometrics);
    await reopened.bindAccount('account-a');
    expect(reopened.isLocked('!room:example.org'), isTrue);

    // Another account does not see it.
    final other = ChatLockStore(secureStore: secure, biometrics: biometrics);
    await other.bindAccount('account-b');
    expect(other.isLocked('!room:example.org'), isFalse);
  });

  test('unlocking with the app PIN reveals the chat for the session', () async {
    secure.values['parallax.app_lock.v1.pin'] = PinHash.create(
      '2468',
      iterations: 1000,
    ).encode();
    await store.bindAccount('account-a');
    await store.refreshCredential();
    expect(store.pinSet, isTrue);
    expect(store.canLock, isTrue);
    await store.setLocked('!room:example.org', true);

    expect(await store.unlockWithPin('!room:example.org', '0000'), isFalse);
    expect(store.needsUnlock('!room:example.org'), isTrue);
    expect(await store.unlockWithPin('!room:example.org', '2468'), isTrue);
    expect(store.needsUnlock('!room:example.org'), isFalse);
    expect(store.isLocked('!room:example.org'), isTrue); // still locked at rest
  });

  test('biometric unlock works when enabled and available', () async {
    secure.values['parallax.app_lock.v1.biometric'] = 'true';
    biometrics.available = true;
    await store.bindAccount('account-a');
    await store.refreshCredential();
    expect(store.biometricAvailable, isTrue);
    await store.setLocked('!room:example.org', true);
    expect(await store.unlockWithBiometrics('!room:example.org'), isTrue);
    expect(store.needsUnlock('!room:example.org'), isFalse);
  });

  test('unlocking is disabled without a credential', () async {
    await store.bindAccount('account-a');
    await store.refreshCredential();
    expect(store.canLock, isFalse);
    expect(await store.unlockWithPin('!room:example.org', '2468'), isFalse);
  });

  testWidgets('gate hides a locked chat until unlocked', (tester) async {
    await store.bindAccount('account-a');
    await store.setLocked('!room:example.org', true);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatLockScope(
          store: store,
          child: ChatLockGate(
            roomId: '!room:example.org',
            roomName: 'Secret room',
            palette: paletteFor(VisualTheme.parallax),
            child: const Text('SECRET CONTENT'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('SECRET CONTENT'), findsNothing);
    expect(find.text('This chat is locked'), findsOneWidget);

    store.markUnlocked('!room:example.org');
    await tester.pump();
    expect(find.text('SECRET CONTENT'), findsOneWidget);
  });

  testWidgets('gate passes through an unlocked chat', (tester) async {
    await store.bindAccount('account-a');
    await tester.pumpWidget(
      MaterialApp(
        home: ChatLockScope(
          store: store,
          child: ChatLockGate(
            roomId: '!room:example.org',
            roomName: 'Open room',
            palette: paletteFor(VisualTheme.parallax),
            child: const Text('VISIBLE'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('VISIBLE'), findsOneWidget);
  });
}
