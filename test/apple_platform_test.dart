// Apple (iOS/macOS) platform behaviour: built-in notification delivery,
// Darwin notification rendering and the notification settings screen.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/platform/background_connection.dart';
import 'package:parallax/push_notifications.dart';
import 'package:parallax/push_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeConnection implements BackgroundConnectionPlatform {
  @override
  Future<bool> start() async => false;
  @override
  Future<void> stop() async {}
  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;
  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => false;
}

class _FakeDriver implements PushDriver {
  @override
  Future<void> initialize(PushConfiguration configuration) async {}
  @override
  Future<PushPermission> requestPermission() async => PushPermission.authorized;
  @override
  Future<String?> getToken() async => inAppPushToken;
  @override
  Stream<String> get tokenChanges => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get messages => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get openedMessages => const Stream.empty();
  @override
  Future<void> showNotification(PushEnvelope envelope) async {}
  @override
  Future<void> deactivate() async {}
}

class _FakeStore implements PushStateStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? value) async => this.value = value;
}

NotificationLine _line(String text, {bool highlight = false}) =>
    NotificationLine(
      eventId: r'$event:example.org',
      senderId: '@mia:example.org',
      senderName: 'Mia',
      text: text,
      timestamp: DateTime(2026, 11, 19, 10),
      highlight: highlight,
    );

RoomNotificationThread _thread(NotificationLine line) => RoomNotificationThread(
  roomId: '!room:example.org',
  roomName: 'Room',
  isDirect: false,
  lines: [line],
  latestEventId: line.eventId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('built-in delivery on Apple platforms', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              'initialize' => true,
              'requestPermissions' => true,
              'areNotificationsEnabled' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      test('initialises and asks permission on $platform', () async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          if (platform == TargetPlatform.iOS) {
            IOSFlutterLocalNotificationsPlugin.registerWith();
          } else {
            MacOSFlutterLocalNotificationsPlugin.registerWith();
          }
          final driver = InAppPushDriver(platform: _FakeConnection());
          // Before the Apple port this threw UnsupportedError off Android.
          await driver.initialize(const PushConfiguration.inApp());
          expect(calls.where((c) => c.method == 'initialize'), isNotEmpty);
          expect(await driver.requestPermission(), PushPermission.authorized);
          expect(
            calls.where((c) => c.method == 'requestPermissions'),
            isNotEmpty,
          );
          // No foreground service off Android: notifications arrive while the
          // app runs, and the driver reports that honestly.
          expect(await driver.getToken(), inAppPushToken);
          expect(driver.connected, isFalse);
          await driver.deactivate();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    test('Android keeps the foreground-service behaviour', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        final connection = _FakeConnection();
        final driver = InAppPushDriver(platform: connection);
        await driver.initialize(const PushConfiguration.inApp());
        expect(await driver.requestPermission(), PushPermission.authorized);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Darwin notification rendering', () {
    RenderedNotification render(String text, {bool highlight = false}) =>
        renderRoomThread(
          _thread(_line(text, highlight: highlight)),
          myUserId: '@me:example.org',
          registrationId: 'reg-1',
          fileExists: (_) => false,
        );

    test('room notifications carry iOS and macOS details', () {
      final rendered = render('hello there');
      final ios = rendered.details.iOS;
      final macos = rendered.details.macOS;
      expect(ios, isNotNull);
      expect(macos, isNotNull);
      expect(ios!.categoryIdentifier, darwinMessageCategory);
      expect(ios.threadIdentifier, '!room:example.org');
      expect(macos!.categoryIdentifier, darwinMessageCategory);
      // Android rendering is unchanged.
      expect(rendered.details.android, isNotNull);
    });

    test('a one-time code picks the copy-code category', () {
      final rendered = render('Your verification code is 482913');
      expect(rendered.details.iOS!.categoryIdentifier, darwinCopyCodeCategory);
    });

    test('a phone number picks the copy-phone category', () {
      final rendered = render('Call me on +61 400 000 000');
      expect(rendered.details.iOS!.categoryIdentifier, darwinCopyPhoneCategory);
    });

    test('mentions interrupt; plain messages do not', () {
      expect(
        render('hi', highlight: true).details.iOS!.interruptionLevel,
        InterruptionLevel.timeSensitive,
      );
      expect(
        render('hi').details.iOS!.interruptionLevel,
        InterruptionLevel.active,
      );
    });

    test('calls, invites and the summary use their categories', () {
      final event = ResolvedPushEvent(
        roomId: '!room:example.org',
        eventId: r'$event:example.org',
        kind: NotifiableEventKind.call,
        roomName: 'Room',
        isDirect: true,
        line: _line('Incoming call'),
      );
      expect(
        renderCall(
          event,
          registrationId: 'reg-1',
        ).details.iOS!.categoryIdentifier,
        darwinCallCategory,
      );
      expect(
        renderInvite(
          event,
          registrationId: 'reg-1',
        ).details.iOS!.categoryIdentifier,
        darwinInviteCategory,
      );
      expect(
        renderSummary([_thread(_line('hi'))]).details.iOS!.threadIdentifier,
        'parallax.summary',
      );
    });

    test('categories register reply and mark-as-read actions', () {
      final message = darwinNotificationCategories.firstWhere(
        (c) => c.identifier == darwinMessageCategory,
      );
      expect(
        message.actions.map((a) => a.identifier),
        containsAll([pushReplyActionId, pushMarkReadActionId]),
      );
      final reply = message.actions.firstWhere(
        (a) => a.identifier == pushReplyActionId,
      );
      // Only the text-input action carries a send button title.
      expect(reply.buttonTitle, 'Send');
    });
  });

  group('notification settings on Apple platforms', () {
    late PushNotifications push;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      push = PushNotifications(
        driver: _FakeDriver(),
        inAppDriver: _FakeDriver(),
        store: _FakeStore(),
        configuration: const PushConfiguration.inApp(),
      );
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await push.shutdown();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PushSettingsScreen(
            notifications: push,
            connection: _FakeConnection(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('iOS hides the Android-only delivery choices', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        IOSFlutterLocalNotificationsPlugin.registerWith();
        await pump(tester);
        expect(find.byType(SegmentedButton<PushProvider>), findsNothing);
        expect(find.textContaining('Built-in connection'), findsOneWidget);
        expect(find.byKey(const ValueKey('push.enable')), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Android keeps the delivery choices', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        await pump(tester);
        expect(find.byType(SegmentedButton<PushProvider>), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
