import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/crypto_setup_screen.dart';
import 'package:parallax/directory_screen.dart';
import 'package:parallax/gallery_bubble.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/login_screen.dart';
import 'package:parallax/main.dart';
import 'package:parallax/message_search_screen.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/room_background_store.dart';
import 'package:parallax/room_details.dart';
import 'package:parallax/room_avatar.dart';
import 'package:parallax/settings_screen.dart';
import 'package:parallax/security_overlay.dart';
import 'home_options.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('login validates homeserver and sends credentials', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: LoginScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Enter the matrix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter the matrix'));
    await tester.pump();
    expect(find.text('Enter your username'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(1), '@sam:matrix.org');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await tester.ensureVisible(find.text('Enter the matrix'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter the matrix'));
    await tester.pump();
    expect(backend.lastLogin, '@sam:matrix.org');
    expect(backend.lastHomeserver, 'https://matrix.org');
  });

  testWidgets('unread filter shows only unread rooms', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!a:example.org',
          name: 'General',
          preview: 'Hi',
          lastActivity: DateTime(2026),
          unread: 3,
        ),
        ChatRoom(
          id: '!b:example.org',
          name: 'Quiet',
          preview: '',
          lastActivity: null,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    expect(find.text('Quiet'), findsOneWidget);
    await openHomeOptions(tester);
    await tester.tap(find.text('Unread'));
    await tester.pump();
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Quiet'), findsNothing);
  });

  testWidgets('room creation defaults to encryption and rejects blank names', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Create room'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tester.tap(find.text('Create'));
    await tester.pump();
    expect(backend.createdRoomName, isNull);
    expect(find.text('Create room'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '  Private group  ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(backend.createdRoomName, 'Private group');
    expect(backend.createdRoomEncrypted, isTrue);
    expect(backend.activeRoomId, '!created:example.org');
    expect(tester.takeException(), isNull);
  });

  testWidgets('room creation passes explicit unencrypted choice', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.tap(find.byTooltip('Create room'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(
      find.text('Private room without end-to-end encryption.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).last, 'Unencrypted group');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(backend.createdRoomName, 'Unencrypted group');
    expect(backend.createdRoomEncrypted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty inbox distinguishes syncing, failure, and a true empty account',
    (tester) async {
      final backend = FakeBackend()
        ..syncState = RoomSyncState.loading
        ..currentUserId = '@test:example.org';
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: InboxScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            style: VisualTheme.parallax,
            onThemeChanged: (_) {},
          ),
        ),
      );
      // The room count/sync pill is in the options menu.
      await openHomeOptions(tester);
      expect(find.text('SYNCING'), findsOneWidget);
      expect(find.text('No rooms found'), findsNothing);

      backend.setSync(RoomSyncState.error, RoomSyncIssue.network);
      await tester.pump();
      expect(find.text('SYNC ERROR'), findsOneWidget);
      expect(find.text('Couldn’t sync your rooms'), findsOneWidget);
      await tester.tap(find.text('Retry sync'));
      await tester.pump();
      expect(backend.refreshCount, 1);
      expect(find.text('SYNCING'), findsOneWidget);

      backend.setSync(RoomSyncState.ready);
      await tester.pump();
      expect(find.text('0 ROOMS'), findsOneWidget);
      expect(
        find.textContaining('Synced as @test:example.org'),
        findsOneWidget,
      );
      await tester.tap(find.text('Refresh rooms'));
      await tester.pump();
      expect(backend.refreshCount, 2);
    },
  );

  testWidgets('sync retry remains reachable on a compact display', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = FakeBackend()
      ..syncState = RoomSyncState.error
      ..syncIssue = RoomSyncIssue.homeserver;
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    expect(find.textContaining('homeserver rejected'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry sync'));
    await tester.tap(find.text('Retry sync'));
    await tester.pump();
    expect(backend.refreshCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invitation can be declined from the inbox', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!invite:example.org',
          name: 'Project invite',
          preview: '',
          lastActivity: null,
          invited: true,
        ),
        ChatRoom(
          id: '!joined:example.org',
          name: 'General',
          preview: '',
          lastActivity: null,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await openHomeOptions(tester);
    await tester.ensureVisible(find.text('Invites'));
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
    expect(find.text('General'), findsNothing);
    // Element X shows inline Accept/Decline; declining asks for confirmation.
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.declined, isNull);
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline invite'));
    await tester.pumpAndSettle();
    expect(backend.declined, '!invite:example.org');
    expect(find.text('You don’t have any pending invites'), findsOneWidget);
  });

  testWidgets('long-press marks a joined room unread and clears the flag', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..roomList = [
        const ChatRoom(
          id: '!joined:example.org',
          name: 'General',
          preview: '',
          lastActivity: null,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.longPress(find.text('General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as unread'));
    await tester.pumpAndSettle();
    expect(backend.lastRoomUnread, isTrue);
    expect(find.text('•'), findsOneWidget);

    await tester.longPress(find.text('General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as read'));
    await tester.pumpAndSettle();
    expect(backend.lastRoomUnread, isFalse);
  });

  testWidgets('leaving a joined room requires confirmation', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        const ChatRoom(
          id: '!joined:example.org',
          name: 'General',
          preview: '',
          lastActivity: null,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.longPress(find.text('General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave room'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.lastLeftRoom, isNull);

    await tester.longPress(find.text('General'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave room'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(backend.lastLeftRoom, '!joined:example.org');
    expect(find.text('General'), findsNothing);
  });

  testWidgets('public directory paginates and replaces search results', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: DirectoryScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First room'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Second room'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'kotlin');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Kotlin room'), findsOneWidget);
    expect(find.text('First room'), findsNothing);
  });

  testWidgets('message search waits for a query and shows joined-room hits', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: MessageSearchScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    expect(
      find.text('Type at least two characters to search.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Found it in a room'), findsOneWidget);
  });

  testWidgets('room sends text and shows an unavailable image fallback', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Photos',
          preview: '',
          lastActivity: null,
          encrypted: true,
        ),
      ]
      ..entries = [
        ChatEntry(
          id: r'$event',
          sender: '@friend:example.org',
          body: 'photo.jpg',
          time: DateTime(2026),
          mine: false,
          isImage: true,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: RoomBackgroundStore(
            root: Directory('build/test_background'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Encrypted room'), findsOneWidget);
    expect(find.text('Image unavailable'), findsOneWidget);
    expect(backend.imageLoads, 1);
    await tester.enterText(find.byType(TextField), 'Hello!');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(backend.lastMessage, 'Hello!');
  });

  testWidgets('failed send retains the draft for retry', (tester) async {
    final backend = FakeBackend()..failSend = true;
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this message');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(find.text('Keep this message'), findsOneWidget);
    expect(find.text('Message not sent. Try again.'), findsOneWidget);
  });

  testWidgets('long-press reply targets the selected Matrix event', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..entries = [
        ChatEntry(
          id: 'original',
          sender: '@meta_555000222:samprim.net',
          senderName: 'Meta',
          body: 'First message',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('First message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to Meta: First message'), findsOneWidget);
    expect(find.textContaining('Replying to @meta_'), findsNothing);
    await tester.enterText(find.byType(TextField), 'My reply');
    expect(backend.typingStates.last, isTrue);
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(backend.lastReplyId, 'original');
    expect(backend.lastMessage, 'My reply');
    expect(find.textContaining('Replying to Meta'), findsNothing);
    expect(backend.typingStates.last, isFalse);
  });

  testWidgets('incoming typing and reaction choices are visible', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..typingNames = ['Alice']
      ..entries = [
        ChatEntry(
          id: 'friend-message',
          sender: '@friend:example.org',
          body: 'Hi there',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alice typing…'), findsOneWidget);
    await tester.longPress(find.text('Hi there'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('React 👍'));
    await tester.pumpAndSettle();
    expect(backend.lastReaction, '👍');
  });

  testWidgets('double tap reacts to anyone\'s message with the chosen emoji', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = AppearancePreferences();
    addTearDown(preferences.dispose);
    await preferences.setQuickReaction('👍');
    final backend = FakeBackend()
      ..entries = [
        ChatEntry(
          id: 'theirs',
          sender: '@friend:example.org',
          senderName: 'Friend',
          body: 'From a friend',
          time: DateTime(2026, 1, 1, 10),
          mine: false,
        ),
        ChatEntry(
          id: 'mine',
          sender: '@me:example.org',
          body: 'From me',
          time: DateTime(2026, 1, 1, 9),
          mine: true,
        ),
      ];
    await tester.pumpWidget(
      FeatureSettingsScope(
        preferences: preferences,
        draftStore: MessageDraftStore(),
        child: MaterialApp(
          home: RoomScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            roomId: '!r:example.org',
            backgroundStore: FakeBackgroundStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in ['From a friend', 'From me']) {
      backend.lastReaction = null;
      await tester.tap(find.text(text));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text(text));
      await tester.pump(const Duration(milliseconds: 100));
      // The reaction pops over the message before the server answers.
      expect(find.byKey(const ValueKey('double-tap-pop')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(backend.lastReaction, '👍', reason: text);
      expect(find.byKey(const ValueKey('double-tap-pop')), findsNothing);
    }
  });

  testWidgets('people\'s pictures show beside their messages in DMs too', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Friend',
          preview: '',
          lastActivity: null,
          isDirect: true,
        ),
      ]
      // Oldest first, as the backend projects them.
      ..entries = [
        ChatEntry(
          id: 'first',
          sender: '@friend:example.org',
          senderName: 'Friend',
          body: 'First',
          time: DateTime(2026, 1, 1, 10),
          mine: false,
        ),
        ChatEntry(
          id: 'second',
          sender: '@friend:example.org',
          senderName: 'Friend',
          body: 'Second',
          time: DateTime(2026, 1, 1, 10, 1),
          mine: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // One picture starts the run of messages; the name stays hidden in DMs.
    expect(find.byKey(const ValueKey('avatar-first')), findsOneWidget);
    expect(find.byKey(const ValueKey('avatar-second')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('avatar-first'))).dx,
      lessThan(tester.getTopLeft(find.text('First')).dx),
    );
  });

  testWidgets('reaction count is visible and can be toggled', (tester) async {
    final backend = FakeBackend()
      ..entries = [
        ChatEntry(
          id: 'reacted-message',
          sender: '@friend:example.org',
          body: 'Reacted',
          time: DateTime(2026),
          mine: false,
          reactions: const [ChatReaction(emoji: '❤️', count: 2, mine: true)],
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('❤️ 2'), findsOneWidget);
    await tester.tap(find.text('❤️ 2'));
    await tester.pumpAndSettle();
    expect(backend.lastReaction, '❤️');
  });

  testWidgets('own message can be edited or deleted after confirmation', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..entries = [
        ChatEntry(
          id: r'$mine',
          sender: '@me:example.org',
          body: 'Old text',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Old text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'New text');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(backend.lastEditId, r'$mine');
    expect(backend.lastMessage, 'New text');

    await tester.longPress(find.text('Old text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete message'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.lastRedactedId, isNull);
    await tester.longPress(find.text('Old text'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete message'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Delete message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(backend.lastRedactedId, r'$mine');
  });

  testWidgets('failed local message offers a local discard action', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..entries = [
        ChatEntry(
          id: 'txn-failed',
          sender: '@me:example.org',
          body: 'Failed last night',
          time: DateTime(2026),
          mine: true,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Failed last night'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Discard unsent message'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Discard unsent message'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsent message?'), findsOneWidget);
    expect(find.textContaining('only from this device'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pump();
    expect(backend.lastRedactedId, 'txn-failed');
  });

  testWidgets('file attachment has a save action and composer picker', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Files',
          preview: '',
          lastActivity: null,
        ),
      ]
      ..entries = [
        ChatEntry(
          id: 'file-1',
          sender: '@a:server',
          body: 'report.pdf',
          time: DateTime(2026),
          mine: false,
          isAttachment: true,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: RoomBackgroundStore(
            root: Directory('build/test_background'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.byTooltip('Attach file'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });

  testWidgets('consecutive photos render as one gallery', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Photos',
          preview: '',
          lastActivity: null,
        ),
      ]
      ..entries = [
        for (var i = 0; i < 3; i++)
          ChatEntry(
            id: 'image-$i',
            sender: '@friend:example.org',
            body: 'image.jpg',
            time: DateTime(2026, 10, 20, 12, i),
            mine: false,
            isImage: true,
          ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: RoomBackgroundStore(
            root: Directory('build/test_background'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GalleryBubble), findsOneWidget);
    expect(backend.imageLoads, 3);
  });

  testWidgets('room background menu clears only the selected room', (
    tester,
  ) async {
    final store = FakeBackgroundStore();
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Photos',
          preview: '',
          lastActivity: null,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Room background'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove background'));
    await tester.pumpAndSettle();
    expect(store.cleared, ['!r:example.org']);
    expect(store.rooms.containsKey('!other:example.org'), isTrue);
  });

  testWidgets('group avatars request visible hero images only', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        ChatRoom(
          id: '!r:example.org',
          name: 'Team',
          preview: 'Hi',
          lastActivity: null,
          heroes: [
            ChatAvatar(name: 'Alice', url: Uri.parse('mxc://s/a')),
            ChatAvatar(name: 'Bob', url: Uri.parse('mxc://s/b')),
            ChatAvatar(name: 'Carol', url: Uri.parse('mxc://s/c')),
            ChatAvatar(name: 'Dan', url: Uri.parse('mxc://s/d')),
          ],
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: InboxScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RoomAvatar), findsOneWidget);
    expect(backend.avatarLoads, 4);
  });

  testWidgets('recovery uses an obscured field and refreshes identity', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Enter recovery key'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter recovery key'));
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(find.byType(TextField).last);
    expect(input.obscureText, isTrue);
    await tester.enterText(
      find.byType(TextField).last,
      '  synthetic-test-recovery-key  ',
    );
    await tester.tap(find.text('Restore').last);
    await tester.pumpAndSettle();
    expect(backend.lastRecoveryKey, '  synthetic-test-recovery-key  ');
    expect(find.text('Identity connected on this device'), findsOneWidget);
  });

  testWidgets('the other-devices list is collapsed until opened', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..currentUserId = '@me:example.org'
      ..devices = const [
        VerificationDevice(id: 'PHONE', name: 'Pixel', verified: false),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    final toggle = find.byKey(const ValueKey('devices-toggle'));
    await tester.scrollUntilVisible(
      toggle,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // Collapsed: no device rows, and nothing fetched yet.
    expect(find.text('Pixel'), findsNothing);
    expect(find.text('Refresh devices'), findsNothing);
    expect(backend.deviceLoads, 0);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Pixel'), findsOneWidget);
    expect(backend.deviceLoads, 1);

    await tester.tap(find.text('Pixel'));
    await tester.pumpAndSettle();
    expect(backend.verificationAction, 'start:@me:example.org:PHONE');

    // Closing and reopening keeps the loaded list.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Pixel'), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Pixel'), findsOneWidget);
    expect(backend.deviceLoads, 1);
  });

  testWidgets('secure flag remains through recovery dialog exit animation', (
    tester,
  ) async {
    final calls = <bool>[];
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (enabled) async => calls.add(enabled),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Enter recovery key'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Enter recovery key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter recovery key'));
    await tester.pumpAndSettle();
    expect(calls, [true]);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(calls.last, isTrue);
    await tester.pumpAndSettle();
    expect(calls.last, isFalse);
  });

  testWidgets('recovery dialog entry stays single-flight while securing', (
    tester,
  ) async {
    final gate = Completer<void>();
    final calls = <bool>[];
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (enabled) async {
            calls.add(enabled);
            if (enabled) await gate.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Enter recovery key'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Enter recovery key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter recovery key'));
    await tester.pump();
    await tester.tap(find.text('Enter recovery key'));
    await tester.pump();
    expect(calls, [true]);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
  });

  testWidgets('new account saves a phrase before creating its identity', (
    tester,
  ) async {
    final secureCalls = <bool>[];
    final backend = FakeBackend()
      ..setupAvailability = CryptoSetupAvailability.create;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (enabled) async => secureCalls.add(enabled),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Set up encryption'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Set up encryption'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set up encryption'));
    await tester.pumpAndSettle();
    expect(find.byType(CryptoSetupScreen), findsOneWidget);
    expect(secureCalls, [true]);
    final phrase = tester
        .widget<SelectableText>(find.byType(SelectableText).first)
        .data!;
    expect(phrase.length, greaterThanOrEqualTo(32));
    expect(backend.lastSetupPhrase, isNull);
    await tester.tap(find.text('I saved this phrase outside the app'));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
          .value,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), phrase);
    await tester.ensureVisible(find.text('Create encryption identity'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create encryption identity'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Create encryption identity'));
    await tester.pumpAndSettle();
    expect(backend.lastSetupPhrase, isNotNull);
    expect(backend.lastSetupPhrase == phrase, isTrue);
    expect(find.text('synthetic-test-recovery-key'), findsOneWidget);
    await tester.tap(find.text('I saved my recovery credentials'));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).last).value,
      isTrue,
    );
    await tester.ensureVisible(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Finish setup'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(secureCalls.last, false);
    expect(find.text('Identity connected on this device'), findsOneWidget);
  });

  testWidgets('existing identity material cannot start a new identity', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..setupAvailability = CryptoSetupAvailability.blocked;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Existing identity needs careful recovery'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Set up encryption'), findsNothing);
    expect(find.text('Repair with existing key'), findsNothing);
  });

  testWidgets('new identity setup waits for other devices to sign out', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..setupAvailability = CryptoSetupAvailability.needsSingleDevice;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Other devices are signed in'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Set up encryption'), findsNothing);
  });

  testWidgets('partial identity can be repaired with its existing key', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..setupAvailability = CryptoSetupAvailability.repair;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
          setSecureWindow: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsCategory(tester, 'security');
    await tester.scrollUntilVisible(
      find.text('Repair with existing key'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Repair with existing key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair with existing key'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'synthetic-existing-recovery-key',
    );
    await tester.tap(find.text('Restore').last);
    await tester.pumpAndSettle();
    expect(backend.lastRepairCredential, 'synthetic-existing-recovery-key');
    expect(find.text('Identity connected on this device'), findsOneWidget);
  });

  testWidgets('failed screen protection prevents identity creation', (
    tester,
  ) async {
    final backend = FakeBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: CryptoSetupScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          setSecureWindow: (enabled) async {
            if (enabled) throw StateError('native screen guard unavailable');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Screen protection is unavailable'),
      findsOneWidget,
    );
    expect(find.text('Create encryption identity'), findsNothing);
    expect(backend.lastSetupPhrase, isNull);
  });

  testWidgets('incoming verification requires explicit acceptance', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..shownVerification = const VerificationDetails(
        id: 1,
        userId: '@friend:example.org',
        deviceId: 'OTHER',
        stage: VerificationStage.accept,
        incoming: true,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityOverlay(backend: backend, child: const Scaffold()),
      ),
    );
    expect(find.text('Accept request'), findsOneWidget);
    expect(find.text('Device: OTHER'), findsOneWidget);
    await tester.tap(find.text('Accept request'));
    await tester.pump();
    expect(backend.verificationAction, 'accept');
    await tester.tap(find.text('Cancel verification'));
    await tester.pump();
    expect(backend.verificationAction, 'cancel');
  });

  testWidgets('incoming verification appears over the app navigation', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..shownVerification = const VerificationDetails(
        id: 8,
        userId: '@me:example.org',
        stage: VerificationStage.accept,
        incoming: true,
      );
    await tester.pumpWidget(ParallaxApp(backend: backend));
    await tester.pump();
    expect(find.text('Verify identity'), findsOneWidget);
    expect(find.text('Accept request'), findsOneWidget);
    expect(find.text('SIGN IN TO MATRIX'), findsOneWidget);
  });

  testWidgets('encrypted-room sender offers verification', (tester) async {
    final backend = FakeBackend()
      ..roomList = [
        const ChatRoom(
          id: '!r:example.org',
          name: 'Secure room',
          preview: '',
          lastActivity: null,
          encrypted: true,
        ),
      ]
      ..entries = [
        ChatEntry(
          id: 'event',
          sender: '@friend:example.org',
          body: 'Hello',
          time: DateTime(2026),
          mine: false,
        ),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!r:example.org',
          backgroundStore: FakeBackgroundStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Hello'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verify sender'));
    await tester.pumpAndSettle();
    expect(backend.verificationAction, 'start:@friend:example.org:null');
  });

  testWidgets('SAS emoji and decimal comparison require a decision', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..shownVerification = const VerificationDetails(
        id: 2,
        userId: '@friend:example.org',
        stage: VerificationStage.compare,
        incoming: false,
        emojis: [
          VerificationEmoji('🐶', 'Dog'),
          VerificationEmoji('🐱', 'Cat'),
          VerificationEmoji('🌞', 'Sun'),
          VerificationEmoji('🌙', 'Moon'),
          VerificationEmoji('🔥', 'Fire'),
          VerificationEmoji('🌳', 'Tree'),
          VerificationEmoji('🌊', 'Wave'),
        ],
        numbers: [1234, 5678, 9012],
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityOverlay(backend: backend, child: const Scaffold()),
      ),
    );
    expect(find.text('Dog'), findsOneWidget);
    await tester.tap(find.text('Show numbers instead'));
    await tester.pump();
    expect(find.text('1234  5678  9012'), findsOneWidget);
    await tester.tap(find.text('They do not match'));
    await tester.pump();
    expect(backend.verificationAction, 'mismatch');
    await tester.tap(find.text('They match exactly'));
    await tester.pump();
    expect(backend.verificationAction, 'match');
  });

  testWidgets('verification secret stays obscured and can be skipped', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..shownVerification = const VerificationDetails(
        id: 3,
        userId: '@me:example.org',
        stage: VerificationStage.secret,
        incoming: false,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityOverlay(backend: backend, child: const Scaffold()),
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'test-only-secret');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Unlock and sign'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Unlock and sign'));
    await tester.pump();
    expect(backend.verificationAction, 'unlock');
    await tester.tap(find.text('Continue without signing'));
    await tester.pump();
    expect(backend.verificationAction, 'skip');
  });

  testWidgets('untrusted recipient blocks send until explicit decision', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..shownTrust = const TrustWarning(
        roomId: '!room:example.org',
        recipients: [
          UntrustedRecipient(
            userId: '@friend:example.org',
            masterKey: 'sample-master-key',
          ),
        ],
      );
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityOverlay(backend: backend, child: const Scaffold()),
      ),
    );
    expect(find.text('Unverified recipients'), findsOneWidget);
    expect(find.text('sample-master-key'), findsOneWidget);
    await tester.tap(find.text('Do not send'));
    await tester.pump();
    expect(backend.verificationAction, 'reject-trust');
    backend.shownTrust = const TrustWarning(
      roomId: '!room:example.org',
      recipients: [UntrustedRecipient(userId: '@friend:example.org')],
    );
    backend.notifyListeners();
    await tester.pump();
    await tester.ensureVisible(find.text('Send without verification'));
    await tester.pump();
    await tester.tap(find.text('Send without verification'));
    await tester.pump();
    expect(backend.verificationAction, 'trust');
  });
}

