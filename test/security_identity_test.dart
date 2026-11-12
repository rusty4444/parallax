import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/security/identity_change_banner.dart';
import 'package:parallax/features/security/identity_trust.dart';
import 'package:parallax/features/security/security_features.dart';
import 'package:parallax/features/security/security_hooks.dart';
import 'package:parallax/hooks/hook_types.dart';

import 'security_fakes.dart';

const _room = '!room:example.org';

IdentityChange _change(String user, UserTrustLevel level, {String? name}) =>
    IdentityChange(
      userId: user,
      displayName: name ?? user,
      trust: UserTrust(
        userId: user,
        level: level,
        masterKey: 'new-$user',
        previousMasterKey: 'old-$user',
      ),
    );

void main() {
  group('identity state machine', () {
    const unseen = IdentitySnapshot(masterKey: 'A');
    const pinnedA = IdentitySnapshot(masterKey: 'A', pinned: true);
    const verifiedA = IdentitySnapshot(masterKey: 'A', verified: true);
    const unseenB = IdentitySnapshot(masterKey: 'B');
    const pinnedB = IdentitySnapshot(masterKey: 'B', pinned: true);

    test('no master key is unknown', () {
      expect(
        classifyIdentity(const IdentitySnapshot(masterKey: null), null),
        UserTrustLevel.unknown,
      );
    });

    test('first sighting is unpinned, not a violation', () {
      expect(classifyIdentity(unseen, null), UserTrustLevel.unpinned);
      expect(nextPinRecord(unseen, null), isNull);
    });

    test('pinning and verifying update the record', () {
      expect(classifyIdentity(pinnedA, null), UserTrustLevel.pinned);
      expect(nextPinRecord(pinnedA, null), const PinRecord('A'));
      expect(classifyIdentity(verifiedA, null), UserTrustLevel.verified);
      expect(
        nextPinRecord(verifiedA, const PinRecord('A')),
        const PinRecord('A', verified: true),
      );
      expect(nextPinRecord(pinnedA, const PinRecord('A')), isNull);
    });

    test('a replaced pinned identity is a pin violation', () {
      const record = PinRecord('A');
      expect(classifyIdentity(unseenB, record), UserTrustLevel.pinViolation);
      // Violations never overwrite what the user accepted.
      expect(nextPinRecord(unseenB, record), isNull);
    });

    test('a replaced verified identity is a verification violation', () {
      const record = PinRecord('A', verified: true);
      expect(
        classifyIdentity(unseenB, record),
        UserTrustLevel.verificationViolation,
      );
    });

    test('acknowledging (pinning the new key) clears the violation', () {
      const record = PinRecord('A', verified: true);
      expect(classifyIdentity(pinnedB, record), UserTrustLevel.pinned);
      expect(nextPinRecord(pinnedB, record), const PinRecord('B'));
    });

    test('re-verifying the new key clears the violation', () {
      const record = PinRecord('A');
      const verifiedB = IdentitySnapshot(masterKey: 'B', verified: true);
      expect(classifyIdentity(verifiedB, record), UserTrustLevel.verified);
    });

    test('losing local verification of the same key is not a reset', () {
      const record = PinRecord('A', verified: true);
      expect(classifyIdentity(unseen, record), UserTrustLevel.unpinned);
      expect(nextPinRecord(unseen, record), isNull);
    });
  });

  group('IdentityPinBook', () {
    test('reports nothing until stored records load', () async {
      final storage = MemoryPinStorage()
        ..data['acct'] = {'@a:x': const PinRecord('A')};
      final book = IdentityPinBook('acct', storage);
      expect(book['@a:x'], isNull);
      var notified = 0;
      book.addListener(() => notified++);
      book.ensureLoaded();
      await pumpEventQueue();
      expect(book.loaded, isTrue);
      expect(book['@a:x'], const PinRecord('A'));
      expect(notified, 1);
    });

    test('observations during load win over storage and persist', () async {
      final storage = MemoryPinStorage()
        ..data['acct'] = {'@a:x': const PinRecord('A')};
      final book = IdentityPinBook('acct', storage)..ensureLoaded();
      book.observe(
        '@a:x',
        const IdentitySnapshot(masterKey: 'A', verified: true),
      );
      await pumpEventQueue();
      expect(book['@a:x'], const PinRecord('A', verified: true));
      expect(
        storage.data['acct']!['@a:x'],
        const PinRecord('A', verified: true),
      );
    });

    test('accept replaces a violation and saves', () async {
      final storage = MemoryPinStorage();
      final book = IdentityPinBook('acct', storage)..ensureLoaded();
      await pumpEventQueue();
      book.observe(
        '@a:x',
        const IdentitySnapshot(masterKey: 'A', pinned: true),
      );
      expect(
        book.observe('@a:x', const IdentitySnapshot(masterKey: 'B')),
        isFalse,
      );
      book.accept('@a:x', const PinRecord('B'));
      await pumpEventQueue();
      expect(storage.data['acct']!['@a:x'], const PinRecord('B'));
    });

    test('storage failures behave as an empty book', () async {
      final book = IdentityPinBook('acct', _FailingStorage())..ensureLoaded();
      await pumpEventQueue();
      expect(book.loaded, isTrue);
      book.observe(
        '@a:x',
        const IdentitySnapshot(masterKey: 'A', pinned: true),
      );
      await pumpEventQueue();
      expect(book['@a:x'], const PinRecord('A'));
    });

    test('evicts the oldest records beyond the cap', () async {
      final book = IdentityPinBook('acct', MemoryPinStorage())..ensureLoaded();
      await pumpEventQueue();
      for (var i = 0; i <= IdentityPinBook.maxRecords; i++) {
        book.observe(
          '@u$i:x',
          IdentitySnapshot(masterKey: 'K$i', pinned: true),
        );
      }
      expect(book.records.length, IdentityPinBook.maxRecords);
      expect(book['@u0:x'], isNull);
      expect(book['@u${IdentityPinBook.maxRecords}:x'], isNotNull);
    });
  });

  group('identity change banner', () {
    Future<void> pump(
      WidgetTester tester,
      SecurityTestBackend backend,
      FakeSecurity security, {
      List<Uri>? opened,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              IdentityChangeBanner(
                backend: backend,
                security: security,
                roomId: _room,
                palette: paletteFor(VisualTheme.parallax),
                openUrl: (url) async {
                  opened?.add(url);
                  return true;
                },
              ),
            ],
          ),
        ),
      ),
    );

    testWidgets('nothing shows without violations', (tester) async {
      final security = FakeSecurity();
      await pump(tester, SecurityTestBackend(), security);
      expect(find.textContaining('digital identity'), findsNothing);
    });

    testWidgets('pin violation can be dismissed by pinning the new key', (
      tester,
    ) async {
      final security = FakeSecurity()
        ..changes[_room] = [
          _change('@bob:example.org', UserTrustLevel.pinViolation, name: 'Bob'),
        ];
      final opened = <Uri>[];
      await pump(tester, SecurityTestBackend(), security, opened: opened);
      expect(
        find.textContaining(
          'Bob’s (@bob:example.org) digital identity was reset.',
        ),
        findsOneWidget,
      );
      expect(find.text('Withdraw verification'), findsNothing);
      await tester.tap(find.text('Verify'));
      await tester.pump();
      expect(security.verifiedUsers, ['@bob:example.org']);
      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(security.acknowledged, [
        ('@bob:example.org', 'new-@bob:example.org'),
      ]);
      expect(find.textContaining('digital identity'), findsNothing);
    });

    testWidgets('verified-user violation is critical and offers withdrawal', (
      tester,
    ) async {
      final security = FakeSecurity()
        ..changes[_room] = [
          _change('@ann:example.org', UserTrustLevel.verificationViolation),
          _change('@bob:example.org', UserTrustLevel.pinViolation),
          _change('@cat:example.org', UserTrustLevel.pinViolation),
        ];
      await pump(tester, SecurityTestBackend(), security);
      expect(
        find.textContaining('verified digital identity was reset'),
        findsOneWidget,
      );
      expect(
        find.textContaining('2 other people’s identities also changed'),
        findsOneWidget,
      );
      expect(find.text('Verify again'), findsOneWidget);
      await tester.tap(find.text('Withdraw verification'));
      await tester.pump();
      expect(security.acknowledged.single.$1, '@ann:example.org');
      // The next violation takes its place.
      expect(
        find.textContaining('(@bob:example.org) digital identity was reset'),
        findsOneWidget,
      );
    });

    testWidgets('busy backends re-check members at most twice a second', (
      tester,
    ) async {
      final security = _CountingSecurity();
      final backend = SecurityTestBackend();
      await pump(tester, backend, security);
      expect(security.reads, 1);
      // A burst of timeline updates: one check now, one when it settles.
      for (var i = 0; i < 30; i++) {
        backend.ping();
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(security.reads, 2);
      await tester.pump(const Duration(milliseconds: 500));
      expect(security.reads, 3);
      // Security changes are shown at once.
      security.changes[_room] = [
        _change('@bob:example.org', UserTrustLevel.pinViolation),
      ];
      security.update();
      await tester.pump();
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('banner follows live security changes', (tester) async {
      final security = FakeSecurity();
      final backend = SecurityTestBackend();
      await pump(tester, backend, security);
      expect(find.text('Dismiss'), findsNothing);
      security.changes[_room] = [
        _change('@bob:example.org', UserTrustLevel.pinViolation),
      ];
      backend.ping();
      await tester.pump();
      expect(find.text('Dismiss'), findsOneWidget);
    });
  });

  group('hooks', () {
    test('trustOf degrades to unknown without a security module', () {
      final backend = _PlainBackend();
      expect(trustOf(backend, '@a:example.org').level, UserTrustLevel.unknown);
      expect(securityFeaturesOf(backend), isNull);
    });

    testWidgets('hooks are inert for backends without security', (
      tester,
    ) async {
      final backend = _PlainBackend();
      late BuildContext captured;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      );
      final palette = paletteFor(VisualTheme.parallax);
      expect(
        securityRoomBanners(
          captured,
          RoomHookContext(backend: backend, roomId: _room, palette: palette),
        ),
        isEmpty,
      );
      expect(
        securitySettingsSections(
          captured,
          SettingsHookContext(backend: backend, palette: palette),
        ),
        isEmpty,
      );
      const child = SizedBox();
      expect(
        wrapWithSecurityGate(
          captured,
          AppHookContext(
            backend: backend,
            palette: palette,
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
          child,
        ),
        same(child),
      );
    });

    testWidgets('banner hook uses the backend security module', (tester) async {
      final backend = _SecureBackend();
      backend.changes[_room] = [
        _change('@bob:example.org', UserTrustLevel.pinViolation),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: securityRoomBanners(
                  context,
                  RoomHookContext(
                    backend: backend,
                    roomId: _room,
                    palette: paletteFor(VisualTheme.parallax),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Dismiss'), findsOneWidget);
      expect(trustOf(backend, '@x:example.org').level, UserTrustLevel.unknown);
    });
  });
}

class _FailingStorage implements IdentityPinStorage {
  @override
  Future<Map<String, PinRecord>> load(String account) async =>
      throw StateError('no storage');
  @override
  Future<void> save(String account, Map<String, PinRecord> records) async =>
      throw StateError('no storage');
}

class _PlainBackend extends SecurityTestBackend {}

class _SecureBackend extends SecurityTestBackend implements SecurityFeatures {
  final _security = FakeSecurity();
  Map<String, List<IdentityChange>> get changes => _security.changes;

  // Only the members the banner uses are forwarded; others hit noSuchMethod.
  @override
  Listenable get securityChanges => _security;
  @override
  List<IdentityChange> identityChanges(String roomId) =>
      _security.identityChanges(roomId);
  @override
  UserTrust trustOf(String userId) => _security.trustOf(userId);
  @override
  Future<void> acknowledgeIdentityChange(String userId, String masterKey) =>
      _security.acknowledgeIdentityChange(userId, masterKey);
  @override
  Future<void> verifyUser(String userId) => _security.verifyUser(userId);
}

class _CountingSecurity extends FakeSecurity {
  int reads = 0;

  @override
  List<IdentityChange> identityChanges(String roomId) {
    reads++;
    return super.identityChanges(roomId);
  }
}
