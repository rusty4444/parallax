import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/main.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/push_notifications.dart';
import 'package:parallax/push_settings_screen.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_notifications_test.dart'
    show FakePushDriver, MemoryPushStore, configuration;
import 'widget_test.dart' show FakeBackend;
import 'package:parallax/inbox_screen.dart';

const _roomId = '!push:example.org';
const _joined = ChatRoom(
  id: _roomId,
  name: 'Notification room',
  preview: '',
  lastActivity: null,
);
const _previousRoomId = '!previous:example.org';
const _previousRoom = ChatRoom(
  id: _previousRoomId,
  name: 'Previous room',
  preview: '',
  lastActivity: null,
);

/// Stream cancellation can finish in the real zone even when the app lifecycle
/// callback started in fake async. Pump both zones rather than blocking runAsync
/// on a tail whose next callback needs tester.pump().
Future<void> _join(
  WidgetTester tester,
  Future<void> Function() operation,
) async {
  var done = false;
  Object? failure;
  StackTrace? stack;
  unawaited(
    Future<void>.sync(operation).then<void>(
      (_) {
        done = true;
      },
      onError: (Object error, StackTrace trace) {
        failure = error;
        stack = trace;
        done = true;
      },
    ),
  );
  for (var turn = 0; turn < 100 && !done; turn++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(done, isTrue, reason: 'accepted lifecycle work must join');
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
}

class _Store extends MemoryPushStore {
  _Store(this.events);
  final List<String> events;
  Completer<void>? deletionGate;
  int deletions = 0;

  @override
  Future<void> write(String? value) async {
    if (value == null) {
      events.add('store.clear');
      deletions++;
      await deletionGate?.future;
    }
    await super.write(value);
  }
}

class _Push extends PushNotifications {
  // The opt-in push flow unless a test asks for the built-in delivery.
  _Push(
    this.events, {
    required super.driver,
    required super.store,
    super.inAppDriver,
    PushConfiguration configuration = const PushConfiguration(),
  }) : super(configuration: configuration);
  final List<String> events;
  final bound = <PushSession?>[];
  bool disposed = false;
  int shutdowns = 0;

  @override
  Future<void> setSession(PushSession? session) {
    bound.add(session);
    return super.setSession(session);
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
    events.add('push.shutdown.start');
    try {
      await super.shutdown();
    } finally {
      events.add('push.shutdown.end');
    }
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// An SDK-free Matrix backend seam: exercise app wiring, not live FCM/Matrix.
class _Backend extends MatrixBackend {
  _Backend(this.events);
  final List<String> events;
  Future<void> Function()? cleanupBeforeLogout;
  bool Function()? receiptsEnabled;
  String user = '@alice:example.org';
  String device = 'ALICE';
  int loginGeneration = 1;
  SessionStatus status = SessionStatus.ready;
  List<ChatRoom> roomList = [];
  List<ChatRoom>? refreshedRooms;
  final registrations = <PushRegistration>[];
  final openedRooms = <String>[];
  Completer<void>? initializationGate;
  Completer<void>? refreshGate;
  Completer<void>? removalGate;
  Completer<void>? removalStarted;
  bool failInitialization = false;
  bool failRemoval = false;
  bool failSessionCreation = false;
  bool disposed = false;
  int initializations = 0;
  int refreshes = 0;
  int sessionCreations = 0;
  String? openedRoom;

  @override
  SessionStatus get connection => status;
  @override
  String? get userId => status == SessionStatus.signedOut ? null : user;
  @override
  String get accountKey => user;
  @override
  String? get pushSessionKey =>
      status == SessionStatus.ready ? '$user/$device/$loginGeneration' : null;
  @override
  List<ChatRoom> get rooms => roomList;
  @override
  RoomSyncState get roomSyncState => RoomSyncState.ready;
  @override
  RoomSyncIssue? get roomSyncIssue => null;
  @override
  String? get error => null;
  @override
  String? get activeRoomId => openedRoom;
  @override
  List<ChatEntry> get messages => const [];
  @override
  bool get sending => false;
  @override
  bool get loadingHistory => false;
  @override
  bool get canLoadOlder => false;
  @override
  List<String> get typingUsers => const [];
  @override
  List<PendingSend> get pendingSends => const [];

  @override
  Future<void> initialize() async {
    initializations++;
    events.add('backend.initialize');
    await initializationGate?.future;
    if (failInitialization) throw StateError('storage unavailable');
  }

  @override
  PushSession? createPushSession(
    Future<void> Function(PushNavigationRequest) onNavigate,
  ) {
    sessionCreations++;
    if (failSessionCreation) throw StateError('invalid device');
    if (pushSessionKey == null) return null;
    return PushSession(
      userId: user,
      deviceId: device,
      registerPusher: (registration) async {
        events.add('pusher.register');
        registrations.add(registration);
      },
      removePusher: (_) async {
        expect(disposed, isFalse, reason: 'SDK must outlive pusher cleanup');
        events.add('pusher.remove.start');
        if (removalStarted?.isCompleted == false) removalStarted!.complete();
        await removalGate?.future;
        if (failRemoval) throw StateError('homeserver unreachable');
        events.add('pusher.remove.end');
      },
      onNavigate: onNavigate,
    );
  }

  @override
  Future<void> refreshRooms() async {
    refreshes++;
    await refreshGate?.future;
    if (refreshedRooms != null) roomList = refreshedRooms!;
  }

  @override
  Future<void> openRoom(String roomId) async {
    openedRooms.add(roomId);
    openedRoom = roomId;
    notifyListeners();
  }

  @override
  void closeRoom(String roomId) {
    if (openedRoom == roomId) openedRoom = null;
  }

  @override
  Future<void> logout() async {
    await cleanupBeforeLogout?.call();
    events.add('backend.logout');
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  @override
  Future<List<VerificationDevice>> ownDevices() async => const [];
  @override
  Future<CryptoStatus> cryptoStatus() async => const CryptoStatus(
    initialized: false,
    connected: false,
    keyBackupEnabled: false,
    crossSigningEnabled: false,
    setupAvailability: CryptoSetupAvailability.blocked,
  );

  @override
  void dispose() {
    disposed = true;
    events.add('backend.dispose');
    super.dispose();
  }
}

class _Drafts extends MessageDraftStore {
  @override
  Future<String> read(String accountKey, String roomId) async => '';
  @override
  Future<void> write(String accountKey, String roomId, String text) async {}
}

class _Harness {
  _Harness({bool builtIn = false}) {
    store = _Store(events);
    push = _Push(
      events,
      driver: driver,
      store: store,
      inAppDriver: inApp,
      configuration: builtIn
          ? const PushConfiguration.inApp()
          : const PushConfiguration(),
    );
    backend = _Backend(events)..cleanupBeforeLogout = push.logout;
  }
  final events = <String>[];
  final driver = FakePushDriver();
  final inApp = FakePushDriver();
  final preferences = AppearancePreferences();
  late final _Store store;
  late final _Push push;
  late final _Backend backend;

  Future<void> boot(
    WidgetTester tester, {
    bool ownedBackend = false,
    bool ownedPush = false,
    ChatBackend? legacyBackend,
    bool settle = true,
  }) async {
    // Phone window: these tests assert single-pane notification navigation.
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ParallaxApp(
        backend: ownedBackend ? null : legacyBackend ?? backend,
        backendFactory: ownedBackend
            ? ({required beforeLogout, required sendReadReceipts}) {
                backend.cleanupBeforeLogout = beforeLogout;
                backend.receiptsEnabled = sendReadReceipts;
                return backend;
              }
            : null,
        preferences: preferences,
        draftStore: _Drafts(),
        notifications: ownedPush ? null : push,
        notificationsFactory: ownedPush ? () => push : null,
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
      await _join(tester, push.settle);
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> enable(WidgetTester tester) async {
    await _join(tester, () async {
      await push.configure(configuration);
      await push.enable(consent: true);
    });
    await tester.pumpAndSettle();
    expect(push.active, isTrue);
  }

  void tapNotification() => driver.opened.add({
    'registration_id': backend.registrations.last.registrationId,
    'room_id': _roomId,
    'event_id': r'$push-event',
  });

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await _join(tester, () async {
      await push.settle();
      if (!push.disposed) await push.shutdown();
      await push.settle();
      if (!backend.disposed) backend.dispose();
      await driver.tokens.close();
      await driver.received.close();
      await driver.opened.close();
    });
    preferences.dispose();
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('startup revokes local binding before Matrix, without FCM', (
    tester,
  ) async {
    final h = _Harness();
    h.store.value = 'previous-process binding';
    await h.boot(tester);
    expect(h.events.take(2), ['store.clear', 'backend.initialize']);
    expect(h.store.value, isNull);
    expect(h.push.hasSession, isTrue);
    expect(h.backend.sessionCreations, 1);
    expect(h.driver.initializations, 0);
    expect(h.driver.permissions, 0);
    expect(h.driver.tokenReads, 0);
    await _join(tester, () => h.push.enable(consent: true));
    expect(h.push.status, PushStatus.configurationRequired);
    expect(h.driver.initializations, 0);
    expect(h.backend.registrations, isEmpty);
    await h.close(tester);
  });

  testWidgets('built-in notifications start after sign-in with no opt-in', (
    tester,
  ) async {
    final h = _Harness(builtIn: true);
    await h.boot(tester);
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(h.push.active, isTrue);
    expect(h.inApp.permissions, 1);
    expect(h.inApp.tokenReads, 1);
    expect(h.backend.registrations, isEmpty);
    expect(h.driver.initializations, 0);
    await h.close(tester);
    expect(h.inApp.deactivations, 1);
  });

  testWidgets('settings reaches the shared push owner with a legacy backend', (
    tester,
  ) async {
    final h = _Harness();
    await h.boot(tester, legacyBackend: _LegacyReadyBackend());
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final notifications = find.byKey(const ValueKey('settings.notifications'));
    await tester.ensureVisible(notifications);
    await tester.tap(notifications);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable notifications on this device'));
    await tester.pumpAndSettle();
    expect(find.byType(PushSettingsScreen), findsOneWidget);
    final screen = tester.widget<PushSettingsScreen>(
      find.byType(PushSettingsScreen),
    );
    expect(screen.notifications, same(h.push));
    expect(h.push.hasSession, isFalse);
    expect(h.driver.initializations, 0);
    await tester.pumpWidget(const SizedBox());
    await _join(tester, h.push.settle);
    expect(h.push.disposed, isFalse);
    expect(h.push.shutdowns, 0);
    await h.close(tester);
  });

  testWidgets(
    'startup completes before session creation and binds once per key',
    (tester) async {
      final h = _Harness();
      h.backend.initializationGate = Completer<void>();
      await h.boot(tester, settle: false);
      await tester.pump();
      h.backend.notifyListeners();
      await tester.pump();
      expect(h.backend.sessionCreations, 0);
      h.backend.initializationGate!.complete();
      await tester.pumpAndSettle();
      await h.enable(tester);
      final boundCount = h.push.bound.length;
      for (var i = 0; i < 4; i++) {
        h.backend.notifyListeners();
        await tester.pump();
      }
      expect(h.backend.sessionCreations, 1);
      expect(h.push.bound.length, boundCount);
      expect(h.push.active, isTrue, reason: 'sync must not revoke consent');
      h.backend.loginGeneration++;
      h.backend.notifyListeners();
      await _join(tester, h.push.settle);
      await tester.pumpAndSettle();
      expect(h.backend.sessionCreations, 2);
      expect(h.push.active, isFalse);
      expect(h.push.hasSession, isTrue);
      await h.close(tester);
    },
  );

  testWidgets(
    'valid tap dispatches a room without waiting for route lifetime',
    (tester) async {
      final h = _Harness();
      h.backend.roomList = [_joined];
      await h.boot(tester);
      await h.enable(tester);
      h.tapNotification();
      await _join(tester, h.push.settle);
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(h.backend.openedRooms, [_roomId]);
      expect(h.backend.refreshes, 0);
      expect(
        FeatureSettingsScope.maybeOf(
          tester.element(find.byType(RoomScreen)),
        )?.notifications,
        same(h.push),
      );
      await _join(tester, h.backend.logout);
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen, skipOffstage: false), findsNothing);
      expect(
        h.events.indexOf('pusher.remove.end'),
        lessThan(h.events.indexOf('backend.logout')),
      );
      expect(tester.takeException(), isNull);
      await h.close(tester);
    },
  );

  testWidgets('notification from an open room backs out to the inbox', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.roomList = [_previousRoom, _joined];
    await h.boot(tester);
    await h.enable(tester);
    await tester.tap(find.text('Previous room'));
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(h.backend.openedRooms, [_previousRoomId]);

    h.tapNotification();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(h.backend.openedRooms, [_previousRoomId, _roomId]);
    expect(h.backend.activeRoomId, _roomId);

    await tester.tap(find.byTooltip('Back to rooms'));
    await tester.pumpAndSettle();
    expect(find.byType(InboxScreen), findsOneWidget);
    expect(find.byType(RoomScreen, skipOffstage: false), findsNothing);
    expect(h.backend.activeRoomId, isNull);
    await h.close(tester);
  });

  testWidgets('notification for the open room keeps its timeline active', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.roomList = [_joined];
    await h.boot(tester);
    await h.enable(tester);
    await tester.tap(find.text('Notification room'));
    await tester.pumpAndSettle();
    expect(h.backend.activeRoomId, _roomId);

    h.tapNotification();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(h.backend.activeRoomId, _roomId);

    await tester.tap(find.byTooltip('Back to rooms'));
    await tester.pumpAndSettle();
    expect(find.byType(InboxScreen), findsOneWidget);
    expect(h.backend.activeRoomId, isNull);
    await h.close(tester);
  });

  testWidgets('missing joined room refreshes safely before dispatch', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.refreshedRooms = [_joined];
    await h.boot(tester);
    await h.enable(tester);
    h.tapNotification();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(h.backend.refreshes, 1);
    expect(h.backend.openedRooms, [_roomId]);
    await h.close(tester);
  });

  for (final change in [
    'account',
    'device',
    'same-account login',
    'silent account',
  ]) {
    testWidgets('tap paused in room refresh rejects stale $change', (
      tester,
    ) async {
      final h = _Harness();
      h.backend.refreshGate = Completer<void>();
      await h.boot(tester);
      await h.enable(tester);
      h.tapNotification();
      await tester.pump();
      expect(h.backend.refreshes, 1);
      if (change.contains('account') && change != 'same-account login') {
        h.backend.user = '@bob:example.org';
      } else if (change == 'device') {
        h.backend.device = 'REPLACEMENT';
      } else {
        h.backend.loginGeneration++;
      }
      if (change != 'silent account') h.backend.notifyListeners();
      h.backend.roomList = [_joined];
      h.backend.refreshGate!.complete();
      await _join(tester, h.push.settle);
      await tester.pumpAndSettle();
      expect(h.backend.openedRooms, isEmpty);
      expect(find.byType(RoomScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await h.close(tester);
    });
  }

  testWidgets(
    'push cancellation during refresh rejects an otherwise valid tap',
    (tester) async {
      final h = _Harness();
      h.backend.refreshGate = Completer<void>();
      await h.boot(tester);
      await h.enable(tester);
      h.tapNotification();
      await tester.pump();
      final disabling = h.push.disable();
      h.backend.roomList = [_joined];
      h.backend.refreshGate!.complete();
      await _join(tester, () => disabling);
      await tester.pumpAndSettle();
      expect(h.backend.openedRooms, isEmpty);
      expect(find.byType(RoomScreen), findsNothing);
      await h.close(tester);
    },
  );

  testWidgets('unmount during room lookup prevents late navigation', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.refreshGate = Completer<void>();
    await h.boot(tester, ownedPush: true, ownedBackend: true);
    await h.enable(tester);
    h.tapNotification();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(h.backend.disposed, isFalse);
    h.backend.roomList = [_joined];
    h.backend.refreshGate!.complete();
    await _join(tester, h.push.settle);
    await tester.pump();
    expect(h.backend.openedRooms, isEmpty);
    expect(h.backend.disposed, isTrue);
    expect(tester.takeException(), isNull);
    await h.close(tester);
  });

  testWidgets('invited or unknown room never joins or opens from a push', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.roomList = [
      const ChatRoom(
        id: _roomId,
        name: 'Invitation',
        preview: '',
        lastActivity: null,
        invited: true,
      ),
    ];
    await h.boot(tester);
    await h.enable(tester);
    h.tapNotification();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(h.backend.refreshes, 1);
    expect(h.backend.openedRooms, isEmpty);
    expect(find.textContaining('not joined or is unavailable'), findsOneWidget);
    await h.close(tester);
  });

  testWidgets('push storage failure stays visible without blocking messaging', (
    tester,
  ) async {
    final h = _Harness();
    h.store.failDeletion = true;
    await h.boot(tester);
    expect(h.backend.initializations, 1);
    expect(find.byType(InboxScreen), findsOneWidget);
    expect(find.textContaining('local notification storage'), findsOneWidget);
    expect(h.push.hasSession, isFalse);
    expect(h.driver.initializations, 0);
    expect(tester.takeException(), isNull);
    h.store.failDeletion = false;
    await tester.tap(find.text('Retry notifications'));
    await tester.pumpAndSettle();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(h.push.hasSession, isTrue);
    expect(find.textContaining('local notification storage'), findsNothing);
    expect(h.backend.initializations, 1);
    await h.close(tester);
  });

  testWidgets(
    'hung local revocation times out visibly and retries the same write',
    (tester) async {
      final h = _Harness();
      h.store.deletionGate = Completer<void>();
      await h.boot(tester, settle: false);
      await tester.pump();
      expect(h.backend.initializations, 0);
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(h.backend.initializations, 1);
      expect(find.textContaining('local notification storage'), findsOneWidget);
      await tester.tap(find.text('Retry notifications'));
      await tester.pump();
      expect(h.store.deletions, 1);
      h.store.deletionGate!.complete();
      await _join(tester, h.push.settle);
      await tester.pumpAndSettle();
      expect(h.push.hasSession, isTrue);
      expect(h.store.deletions, 1);
      expect(h.driver.initializations, 0);
      await h.close(tester);
    },
  );

  testWidgets('backend startup throw cannot leave the loading screen hung', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.status = SessionStatus.loading;
    h.backend.failInitialization = true;
    await h.boot(tester);
    expect(find.text('Couldn’t start Parallax'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    h.backend.failInitialization = false;
    h.backend.status = SessionStatus.ready;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byType(InboxScreen), findsOneWidget);
    expect(h.backend.initializations, 2);
    expect(h.push.hasSession, isTrue);
    await h.close(tester);
  });

  testWidgets('session cleanup failure is visible and explicitly retryable', (
    tester,
  ) async {
    final h = _Harness();
    await h.boot(tester);
    await h.enable(tester);
    h.backend.failRemoval = true;
    h.backend.loginGeneration++;
    h.backend.notifyListeners();
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(find.textContaining('Push cleanup failed.'), findsOneWidget);
    expect(h.push.active, isFalse);
    expect(tester.takeException(), isNull);
    h.backend.failRemoval = false;
    await tester.tap(find.text('Retry notifications'));
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(find.textContaining('Push cleanup failed.'), findsNothing);
    expect(h.push.hasSession, isTrue);
    await h.close(tester);
  });

  testWidgets('failed session creation does not silently lose its error', (
    tester,
  ) async {
    final h = _Harness();
    h.backend.failSessionCreation = true;
    await h.boot(tester);
    expect(h.push.hasSession, isFalse);
    expect(find.textContaining('Push cleanup failed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    h.backend.failSessionCreation = false;
    await tester.tap(find.text('Retry notifications'));
    await _join(tester, h.push.settle);
    await tester.pumpAndSettle();
    expect(h.push.hasSession, isTrue);
    await h.close(tester);
  });

  for (final ownedPush in [true, false]) {
    testWidgets(
      'owned backend outlives joined ${ownedPush ? 'owned' : 'borrowed'} push cleanup',
      (tester) async {
        final h = _Harness();
        await h.boot(tester, ownedBackend: true, ownedPush: ownedPush);
        expect(h.backend.receiptsEnabled?.call(), isTrue);
        await h.preferences.setSendReadReceipts(false);
        expect(h.backend.receiptsEnabled?.call(), isFalse);
        await h.enable(tester);
        h.backend.removalGate = Completer<void>();
        h.backend.removalStarted = Completer<void>();
        await tester.pumpWidget(const SizedBox());
        await _join(tester, () => h.backend.removalStarted!.future);
        expect(h.events, contains('pusher.remove.start'));
        expect(h.backend.disposed, isFalse);
        expect(h.push.enabled, isFalse);
        h.backend.removalGate!.complete();
        await _join(tester, h.push.settle);
        await tester.pump();
        expect(h.backend.disposed, isTrue);
        expect(
          h.events.indexOf('pusher.remove.end'),
          lessThan(h.events.indexOf('backend.dispose')),
        );
        expect(h.push.disposed, ownedPush);
        expect(h.push.shutdowns, ownedPush ? 1 : 0);
        if (ownedPush) {
          expect(
            h.events.indexOf('push.shutdown.end'),
            lessThan(h.events.indexOf('backend.dispose')),
          );
        }
        expect(tester.takeException(), isNull);
        await h.close(tester);
      },
    );
  }

  for (final stage in ['push storage', 'Matrix initialization']) {
    testWidgets('dispose cancels $stage deadline without abandoning its work', (
      tester,
    ) async {
      final h = _Harness();
      if (stage == 'push storage') {
        h.store.deletionGate = Completer<void>();
      } else {
        h.backend.initializationGate = Completer<void>();
      }
      await h.boot(tester, ownedPush: true, ownedBackend: true, settle: false);
      await tester.pump();
      await tester.pump();
      expect(h.store.deletions, 1);
      expect(h.backend.initializations, stage == 'push storage' ? 0 : 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        h.backend.disposed,
        isFalse,
        reason: 'the original uncancellable operation still owns the SDK',
      );
      // Intentionally leave this fake I/O blocked through the invariant check:
      // completing it here would conceal a leaked Future.timeout timer. There
      // are no native resources; joined teardown correctly remains suspended.
      await h.driver.tokens.close();
      await h.driver.received.close();
      await h.driver.opened.close();
      h.preferences.dispose();
    });
  }

  testWidgets('widget rebuild cannot transfer injected resource ownership', (
    tester,
  ) async {
    final h = _Harness();
    await h.boot(tester);
    await tester.pumpWidget(const ParallaxApp());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await _join(tester, h.push.settle);
    expect(h.backend.disposed, isFalse);
    expect(h.push.disposed, isFalse);
    expect(h.push.shutdowns, 0);
    // The original injected preferences also remain caller-owned and usable.
    await h.preferences.setCompact(true);
    await h.close(tester);
  });

  testWidgets('app never disposes an injected backend or push owner', (
    tester,
  ) async {
    final h = _Harness();
    await h.boot(tester);
    await h.enable(tester);
    await tester.pumpWidget(const SizedBox());
    await _join(tester, h.push.settle);
    await tester.pump();
    expect(h.backend.disposed, isFalse);
    expect(h.push.disposed, isFalse);
    expect(h.push.hasSession, isFalse);
    expect(h.push.shutdowns, 0);
    await h.close(tester);
  });
}

class _LegacyReadyBackend extends FakeBackend {
  @override
  SessionStatus get connection => SessionStatus.ready;
}