class FakeBackgroundStore extends RoomBackgroundStore {
  final rooms = <String, File>{
    '!r:example.org': File('assets/parallax_icon.png'),
    '!other:example.org': File('assets/parallax_icon.png'),
  };
  final cleared = <String>[];

  @override
  Future<File?> fileFor(String roomId) async => rooms[roomId];

  @override
  Future<void> clear(String roomId) async {
    rooms.remove(roomId);
    cleared.add(roomId);
  }
}

class FakeBackend extends ChatBackend {
  String? lastLogin;
  String? lastHomeserver;
  List<ChatRoom> roomList = [];
  List<ChatEntry> entries = [];
  String? activeId;
  String? lastMessage;
  bool failSend = false;
  String? lastReplyId;
  String? lastEditId;
  String? lastRedactedId;
  final typingStates = <bool>[];
  List<String> typingNames = [];
  String? lastReaction;
  String? declined;
  bool? lastRoomUnread;
  String? lastLeftRoom;
  String? createdRoomName;
  bool? createdRoomEncrypted;
  int imageLoads = 0;
  int avatarLoads = 0;
  String? lastRecoveryKey;
  bool connected = false;
  CryptoSetupAvailability setupAvailability = CryptoSetupAvailability.restore;
  String? lastSetupPhrase;
  String? lastRepairCredential;
  bool setupReady = true;
  VerificationDetails? shownVerification;
  TrustWarning? shownTrust;
  String? verificationAction;
  String? currentUserId;
  RoomSyncState syncState = RoomSyncState.ready;
  RoomSyncIssue? syncIssue;
  int refreshCount = 0;

