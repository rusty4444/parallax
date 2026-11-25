import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_features.dart';
import 'package:parallax/features/notifications/notification_hooks.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notification_settings_section.dart';
import 'package:parallax/features/notifications/notification_store.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/push_notifications.dart';

import 'notifications_fakes.dart';
import 'widget_test.dart' show FakeBackend;

class _Backend extends FakeBackend implements NotificationFeatures {
  _Backend() {
    currentUserId = '@me:example.org';
  }
  @override
  String? get deviceId => 'DEVICE';
  @override
  Stream<SyncedNotification> get syncNotifications => const Stream.empty();
  @override
  Future<ResolvedPushEvent?> resolvePush(
    PushEnvelope envelope,
    NotificationPreferences preferences, {
    Directory? cacheRoot,
  }) async => null;
  @override
  Future<void> sendQuickReply(String roomId, String text) async {}

  @override
  Future<void> markReadUpTo(
    String roomId,
    String eventId, {
    required bool publicReceipt,
    required DateTime pressedAt,
  }) async {}
}

void main() {
  late MemoryNotificationStore store;
  late FakeSurface surface;
  late _Backend backend;

  setUp(() {
    store = MemoryNotificationStore();
    surface = FakeSurface();
    backend = _Backend();
  });

  Future<void> pump(
    WidgetTester tester, {
    Future<NotificationStore> Function()? open,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              NotificationContentSection(
                palette: paletteFor(defaultVisualTheme),
                backend: backend,
                openStore: open ?? () async => store,
                surface: () => surface,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  SwitchListTile tile(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

  testWidgets('both toggles default on and persist', (tester) async {
    await pump(tester);
    expect(tile(tester, 'notifications.showContent').value, isTrue);
    expect(tile(tester, 'notifications.showMedia').value, isTrue);
    await tester.tap(find.text('Show media previews in notifications'));
    await tester.pump();
    expect(store.preferences.showMediaPreviews, isFalse);
    expect(store.preferences.showContent, isTrue);
    expect(tile(tester, 'notifications.showMedia').value, isFalse);
  });

  testWidgets('turning content off disables media and clears rich '
      'notifications', (tester) async {
    store.rooms['!room:example.org'] = RoomNotificationThread(
      roomId: '!room:example.org',
      roomName: 'Book club',
      isDirect: false,
      lines: [
        NotificationLine(
          eventId: r'$e',
          senderId: '@alice:example.org',
          senderName: 'Alice',
          text: 'secret plans',
          timestamp: DateTime(2026, 11, 12),
        ),
      ],
    );
    await pump(tester);
    await tester.tap(find.text('Show message content'));
    await tester.pump();
    await tester.pump();
    expect(store.preferences.showContent, isFalse);
    expect(tile(tester, 'notifications.showMedia').onChanged, isNull);
    expect(tile(tester, 'notifications.showMedia').value, isFalse);
    expect(
      surface.cancelled,
      contains(roomNotificationId('!room:example.org')),
    );
    expect(surface.cancelled, contains(notificationSummaryId));
    expect(store.rooms, isEmpty);
  });

  testWidgets('a failed save reverts and explains', (tester) async {
    store.failWrites = true;
    await pump(tester);
    await tester.tap(find.text('Show message content'));
    await tester.pump();
    await tester.pump();
    expect(tile(tester, 'notifications.showContent').value, isTrue);
    expect(find.text('Couldn’t save notification settings.'), findsOneWidget);
  });

  testWidgets('an unavailable store keeps the toggles off-limits', (
    tester,
  ) async {
    await pump(tester, open: () async => throw const FileSystemException('x'));
    expect(tile(tester, 'notifications.showContent').onChanged, isNull);
    expect(
      find.text('Notification settings are unavailable on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('the settings hook adds rows to the Notifications group', (
    tester,
  ) async {
    late List<Widget> sections;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            sections = notificationSettingsRows(
              context,
              SettingsHookContext(
                backend: backend,
                palette: paletteFor(defaultVisualTheme),
              ),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(sections.first, isA<NotificationContentSection>());
    // The troubleshooting row follows the content section.
    expect(sections.length, 2);
  });

  test('preferences JSON tolerates junk', () {
    expect(
      NotificationPreferences.fromJson({'show_content': 'yes'}),
      const NotificationPreferences(),
    );
    expect(
      NotificationPreferences.fromJson(
        const NotificationPreferences(
          showContent: false,
          showMediaPreviews: false,
        ).toJson(),
      ),
      const NotificationPreferences(
        showContent: false,
        showMediaPreviews: false,
      ),
    );
    expect(NotifiableEventKind.values, hasLength(3));
  });
}
