import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/platform/desktop_shell.dart';
import 'package:parallax/features/platform/desktop_title_bar.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/timeline/double_tap_react.dart';
import 'package:parallax/two_pane.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';
import 'rich_message_composer_test.dart' show mount;
import 'widget_test.dart' show FakeBackgroundStore;

/// Foundation overrides must be restored before the test body ends — the
/// binding verifies invariants before tearDown callbacks run.
void platformTestWidgets(
  String description,
  TargetPlatform platform,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktop compose keys', () {
    Future<void> focusField(WidgetTester tester) async {
      await tester.tap(find.byType(TextField));
      await tester.pump();
    }

    platformTestWidgets('Enter sends on desktop', TargetPlatform.windows, (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      String? sent;
      await mount(
        tester,
        controller: controller,
        onSend: (text, media) async => sent = text,
      );
      await tester.enterText(find.byType(TextField), 'hello matrix');
      await focusField(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, 'hello matrix');
    });

    platformTestWidgets(
      'Shift+Enter is a newline, not a send',
      TargetPlatform.windows,
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var sends = 0;
        await mount(
          tester,
          controller: controller,
          onSend: (text, media) async => sends++,
        );
        await tester.enterText(find.byType(TextField), 'line one');
        await focusField(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(sends, 0);
      },
    );

    platformTestWidgets(
      'Enter stays with the IME on phones',
      TargetPlatform.android,
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var sends = 0;
        await mount(
          tester,
          controller: controller,
          onSend: (text, media) async => sends++,
        );
        await tester.enterText(find.byType(TextField), 'hello');
        await focusField(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(sends, 0);
      },
    );

    platformTestWidgets(
      'Ctrl+V attaches a clipboard image on Windows',
      TargetPlatform.windows,
      (tester) async {
        final png = Uint8List.fromList(List.filled(32, 7));
        const channel = MethodChannel('parallax/clipboard');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              expect(call.method, 'readImage');
              return png;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await mount(tester, controller: controller, onSend: (_, _) async {});
        await focusField(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(find.text('pasted-image.png'), findsOneWidget);
      },
    );

    platformTestWidgets(
      'pasting more images adds them instead of replacing (#15)',
      TargetPlatform.windows,
      (tester) async {
        var next = 0;
        const channel = MethodChannel('parallax/clipboard');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              next++;
              return Uint8List.fromList(List.filled(32, next));
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final sent = <(String, int?)>[];
        await mount(
          tester,
          controller: controller,
          onSend: (text, media) async => sent.add((text, media?.bytes.first)),
        );
        Future<void> paste() async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        }

        await focusField(tester);
        await paste();
        expect(find.text('pasted-image.png'), findsOneWidget);
        await paste();
        await paste();
        // All three stay staged, in paste order.
        expect(
          find.byKey(const ValueKey('composer-staged-images')),
          findsOneWidget,
        );
        expect(find.text('3 images'), findsOneWidget);
        for (var i = 0; i < 3; i++) {
          expect(
            find.byKey(ValueKey('composer-staged-image-$i')),
            findsOneWidget,
          );
        }

        // Remove the middle one, then send: each image goes in order and
        // the typed text follows as its own message.
        await tester.tap(find.byTooltip('Remove image 2'));
        await tester.pump();
        expect(find.text('2 images'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'look at these');
        await focusField(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();
        expect(sent, [('', 1), ('', 3), ('look at these', null)]);
        expect(
          find.byKey(const ValueKey('composer-staged-images')),
          findsNothing,
        );
        expect(find.text('pasted-image.png'), findsNothing);
        expect(controller.text, isEmpty);
      },
    );

    platformTestWidgets(
      'a failed image keeps only the unsent ones staged (#15)',
      TargetPlatform.windows,
      (tester) async {
        var next = 0;
        const channel = MethodChannel('parallax/clipboard');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              next++;
              return Uint8List.fromList(List.filled(32, next));
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        final sent = <int?>[];
        await mount(
          tester,
          controller: controller,
          onSend: (text, media) async {
            if (media?.bytes.first == 2) throw StateError('offline');
            sent.add(media?.bytes.first);
          },
        );
        await focusField(tester);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump();
        expect(sent, [1]);
        // Image 1 went; 2 and 3 are still staged for a retry.
        expect(find.text('2 images'), findsOneWidget);
        expect(find.textContaining('Could not send'), findsOneWidget);
      },
    );

    platformTestWidgets(
      'Ctrl+V falls back to text paste',
      TargetPlatform.windows,
      (tester) async {
        const channel = MethodChannel('parallax/clipboard');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                return {'text': 'pasted text'};
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await mount(tester, controller: controller, onSend: (_, _) async {});
        await tester.enterText(find.byType(TextField), 'before ');
        await focusField(tester);
        controller.selection = const TextSelection.collapsed(offset: 7);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(controller.text, 'before pasted text');
      },
    );
  });

  group('Windows unified attachment', () {
    platformTestWidgets(
      'one button opens a single picker, no option sheet',
      TargetPlatform.windows,
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        var picks = 0;
        await mount(
          tester,
          controller: controller,
          onSend: (_, _) async {},
          pickFile: () async {
            picks++;
            return null;
          },
        );
        await tester.tap(find.byTooltip('Attach media'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(picks, 1);
        expect(find.text('Photo or video'), findsNothing);
        expect(find.text('Take photo'), findsNothing);
        expect(find.text('Record video'), findsNothing);
      },
    );

    platformTestWidgets(
      'phones keep the separate options sheet',
      TargetPlatform.android,
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await mount(tester, controller: controller, onSend: (_, _) async {});
        await tester.tap(find.byTooltip('Attach media'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Photo or video'), findsOneWidget);
        expect(find.text('Take photo'), findsOneWidget);
        expect(find.text('Record video'), findsOneWidget);
        expect(find.text('File'), findsOneWidget);
      },
    );
  });

  group('resizable two-pane split', () {
    late HomeFakeBackend backend;
    late RoomRouteObserver observer;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      backend = HomeFakeBackend()
        ..roomList = [
          ChatRoom(
            id: '!team:x.org',
            name: 'Team',
            preview: 'hi',
            lastActivity: null,
          ),
          ChatRoom(
            id: '!alex:x.org',
            name: 'Alex',
            preview: 'yo',
            lastActivity: null,
          ),
        ];
      observer = RoomRouteObserver();
    });

    Future<void> pumpWide(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        FeatureSettingsScope(
          preferences: AppearancePreferences(),
          draftStore: MessageDraftStore(),
          child: MaterialApp(
            theme: themeFor(VisualTheme.parallax),
            navigatorObservers: [observer],
            home: InboxScreen(
              backend: backend,
              palette: paletteFor(VisualTheme.parallax),
              style: VisualTheme.parallax,
              onThemeChanged: (_) {},
              roomRoutes: observer,
              backgroundStore: FakeBackgroundStore(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('dragging the divider resizes and persists the list pane', (
      tester,
    ) async {
      await pumpWide(tester);
      final divider = find.byKey(const ValueKey('two-pane-divider'));
      expect(divider, findsOneWidget);
      final before = tester.getRect(divider).left;
      await tester.drag(divider, const Offset(90, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final after = tester.getRect(divider).left;
      expect(after, greaterThan(before + 50));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(kTwoPaneWidthPref), after);
    });

    testWidgets('dragging clamps so both panes stay usable', (tester) async {
      await pumpWide(tester);
      final divider = find.byKey(const ValueKey('two-pane-divider'));
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(divider).left,
        greaterThanOrEqualTo(kTwoPaneMinListWidth),
      );
      await tester.drag(divider, const Offset(4000, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getRect(divider).left,
        lessThanOrEqualTo(1280 - kTwoPaneMinDetailWidth),
      );
    });

    testWidgets('double-click restores the default split', (tester) async {
      await pumpWide(tester);
      final divider = find.byKey(const ValueKey('two-pane-divider'));
      await tester.drag(divider, const Offset(90, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(divider);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(divider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(kTwoPaneWidthPref), isNull);
      expect(tester.getRect(divider).left, 420);
    });
  });

  group('blended title bar', () {
    testWidgets('brand and caption buttons drive the window', (tester) async {
      final calls = <String>[];
      const channel = MethodChannel('window_manager');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'isMaximized') return false;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopTitleBar(palette: paletteFor(VisualTheme.parallax)),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('desktop-title-bar')), findsOneWidget);
      expect(find.text('Parallax'), findsNothing);
      await tester.tap(find.byTooltip('Minimize'));
      await tester.pump();
      await tester.tap(find.byTooltip('Maximize'));
      await tester.pump();
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(calls, containsAll(['minimize', 'maximize', 'close']));
    });
  });

  group('message right-click', () {
    testWidgets('secondary tap opens the action menu, not a reaction', (
      tester,
    ) async {
      var actions = 0;
      var hearts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: DoubleTapReact(
                onDoubleTap: () => hearts++,
                onLongPress: () => actions++,
                child: const Text('hello message'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('hello message'), buttons: kSecondaryButton);
      await tester.pump();
      expect(actions, 1);
      expect(hearts, 0);
    });
  });

  group('desktop window dragging', () {
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

    // Mirrors the signed-in shell: a Scaffold (opaque Material) whose header
    // row sits flush in the title-bar strip, with an action button kept left
    // of the caption-button zone like the two-pane inbox list header.
    Future<void> pumpShell(
      WidgetTester tester, {
      VoidCallback? onAction,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: DesktopShell(
            palette: paletteFor(VisualTheme.parallax),
            child: Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 500,
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Parallax',
                                style: TextStyle(fontSize: 26),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('header-action'),
                              onPressed: onAction ?? () {},
                              icon: const Icon(Icons.search_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox.expand()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('dragging the empty header space moves the window', (
      tester,
    ) async {
      await pumpShell(tester);
      await tester.dragFrom(const Offset(300, 18), const Offset(140, 26));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, contains('startDragging'));
    });

    testWidgets('a small mouse drag moves the window too', (tester) async {
      await pumpShell(tester);
      final gesture = await tester.startGesture(
        const Offset(300, 18),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(12, 4));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, contains('startDragging'));
    });

    testWidgets('dragging an interactive control in the strip resizes, '
        'not moves the window', (tester) async {
      var drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: DesktopShell(
            palette: paletteFor(VisualTheme.parallax),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: kDesktopTitleBarHeight,
                  child: GestureDetector(
                    key: const ValueKey('strip-content-drag'),
                    onHorizontalDragUpdate: (_) => drags++,
                    child: const ColoredBox(color: Color(0xFF222222)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.dragFrom(const Offset(100, 18), const Offset(60, 0));
      await tester.pump();
      expect(drags, greaterThan(0));
      expect(calls, isNot(contains('startDragging')));
    });

    testWidgets('a single click on the strip does nothing', (tester) async {
      await pumpShell(tester);
      await tester.tapAt(const Offset(300, 18));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, isNot(contains('startDragging')));
      expect(calls, isNot(contains('maximize')));
    });

    testWidgets('header buttons stay tappable under the drag strip', (
      tester,
    ) async {
      var actions = 0;
      await pumpShell(tester, onAction: () => actions++);
      await tester.tap(find.byKey(const ValueKey('header-action')));
      await tester.pump();
      expect(actions, 1);
      expect(calls, isNot(contains('startDragging')));
    });

    testWidgets('double-clicking the strip maximizes', (tester) async {
      await pumpShell(tester);
      await tester.tapAt(const Offset(300, 18));
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(const Offset(300, 18));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, contains('maximize'));
    });

    testWidgets('double-clicking a header button does not maximize', (
      tester,
    ) async {
      var actions = 0;
      await pumpShell(tester, onAction: () => actions++);
      final button = find.byKey(const ValueKey('header-action'));
      await tester.tap(button);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(actions, 2);
      expect(calls, isNot(contains('maximize')));
      expect(calls, isNot(contains('startDragging')));
    });

    platformTestWidgets(
      'caption buttons work and do not start a drag',
      TargetPlatform.windows,
      (tester) async {
        await pumpShell(tester);
        await tester.tap(find.byTooltip('Minimize'));
        await tester.pump();
        expect(calls, contains('minimize'));
        calls.clear();
        await tester.dragFrom(const Offset(780, 18), const Offset(-120, 20));
        await tester.pump();
        expect(calls, isNot(contains('startDragging')));
      },
    );
  });
}