  void setSync(RoomSyncState state, [RoomSyncIssue? issue]) {
    syncState = state;
    syncIssue = issue;
    notifyListeners();
  }

  @override
  SessionStatus get connection => SessionStatus.signedOut;
  @override
  RoomSyncState get roomSyncState => syncState;
  @override
  RoomSyncIssue? get roomSyncIssue => syncIssue;
  @override
  String? get userId => currentUserId;
  @override
  String? get error => null;
  @override
  List<ChatRoom> get rooms => roomList;
  @override
  String? get activeRoomId => activeId;
  @override
  List<ChatEntry> get messages => entries;
  @override
  bool get sending => false;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingHistory => false;
  @override
  List<String> get typingUsers => typingNames;
  @override
  VerificationDetails? get verification => shownVerification;
  @override
  TrustWarning? get trustWarning => shownTrust;

  void showVerification(VerificationDetails details) {
    shownVerification = details;
    notifyListeners();
  }

  List<VerificationDevice> devices = const [];
  int deviceLoads = 0;

  @override
  Future<List<VerificationDevice>> ownDevices() async {
    deviceLoads++;
    return devices;
  }

  @override
  Future<void> startVerification(String userId, {String? deviceId}) async {
    verificationAction = 'start:$userId:$deviceId';
  }

