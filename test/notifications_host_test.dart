import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_features.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notifications_host.dart';
import 'package:parallax/features/notifications/push_handoff.dart';
import 'package:parallax/features/notifications/rich_push_handler.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/push_notifications.dart';

import 'notifications_fakes.dart';
import 'widget_test.dart' show FakeBackend;

const _room = '!room:example.org';

class _Backend extends FakeBackend implements NotificationFeatures {
  _Backend() {
    currentUserId = '@me:example.org';
  }

  SessionStatus status = SessionStatus.ready;
  final replies = <(String, String)>[];
  Object? replyError;

  @override
  SessionStatus get connection => status;

  @override
  String? get deviceId => 'DEVICE';

  @override
  Future<ResolvedPushEvent?> resolvePush(
    PushEnvelope envelope,
    NotificationPreferences preferences, {
    Directory? cacheRoot,
  }) async => ResolvedPushEvent(
    roomId: envelope.roomId,
    eventId: envelope.eventId!,
    kind: NotifiableEventKind.message,
    roomName: 'Book club',
    isDirect: false,
    line: NotificationLine(
      eventId: envelope.eventId!,
      senderId: '@alice:example.org',
      senderName: 'Alice',
      text: 'Live client says hi',
      timestamp: DateTime(2026, 11, 12, 9),
    ),
  );

  @override
  Future<void> sendQuickReply(String roomId, String text) async {
    if (replyError != null) throw replyError!;
    replies.add((roomId, text));
  }

  void setRooms(List<ChatRoom> rooms) {
    roomList = rooms;
    notifyListeners();
  }
}

class _Driver implements PushDriver {
  final tokens = StreamController<String>.broadcast(sync: true);
  final received = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final opened = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final shown = <PushEnvelope>[];
  @override
  Stream<String> get tokenChanges => tokens.stream;
  @override
  Stream<Map<String, dynamic>> get messages => received.stream;
  @override
  Stream<Map<String, dynamic>> get openedMessages => opened.stream;
  @override
  Future<void> initialize(PushConfiguration configuration) async {}
  @override
  Future<PushPermission> requestPermission() async => PushPermission.authorized;
  @override
  Future<String?> getToken() async => 'token-a';
  @override
  Future<void> showNotification(PushEnvelope envelope) async =>
      shown.add(envelope);
  @override
  Future<void> deactivate() async {}
}

class _PushStore implements PushStateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

final _configuration = PushConfiguration(
  gatewayUrl: Uri.parse('https://gw.example.org/_matrix/push/v1/notify'),
  appId: 'org.example.parallax',
  firebaseOptions: const FirebaseOptions(
    apiKey: 'client-identifier',
    appId: '1:123456:android:abcdef',
    messagingSenderId: '123456',
    projectId: 'project',
  ),
);

ChatRoom _chatRoom(int unread) => ChatRoom(
  id: _room,
  name: 'Book club',
  preview: '',
  lastActivity: DateTime(2026, 11, 12),
  unread: unread,
);

