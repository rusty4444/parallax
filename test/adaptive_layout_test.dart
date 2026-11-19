// Adaptive master-detail layout: iPad, unfolded iPhone Fold and Mac windows
// show the room list beside the open chat; compact windows keep the phone
// flow; crossing the breakpoint keeps the open chat on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/home/adaptive_layout.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';

ChatRoom _room(String id, String name) => ChatRoom(
  id: id,
  name: name,
  preview: 'hello',
  lastActivity: null,
  isDirect: false,
  unread: 0,
  highlightCount: 0,
  favourite: false,
  lowPriority: false,
  invited: false,
  isSpace: false,
  manuallyUnread: false,
  notificationMode: RoomNotificationMode.allMessages,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('useWideLayout', () {
    test('phone windows stay compact, tablets and Macs go wide', () {
      // iPhone portrait and landscape (including Pro Max).
      expect(useWideLayout(const Size(393, 852)), isFalse);
      expect(useWideLayout(const Size(932, 430)), isFalse);
      // iPhone Fold: outer screen compact, unfolded inner screen wide.
      expect(useWideLayout(const Size(400, 900)), isFalse);
      expect(useWideLayout(const Size(820, 1024)), isTrue);
      // iPad portrait and landscape (mini through 13-inch).
      expect(useWideLayout(const Size(744, 1133)), isTrue);
      expect(useWideLayout(const Size(1024, 1366)), isTrue);
      expect(useWideLayout(const Size(1366, 1024)), isTrue);
      // The default widget-test surface stays on the compact flow.
      expect(useWideLayout(const Size(800, 600)), isFalse);
      // Mac windows.
      expect(useWideLayout(const Size(1200, 800)), isTrue);
      expect(useWideLayout(const Size(900, 500)), isFalse);
    });
  });

  group('AdaptiveShell', () {
    late HomeFakeBackend backend;
    late AdaptiveLayoutController controller;
    late RoomRouteObserver observer;
    late AppearancePreferences prefs;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = HomeFakeBackend();
      backend.roomList = [
        _room('!alpha:example.org', 'Alpha'),
        _room('!beta:example.org', 'Beta'),
      ];
      controller = AdaptiveLayoutController();
      observer = RoomRouteObserver();
      prefs = AppearancePreferences();
    });

    tearDown(() {
      controller.dispose();
      observer.dispose();
      prefs.dispose();
      backend.dispose();
    });

    Future<void> pumpShell(
      WidgetTester tester, {
      required Size surface,
      bool realRoom = false,
    }) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final palette = paletteFor(VisualTheme.parallax);
      await tester.pumpWidget(
        FeatureSettingsScope(
          preferences: prefs,
          draftStore: MessageDraftStore(),
          child: MaterialApp(
            theme: themeFor(VisualTheme.parallax),
            navigatorObservers: [observer],
            home: AdaptiveShell(
              controller: controller,
              observer: observer,
              palette: palette,
              roomBuilder: realRoom
                  ? (id) => RoomScreen(
                      backend: backend,
                      palette: palette,
                      roomId: id,
                    )
                  : (id) => Scaffold(body: Center(child: Text('detail:$id'))),
              inbox: InboxScreen(
                backend: backend,
                palette: palette,
                style: VisualTheme.parallax,
                onThemeChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('compact windows push a named chat route', (tester) async {
      await pumpShell(tester, surface: const Size(393, 852));
      expect(find.byType(RoomScreen), findsNothing);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      // The inbox pushes the real chat screen as a named route.
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(observer.topRoomId, '!alpha:example.org');
      expect(controller.selectedRoomId, isNull);
    });

    testWidgets('wide windows select the chat beside the list', (tester) async {
      await pumpShell(tester, surface: const Size(1024, 768));
      // Both panes are visible: the list and the empty detail placeholder.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Pick a chat'), findsOneWidget);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('detail:!alpha:example.org'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget); // list still there
      expect(observer.topRoomId, isNull); // no route pushed
      expect(controller.selectedRoomId, '!alpha:example.org');
      // Switching chats replaces the pane, not a route.
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(find.text('detail:!beta:example.org'), findsOneWidget);
      expect(find.text('detail:!alpha:example.org'), findsNothing);
    });

    testWidgets('folding keeps the open chat as a full-screen route', (
      tester,
    ) async {
      await pumpShell(tester, surface: const Size(820, 1024));
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(controller.selectedRoomId, '!alpha:example.org');
      // Fold: the window becomes phone-sized.
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(find.text('detail:!alpha:example.org'), findsOneWidget);
      expect(observer.topRoomId, '!alpha:example.org');
    });

    testWidgets('unfolding moves the open chat into the detail pane', (
      tester,
    ) async {
      await pumpShell(tester, surface: const Size(400, 900));
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(observer.topRoomId, '!beta:example.org');
      expect(find.byType(RoomScreen), findsOneWidget);
      // Unfold: the window becomes tablet-sized.
      tester.view.physicalSize = const Size(820, 1024);
      await tester.pumpAndSettle();
      expect(observer.topRoomId, isNull); // route moved into the pane
      expect(controller.selectedRoomId, '!beta:example.org');
      expect(find.text('detail:!beta:example.org'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('a chat route opened while wide becomes the pane selection', (
      tester,
    ) async {
      await pumpShell(tester, surface: const Size(1200, 800));
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      // A notification/link opens another chat as a full-screen route.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        buildRoomRoute(
          roomId: '!beta:example.org',
          builder: (_) => const Scaffold(
            body: Center(child: Text('detail:!beta:example.org')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.selectedRoomId, '!beta:example.org');
      navigator.pop();
      await tester.pumpAndSettle();
      // Popping the route leaves that chat in the pane.
      expect(find.text('detail:!beta:example.org'), findsOneWidget);
      expect(observer.topRoomId, isNull);
    });

    testWidgets('embedded chat has no back button; pushed chat does', (
      tester,
    ) async {
      await pumpShell(tester, surface: const Size(1024, 768), realRoom: true);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(find.byTooltip('Back to rooms'), findsNothing);
      // Fold: the same chat as a route shows the back button again.
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Back to rooms'), findsOneWidget);
    });
  });

  group('RoomRouteObserver', () {
    test(
      'tracks the topmost chat route and resets on navigator replacement',
      () {
        final observer = RoomRouteObserver();
        addTearDown(observer.dispose);
        final home = MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => const SizedBox(),
        );
        final alpha = buildRoomRoute(
          roomId: '!a:x.org',
          builder: (_) => const SizedBox(),
        );
        final beta = buildRoomRoute(
          roomId: '!b:x.org',
          builder: (_) => const SizedBox(),
        );
        observer.didPush(home, null);
        expect(observer.topRoomId, isNull);
        observer.didPush(alpha, home);
        expect(observer.topRoomId, '!a:x.org');
        observer.didPush(beta, alpha);
        expect(observer.topRoomId, '!b:x.org');
        observer.didPop(beta, alpha);
        expect(observer.topRoomId, '!a:x.org');
        observer.reset();
        expect(observer.topRoomId, isNull);
      },
    );
  });
}
