// Window-drag regressions with the REAL production wiring: DesktopShell in
// MaterialApp.builder ABOVE the Navigator (as main.dart mounts it), not the
// simplified shell-only harness in windows_desktop_ux_test.dart.
//
// The Navigator wraps its Overlay in a pointer-tracking Listener +
// AbsorbPointer on every route. With the production wiring that
// infrastructure sits INSIDE the shell's content root, between the drag
// strip and the content root in the hit path. The strip's interactive-below
// guard must not mistake it for a control — doing so made the window
// un-draggable on every real screen while the simplified harness passed.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/platform/desktop_shell.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:parallax/features/threads/thread_list_screen.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/thread_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, roomId;
import 'widget_test.dart' show FakeBackgroundStore;
import 'windows_desktop_ux_test.dart' show platformTestWidgets;

ChatEntry _entry(String id, {bool mine = false, String body = 'Hello'}) =>
    ChatEntry(
      id: id,
      sender: mine ? '@me:s' : '@alice:s',
      senderName: mine ? 'Me' : 'Alice',
      body: body,
      time: DateTime(2026, 11, 20, 10, 11),
      mine: mine,
      content: {'msgtype': 'm.text', 'body': body},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  late List<String> calls;
  setUp(() {
    calls = <String>[];
    const channel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
            return false;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  });

  /// Mirrors main.dart: the shell wraps the Navigator from the builder.
  Future<void> pumpRealShell(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        builder: (context, child) => DesktopShell(
          palette: paletteFor(VisualTheme.parallax),
          child: FeatureSettingsScope(
            preferences: AppearancePreferences(),
            draftStore: Drafts(),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dragAt(WidgetTester tester, Offset position) async {
    final gesture = await tester.startGesture(
      position,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(14, 6));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
  }

  ThreadScreen thread(FeaturesBackend backend) => ThreadScreen(
    backend: backend,
    roomId: roomId,
    root: _entry('root'),
    palette: paletteFor(VisualTheme.parallax),
  );

  group('production wiring: window drag', () {
    platformTestWidgets(
      'thread header empty space drags the window',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        await dragAt(tester, const Offset(500, 18));
        expect(calls, contains('startDragging'));
      },
    );

    platformTestWidgets(
      'full-screen room top band drags the window',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('m1')];
        await pumpRealShell(
          tester,
          RoomScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            roomId: roomId,
            draftStore: Drafts(),
            backgroundStore: FakeBackgroundStore(),
          ),
        );
        await dragAt(tester, const Offset(400, 18));
        expect(calls, contains('startDragging'));
      },
    );

    platformTestWidgets(
      'embedded room header empty space drags the window',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('m1')];
        await pumpRealShell(
          tester,
          RoomScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.parallax),
            roomId: roomId,
            embedded: true,
            draftStore: Drafts(),
            backgroundStore: FakeBackgroundStore(),
          ),
        );
        await dragAt(tester, const Offset(400, 18));
        expect(calls, contains('startDragging'));
      },
    );

    platformTestWidgets(
      'a header button keeps its own gesture, not a window drag',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        final back = find.byTooltip('Back');
        await tester.drag(back, const Offset(60, 10));
        await tester.pump(const Duration(milliseconds: 100));
        expect(calls, isNot(contains('startDragging')));
      },
    );

    platformTestWidgets(
      'double-clicking empty thread header space maximizes',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        await tester.tapAt(const Offset(500, 18));
        await tester.pump(kDoubleTapMinTime);
        await tester.tapAt(const Offset(500, 18));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(calls, contains('maximize'));
      },
    );

    platformTestWidgets(
      'caption buttons work and do not start a drag',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        await tester.tap(find.byTooltip('Minimize'));
        await tester.pump();
        expect(calls, contains('minimize'));
        calls.clear();
        await dragAt(tester, const Offset(780, 18));
        expect(calls, isNot(contains('startDragging')));
      },
    );
  });

  group('production wiring: thread headers clear the caption buttons', () {
    platformTestWidgets(
      'thread Refresh sits below the caption-button band',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        final refresh = tester.getRect(find.byTooltip('Refresh'));
        expect(refresh.top, greaterThanOrEqualTo(kDesktopTitleBarHeight));
      },
    );

    platformTestWidgets(
      'threads-list Refresh sits below the caption-button band',
      TargetPlatform.windows,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(
          tester,
          ThreadsListScreen(
            backend: backend,
            roomId: roomId,
            palette: paletteFor(VisualTheme.parallax),
          ),
        );
        final refresh = tester.getRect(find.byTooltip('Refresh'));
        expect(refresh.top, greaterThanOrEqualTo(kDesktopTitleBarHeight));
      },
    );

    platformTestWidgets(
      'on macOS the thread header keeps its flush layout',
      TargetPlatform.macOS,
      (tester) async {
        final backend = FeaturesBackend()..entries = [_entry('root')];
        await pumpRealShell(tester, thread(backend));
        final refresh = tester.getRect(find.byTooltip('Refresh'));
        // No Windows caption clearance: the header stays flush (macOS
        // reserves the traffic-light strip via MediaQuery insets instead).
        expect(refresh.top, lessThan(kDesktopTitleBarHeight));
      },
    );
  });
}
