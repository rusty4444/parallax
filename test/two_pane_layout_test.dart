import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/settings_screen.dart';
import 'package:parallax/two_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';
import 'widget_test.dart' show FakeBackgroundStore;

ChatRoom _room(String id, String name) =>
    ChatRoom(id: id, name: name, preview: 'hello', lastActivity: null);

void main() {
  late HomeFakeBackend backend;
  late RoomRouteObserver observer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = HomeFakeBackend()
      ..roomList = [_room('!team:x.org', 'Team'), _room('!alex:x.org', 'Alex')];
    observer = RoomRouteObserver();
  });

  /// Logical window size (DPR 1) for the test surface.
  void window(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  Widget app({
    AppearancePreferences? prefs,
    double textScale = 1,
    double topInset = 0,
  }) => FeatureSettingsScope(
    preferences: prefs ?? AppearancePreferences(),
    draftStore: MessageDraftStore(),
    child: MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      navigatorObservers: [observer],
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: media.padding.copyWith(top: topInset),
            viewPadding: media.viewPadding.copyWith(top: topInset),
          ),
          child: child!,
        );
      },
      home: InboxScreen(
        backend: backend,
        palette: paletteFor(VisualTheme.parallax),
        style: VisualTheme.parallax,
        onThemeChanged: (_) {},
        roomRoutes: observer,
        backgroundStore: FakeBackgroundStore(),
      ),
    ),
  );

  Future<void> pumpApp(WidgetTester tester, Size size) async {
    window(tester, size);
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  group('window classes', () {
    test('breakpoints follow Material medium width with a height guard', () {
      expect(isTwoPaneWindow(const Size(599, 900)), isFalse);
      expect(isTwoPaneWindow(const Size(600, 900)), isTrue);
      expect(isTwoPaneWindow(const Size(1280, 800)), isTrue);
      // Landscape phone: wide but short.
      expect(isTwoPaneWindow(const Size(900, 420)), isFalse);
    });

    test('list width is clamped and splits at a vertical hinge', () {
      expect(twoPaneSplit(600).listWidth, 300);
      expect(twoPaneSplit(840).listWidth, closeTo(336, 0.01));
      expect(twoPaneSplit(1600).listWidth, 420);
      expect(twoPaneSplit(1100).gapWidth, 1);
      final hinge = ui.DisplayFeature(
        bounds: const Rect.fromLTWH(400, 0, 24, 900),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.unknown,
      );
      final split = twoPaneSplit(1100, features: [hinge]);
      expect(split.listWidth, 400);
      expect(split.gapWidth, 24);
      // A horizontal hinge (tabletop posture) does not move the split.
      final horizontal = ui.DisplayFeature(
        bounds: const Rect.fromLTWH(0, 400, 1100, 24),
        type: ui.DisplayFeatureType.hinge,
        state: ui.DisplayFeatureState.unknown,
      );
      expect(twoPaneSplit(1100, features: [horizontal]).listWidth, 420);
      // A flat fold is a continuous screen: no split.
      final flatFold = ui.DisplayFeature(
        bounds: const Rect.fromLTWH(400, 0, 2, 900),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureFlat,
      );
      expect(twoPaneSplit(1100, features: [flatFold]).gapWidth, 1);
    });
  });

  group('phone layout', () {
    testWidgets('tapping a chat pushes a full-screen room route', (
      tester,
    ) async {
      await pumpApp(tester, const Size(400, 900));
      expect(find.text('Select a conversation'), findsNothing);
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(observer.rooms.length, 1);
      expect(observer.rooms.single.roomId, '!team:x.org');
      // The phone room keeps its back arrow.
      expect(find.byTooltip('Back to rooms'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to rooms'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsNothing);
      expect(observer.rooms, isEmpty);
    });

    testWidgets('a landscape phone stays single-pane', (tester) async {
      await pumpApp(tester, const Size(900, 420));
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(observer.rooms.length, 1);
      expect(find.text('Select a conversation'), findsNothing);
    });
  });

  group('tablet layout', () {
    testWidgets('inbox on the left, placeholder on the right', (tester) async {
      await pumpApp(tester, const Size(1100, 900));
      expect(find.text('Team'), findsOneWidget);
      expect(find.text('Select a conversation'), findsOneWidget);
      expect(find.byType(RoomScreen), findsNothing);
      // The list pane is 420 wide (1100 * 0.4 clamped).
      final listRect = tester.getRect(find.byType(InboxScreen));
      expect(listRect.width, 1100);
      expect(
        tester.getTopLeft(find.text('Select a conversation')).dx,
        greaterThan(420),
      );
    });

    testWidgets('tapping a chat selects the detail pane without a route', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(observer.rooms, isEmpty, reason: 'no route is pushed');
      expect(find.text('Select a conversation'), findsNothing);
      // The list stays visible beside the chat.
      expect(find.text('Alex'), findsOneWidget);
      // Embedded chat has no back arrow (there is no route to pop).
      expect(find.byTooltip('Back to rooms'), findsNothing);
      // The open chat's row is tinted: its Material carries the accent blend.
      final teamTile = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const ValueKey('room-!team:x.org')),
              matching: find.byType(Material),
            )
            .first,
      );
      final p = paletteFor(VisualTheme.parallax);
      expect(
        teamTile.color,
        Color.alphaBlend(p.accent.withValues(alpha: 0.16), p.surface),
      );
    });

    testWidgets('switching chats replaces the detail pane', (tester) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.activeRoomId, '!team:x.org');
      await tester.tap(find.text('Alex'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(backend.activeRoomId, '!alex:x.org');
      expect(observer.rooms, isEmpty);
    });

    testWidgets('notification-style opens select the pane and clear routes', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1100, 900));
      // A settings route above the inbox, then a notification tap.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Settings screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openRoomOnNavigator(
        navigator,
        backend: backend,
        palette: paletteFor(VisualTheme.parallax),
        roomId: '!alex:x.org',
        replaceStack: true,
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings screen'), findsNothing);
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(backend.activeRoomId, '!alex:x.org');
      expect(observer.rooms, isEmpty);
    });

    testWidgets(
      'a plain wide open pops covering routes so the pane is visible',
      (tester) async {
        await pumpApp(tester, const Size(1100, 900));
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Saved messages')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // A link/saved-message open without replaceStack must still surface
        // the detail pane instead of selecting behind the covering route.
        await openRoomOnNavigator(
          navigator,
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!team:x.org',
        );
        await tester.pumpAndSettle();
        expect(find.text('Saved messages'), findsNothing);
        expect(find.byType(RoomScreen), findsOneWidget);
        expect(backend.activeRoomId, '!team:x.org');
        expect(observer.rooms, isEmpty);
      },
    );
  });

  testWidgets(
    'Windows and Android retain the flush single-row header and full-height split',
    (tester) async {
      window(tester, const Size(700, 900));
      await tester.pumpWidget(app(textScale: 1.3));
      await tester.pumpAndSettle();
      final brand = tester.getRect(
        find.byKey(const ValueKey('home.header_brand')),
      );
      final search = tester.getRect(
        find.byKey(const ValueKey('home.search_toggle')),
      );
      expect(brand.left, 16);
      expect(brand.top, inInclusiveRange(4, 8));
      expect(search.top, inInclusiveRange(4, 8));
      expect(brand.center.dy, closeTo(search.center.dy, 0.01));
      expect(find.byKey(const ValueKey('home.header_actions')), findsNothing);
      final divider = tester.getRect(
        find.byKey(const ValueKey('two-pane-divider')),
      );
      expect(divider.top, 0);
      expect(divider.bottom, 900);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );

  group('macOS list-pane header', () {
    for (final paneWidth in [kTwoPaneMinListWidth, 300.0]) {
      testWidgets(
        'all actions work at ${paneWidth}dp and 1.3 text scale with titlebar inset',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            if (paneWidth == kTwoPaneMinListWidth) kTwoPaneWidthPref: paneWidth,
          });
          window(tester, const Size(700, 900));
          await tester.pumpWidget(app(textScale: 1.3, topInset: 36));
          await tester.pumpAndSettle();
          final divider = find.byKey(const ValueKey('two-pane-divider'));
          expect(tester.getRect(divider).left, paneWidth);
          final brand = tester.getRect(
            find.byKey(const ValueKey('home.header_brand')),
          );
          // Wide content opts out of the inherited route inset. Only the
          // brand row reserves horizontal space beside the traffic lights.
          expect(brand.left, 84);
          expect(brand.top, 4);
          for (final tooltip in [
            'Search conversations',
            'Create room',
            'Show options',
            'Settings',
          ]) {
            final action = find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == tooltip,
            );
            expect(action.hitTestable(), findsOneWidget);
            final rect = tester.getRect(action);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(paneWidth));
            expect(rect.top, greaterThanOrEqualTo(brand.bottom));
            expect(rect.height, greaterThanOrEqualTo(40));
            expect(tester.widget<IconButton>(action).onPressed, isNotNull);
          }
          expect(tester.takeException(), isNull);

          await tester.tap(find.byTooltip('Search conversations'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('home.conversation_search')),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('Hide conversation search'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          await tester.tap(find.byTooltip('Show options'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('home.options_panel')),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('Hide options'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          await tester.tap(find.byTooltip('Create room'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byTooltip('Settings'));
          await tester.pumpAndSettle();
          expect(find.byType(SettingsScreen), findsOneWidget);
          tester.state<NavigatorState>(find.byType(Navigator)).pop();
          await tester.pumpAndSettle();
          expect(find.byType(SettingsScreen), findsNothing);
          expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    }

    testWidgets(
      'narrow header reserves the inherited traffic-light inset only once',
      (tester) async {
        window(tester, const Size(400, 900));
        await tester.pumpWidget(app(topInset: 36));
        await tester.pumpAndSettle();
        final search = tester.getRect(
          find.byKey(const ValueKey('home.search_toggle')),
        );
        expect(search.top, greaterThanOrEqualTo(36));
        // The header centres actions beside its taller logo/text. Compare
        // against the existing minimum inset rather than guessing that
        // centred button's absolute y-position.
        await tester.pumpWidget(app(topInset: 0));
        await tester.pumpAndSettle();
        final minimumOnly = tester.getRect(
          find.byKey(const ValueKey('home.search_toggle')),
        );
        expect(search.top, minimumOnly.top);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'wide embedded rooms opt out of the inherited traffic-light inset',
      (tester) async {
        window(tester, const Size(1100, 900));
        await tester.pumpWidget(app(topInset: 36));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Team'));
        await tester.pumpAndSettle();
        final roomContext = tester.element(find.byType(RoomScreen));
        expect(MediaQuery.paddingOf(roomContext).top, 0);
        expect(MediaQuery.viewPaddingOf(roomContext).top, 0);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  group('fold / resize transitions', () {
    testWidgets('unfolding absorbs the open chat route into the pane', (
      tester,
    ) async {
      await pumpApp(tester, const Size(400, 900));
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(observer.rooms.length, 1);
      // Unfold: the window widens.
      tester.view.physicalSize = const Size(1100, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty, reason: 'the chat route was absorbed');
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(backend.activeRoomId, '!team:x.org');
      expect(find.byTooltip('Back to rooms'), findsNothing);
    });

    testWidgets('folding pushes the selected chat as a phone route', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(observer.rooms, isEmpty);
      // Fold: the window narrows to the cover screen.
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms.length, 1);
      expect(observer.rooms.single.roomId, '!team:x.org');
      expect(find.byTooltip('Back to rooms'), findsOneWidget);
      // Back returns to the inbox; unfolding again restores the chat.
      await tester.tap(find.byTooltip('Back to rooms'));
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty);
      tester.view.physicalSize = const Size(1100, 900);
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(backend.activeRoomId, '!team:x.org');
    });

    testWidgets('a chat opened by a link while folded is absorbed on unfold', (
      tester,
    ) async {
      await pumpApp(tester, const Size(400, 900));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      // Simulates matrix_link_opener / notification push on a phone.
      unawaited(
        openRoomOnNavigator(
          navigator,
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          roomId: '!alex:x.org',
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.rooms.length, 1);
      tester.view.physicalSize = const Size(1100, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty);
      expect(backend.activeRoomId, '!alex:x.org');
    });

    testWidgets('folding does not push a room that was left', (tester) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.activeRoomId, '!team:x.org');
      backend.roomList = [
        for (final room in backend.roomList)
          if (room.id != '!team:x.org') room,
      ];
      backend.notifyListeners();
      await tester.pump();
      expect(find.text('Select a conversation'), findsOneWidget);
      expect(find.byType(RoomScreen), findsNothing);
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty);
      expect(find.byType(RoomScreen), findsNothing);
      expect(find.text('Alex'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a re-invitation is not a joined detail or phone route', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      backend.roomList = [
        for (final room in backend.roomList)
          room.id == '!team:x.org' ? room.copyWith(invited: true) : room,
      ];
      backend.notifyListeners();
      await tester.pump();
      expect(find.text('Select a conversation'), findsOneWidget);
      expect(find.byType(RoomScreen), findsNothing);
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty);
      expect(find.byType(RoomScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('two window-class flips before a frame settle on the last', (
      tester,
    ) async {
      await pumpApp(tester, const Size(1100, 900));
      await tester.tap(find.text('Team'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.physicalSize = const Size(400, 900);
      tester.view.physicalSize = const Size(1100, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, isEmpty);
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.byTooltip('Back to rooms'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a rapid unfold and fold keeps the original phone route', (
      tester,
    ) async {
      await pumpApp(tester, const Size(400, 900));
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      final originalRoute = observer.rooms.single;
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.physicalSize = const Size(400, 900);
      await tester.pumpAndSettle();
      expect(observer.rooms, [same(originalRoute)]);
      expect(find.byType(RoomScreen), findsOneWidget);
      expect(find.byTooltip('Back to rooms'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