void main() {
  late _Backend backend;
  late MemoryNotificationStore store;
  late FakeSurface surface;
  late FakeDirectory directory;

  setUp(() {
    backend = _Backend();
    store = MemoryNotificationStore();
    surface = FakeSurface();
    directory = FakeDirectory();
  });

  Future<void> pumpHost(WidgetTester tester, {PushNotifications? push}) =>
      tester.pumpWidget(
        FeatureSettingsScope(
          preferences: AppearancePreferences(),
          draftStore: MessageDraftStore(),
          notifications: push,
          child: NotificationsHost(
            app: AppHookContext(
              backend: backend,
              palette: paletteFor(defaultVisualTheme),
              navigatorKey: GlobalKey<NavigatorState>(),
            ),
            environment: NotificationHostEnvironment(
              store: () async => store,
              surface: () => surface,
              cacheRoot: () async => Directory('unused-cache'),
              directory: directory,
            ),
            child: const SizedBox(),
          ),
        ),
      );

  Future<(PushNotifications, _Driver, PushRegistration)> enabledPush() async {
    final driver = _Driver();
    final registrations = <PushRegistration>[];
    final push = PushNotifications(driver: driver, store: _PushStore());
    await push.configure(_configuration);
    await push.setSession(
      PushSession(
        userId: '@me:example.org',
        deviceId: 'DEVICE',
        registerPusher: (r) async => registrations.add(r),
        removePusher: (_) async {},
        onNavigate: (_) async {},
      ),
    );
    await push.enable(consent: true);
    return (push, driver, registrations.single);
  }

  Map<String, Object?> payload(PushRegistration registration) => {
    'registration_id': registration.registrationId,
    'room_id': _room,
    'event_id': r'$event',
  };

  testWidgets('renders verified pushes with the live client', (tester) async {
    final (push, driver, registration) = await enabledPush();
    await pumpHost(tester, push: push);
    expect(push.richRenderer, isNotNull);
    driver.received.add(Map<String, dynamic>.from(payload(registration)));
    await tester.pump();
    await push.settle();
    await tester.pump();
    final shown = surface.byId(roomNotificationId(_room))!;
    expect(shown.body, 'Alice: Live client says hi');
    expect(driver.shown, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(push.richRenderer, isNull);
    // Still signed in: history is kept.
    expect(store.clears, 0);
    await tester.runAsync(push.shutdown);
  });

  testWidgets('opening or reading a room clears its notification', (
    tester,
  ) async {
    backend.roomList = [_chatRoom(2)];
    await pumpHost(tester);
    backend.activeId = _room;
    backend.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(surface.cancelled, contains(roomNotificationId(_room)));

    surface.cancelled.clear();
    backend.activeId = null;
    backend.setRooms([_chatRoom(3)]);
    await tester.pump();
    expect(surface.cancelled, isEmpty);
    backend.setRooms([_chatRoom(0)]);
    await tester.pump();
    await tester.pump();
    expect(surface.cancelled, contains(roomNotificationId(_room)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending quick replies are sent when the app opens', (
    tester,
  ) async {
    final now = DateTime.now();
    store.pending.addAll([
      PendingReply(
        userId: '@me:example.org',
        deviceId: 'DEVICE',
        roomId: _room,
        text: 'Sent late',
        createdAt: now,
      ),
      PendingReply(
        userId: '@me:example.org',
        deviceId: 'DEVICE',
        roomId: '!old:example.org',
        text: 'Too old',
        createdAt: now.subtract(const Duration(hours: 2)),
      ),
      PendingReply(
        userId: '@someone-else:example.org',
        deviceId: 'OTHER',
        roomId: _room,
        text: 'Not mine',
        createdAt: now,
      ),
    ]);
    await pumpHost(tester);
    await tester.pump();
    await tester.pump();
    expect(backend.replies, [(_room, 'Sent late')]);
    expect(
      surface.byId(roomNotificationId('!old:example.org'))!.body,
      quickReplyFailedLine,
    );
    expect(store.pending, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background hand-offs: verified pushes and replies', (
    tester,
  ) async {
    final (push, driver, registration) = await enabledPush();
    await pumpHost(tester, push: push);
    expect(directory.lookup(pushHandoffPortName), isNotNull);

    final pushed = await tester.runAsync(
      () => handOffToMainIsolate(
        handoffKindPush,
        payload(registration),
        directory: directory,
      ),
    );
    expect(pushed, HandoffResult.accepted);
    await tester.pump();
    await push.settle();
    await tester.pump();
    expect(surface.byId(roomNotificationId(_room))!.title, 'Book club');

    final results = await tester.runAsync(
      () async => [
        await handOffToMainIsolate(handoffKindReply, {
          ...payload(registration),
          'text': 'On my way',
        }, directory: directory),
        await handOffToMainIsolate(handoffKindReply, {
          ...payload(registration),
          'registration_id': 'S' * 32,
          'text': 'stale',
        }, directory: directory),
      ],
    );
    expect(results, [HandoffResult.accepted, HandoffResult.rejected]);
    await tester.pump();
    await tester.pump();
    expect(backend.replies, [(_room, 'On my way')]);
    final room = surface.byId(roomNotificationId(_room))!;
    final messages =
        (room.details.android!.styleInformation! as MessagingStyleInformation)
            .messages!;
    expect(messages.last.text, 'On my way');
    expect(messages.last.person!.name, 'Me');

    backend.replyError = StateError('recipients changed');
    final failed = await tester.runAsync(
      () => handOffToMainIsolate(handoffKindReply, {
        ...payload(registration),
        'text': 'second',
      }, directory: directory),
    );
    expect(failed, HandoffResult.accepted);
    await tester.pump();
    await tester.pump();
    final after =
        (surface
                    .byId(roomNotificationId(_room))!
                    .details
                    .android!
                    .styleInformation!
                as MessagingStyleInformation)
            .messages!;
    expect(after.last.text, quickReplyFailedLine);

    await tester.pumpWidget(const SizedBox());
    expect(directory.lookup(pushHandoffPortName), isNull);
    await tester.runAsync(push.shutdown);
  });

  testWidgets('signing out forgets notification history', (tester) async {
    await pumpHost(tester);
    backend.status = SessionStatus.signedOut;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(store.clears, 1);
  });

  testWidgets('non-Matrix backends leave the app untouched', (tester) async {
    final plain = FakeBackend();
    await tester.pumpWidget(
      NotificationsHost(
        app: AppHookContext(
          backend: plain,
          palette: paletteFor(defaultVisualTheme),
          navigatorKey: GlobalKey<NavigatorState>(),
        ),
        environment: NotificationHostEnvironment(
          store: () async => store,
          surface: () => surface,
          cacheRoot: () async => Directory('unused-cache'),
          directory: directory,
        ),
        child: const SizedBox(),
      ),
    );
    expect(notificationFeaturesOf(plain), isNull);
    expect(directory.ports, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test('IsolateNameServer directory registers and removes ports', () {
    const directory = IsolateNameServerDirectory();
    final port = ReceivePort();
    addTearDown(port.close);
    directory.remove('parallax.test.port');
    expect(directory.register(port.sendPort, 'parallax.test.port'), isTrue);
    expect(directory.lookup('parallax.test.port'), port.sendPort);
    expect(directory.remove('parallax.test.port'), isTrue);
  });
}