  @override
  Future<void> acceptVerification() async {
    verificationAction = 'accept';
  }

  @override
  Future<void> chooseEmojiVerification() async {
    verificationAction = 'choose';
  }

  @override
  Future<void> confirmVerification({required bool matches}) async {
    verificationAction = matches ? 'match' : 'mismatch';
  }

  @override
  Future<void> unlockVerification(String keyOrPassphrase) async {
    verificationAction = 'unlock';
  }

  @override
  Future<void> skipVerificationSigning() async {
    verificationAction = 'skip';
  }

  @override
  Future<void> cancelVerification() async {
    verificationAction = 'cancel';
  }

  @override
  void dismissVerification() {
    verificationAction = 'dismiss';
  }

  @override
  void respondToTrustWarning(bool approved) {
    verificationAction = approved ? 'trust' : 'reject-trust';
    shownTrust = null;
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> refreshRooms() async {
    refreshCount++;
    setSync(RoomSyncState.loading);
  }

  @override
  Future<void> login({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    lastHomeserver = homeserver;
    lastLogin = username;
  }

  @override
  Future<void> logout() async {}
  @override
  Future<void> openRoom(String roomId) async {
    activeId = roomId;
  }

  @override
  Future<void> loadOlder(String roomId) async {}

  @override
  void closeRoom(String roomId) {
    activeId = null;
  }

  @override
  Future<void> sendText(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
  }) async {
    if (failSend) throw StateError('SDK returned no event ID');
    lastMessage = text;
    lastReplyId = replyToId;
    lastEditId = editEventId;
  }

  @override
  Future<void> sendImages(String roomId, List<XFile> images) async {}
  @override
  Future<void> sendAttachment(String roomId, XFile file) async {}
  @override
  Future<Uint8List?> loadImage(String roomId, String eventId) async {
    imageLoads++;
    return null;
  }

  @override
  Future<DownloadedAttachment> loadAttachment(
    String roomId,
    String eventId,
  ) async => throw StateError('not available in widget test');

  @override
  Future<Uint8List?> loadAvatar(Uri url) async {
    avatarLoads++;
    return null;
  }

  @override
  Future<void> react(
    String roomId,
    String eventId, {
    String emoji = '❤️',
  }) async {
    lastReaction = emoji;
  }

  @override
  Future<void> redactMessage(String roomId, String eventId) async {
    lastRedactedId = eventId;
  }

  @override
  Future<void> setTyping(String roomId, bool typing) async {
    typingStates.add(typing);
  }

  @override
  Future<void> createDirectChat(String userId) async {}

  @override
  Future<String> createRoom(String name, {required bool encrypted}) async {
    createdRoomName = name;
    createdRoomEncrypted = encrypted;
    roomList = [
      ...roomList,
      ChatRoom(
        id: '!created:example.org',
        name: name,
        preview: '',
        lastActivity: null,
        encrypted: encrypted,
      ),
    ];
    notifyListeners();
    return '!created:example.org';
  }

  @override
  Future<void> acceptInvite(String roomId) async {}

  @override
  Future<void> declineInvite(String roomId) async {
    declined = roomId;
    roomList = [
      for (final room in roomList)
        if (room.id != roomId) room,
    ];
    notifyListeners();
  }

  @override
  Future<void> setRoomUnread(String roomId, bool unread) async {
    lastRoomUnread = unread;
    roomList = [
      for (final room in roomList)
        if (room.id != roomId)
          room
        else
          ChatRoom(
            id: room.id,
            name: room.name,
            preview: room.preview,
            lastActivity: room.lastActivity,
            unread: room.unread,
            manuallyUnread: unread,
            invited: room.invited,
            encrypted: room.encrypted,
            isDirect: room.isDirect,
            avatarUrl: room.avatarUrl,
            heroes: room.heroes,
          ),
    ];
    notifyListeners();
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    lastLeftRoom = roomId;
    roomList = [
      for (final room in roomList)
        if (room.id != roomId) room,
    ];
    notifyListeners();
  }

  @override
  Future<RoomDetails> getRoomDetails(String roomId) async =>
      throw UnimplementedError();

  @override
  Future<void> editRoomName(String roomId, String name) async =>
      throw UnimplementedError();

  @override
  Future<void> editRoomTopic(String roomId, String topic) async =>
      throw UnimplementedError();

  @override
  Future<void> inviteToRoom(String roomId, String userId) async =>
      throw UnimplementedError();

  @override
  Future<void> moderateRoomMember(
    String roomId,
    String userId,
    RoomAction action,
  ) async => throw UnimplementedError();

  @override
  Future<PublicRoomPage> searchPublicRooms(
    String query, {
    String? nextBatch,
  }) async {
    if (query == 'kotlin') {
      return const PublicRoomPage(
        rooms: [
          PublicRoom(id: '!k:example.org', name: 'Kotlin room', members: 9),
        ],
      );
    }
    if (nextBatch != null) {
      return const PublicRoomPage(
        rooms: [
          PublicRoom(
            id: '!second:example.org',
            name: 'Second room',
            members: 2,
          ),
        ],
      );
    }
    return const PublicRoomPage(
      rooms: [
        PublicRoom(id: '!first:example.org', name: 'First room', members: 4),
      ],
      nextBatch: 'page2',
    );
  }

  @override
  Future<String> joinPublicRoom(String roomId) async => roomId;

  @override
  Future<MessageSearchPage> searchMessages(
    String query, {
    String? nextBatch,
  }) async => MessageSearchPage(
    hits: [
      MessageHit(
        id: 'e1',
        roomId: '!r:example.org',
        roomName: 'General',
        sender: '@a:server',
        body: 'Found it in a room',
        time: DateTime(2026),
      ),
    ],
  );

  @override
  Future<CryptoStatus> cryptoStatus() async => CryptoStatus(
    initialized:
        connected ||
        setupAvailability == CryptoSetupAvailability.restore ||
        setupAvailability == CryptoSetupAvailability.connected,
    connected: connected,
    keyBackupEnabled:
        connected || setupAvailability == CryptoSetupAvailability.restore,
    crossSigningEnabled:
        connected || setupAvailability == CryptoSetupAvailability.restore,
    setupAvailability: connected
        ? CryptoSetupAvailability.connected
        : setupAvailability,
  );

  @override
  Future<CryptoSetupResult> createCryptoIdentity(
    String recoveryPassphrase,
  ) async {
    lastSetupPhrase = recoveryPassphrase;
    connected = setupReady;
    setupAvailability = setupReady
        ? CryptoSetupAvailability.connected
        : CryptoSetupAvailability.repair;
    return CryptoSetupResult(
      recoveryKey: 'synthetic-test-recovery-key',
      ready: setupReady,
    );
  }

  @override
  Future<void> repairCryptoIdentity(String keyOrPassphrase) async {
    lastRepairCredential = keyOrPassphrase;
    connected = true;
    setupAvailability = CryptoSetupAvailability.connected;
  }

  @override
  Future<void> restoreCryptoIdentity(String keyOrPassphrase) async {
    lastRecoveryKey = keyOrPassphrase;
    connected = true;
  }

  @override
  Future<void> restoreBackedUpKeys() async {}
}

/// Opens a Settings category page (`settings.<key>`) from the top-level menu.
Future<void> openSettingsCategory(WidgetTester tester, String key) async {
  final row = find.byKey(ValueKey('settings.$key'));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}
