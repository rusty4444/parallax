import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/timeline/message_hover_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, room;
import 'windows_desktop_ux_test.dart' show platformTestWidgets;

const _childKey = ValueKey('hover-target');
const _barKey = ValueKey('message-hover-bar');

ChatEntry _entry(
  String id, {
  required bool mine,
  String body = 'Hover target',
}) => ChatEntry(
  id: id,
  sender: mine ? '@me:s' : '@alice:s',
  senderName: mine ? 'Me' : 'Alice',
  body: body,
  time: DateTime(2026, 11, 20, 10, 11),
  mine: mine,
  // Real event content, so forward/pin hooks see a forwardable message.
  content: {'msgtype': 'm.text', 'body': body},
);

MessageActionItem _item(String id, IconData icon, VoidCallback onTap) =>
    MessageActionItem(
      id: id,
      icon: icon,
      label: id,
      onSelected: (_) async => onTap(),
    );

/// A mouse pointer resting at [location] (hover, no buttons pressed).
Future<TestGesture> hover(WidgetTester tester, Offset location) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: location);
  await tester.pump();
  return gesture;
}

Future<void> leave(WidgetTester tester, TestGesture gesture) async {
  await gesture.removePointer();
  // Past the hide grace period, so the bar (and its tooltips) are disposed.
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  group('hover bar widget', () {
    final palette = paletteFor(VisualTheme.parallax);

    Future<void> pumpTarget(
      WidgetTester tester,
      List<MessageActionItem> actions,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MessageHoverMenu(
              actionsBuilder: () => actions,
              palette: palette,
              child: Container(
                key: _childKey,
                width: 200,
                height: 60,
                color: palette.surface,
              ),
            ),
          ),
        ),
      ),
    );

    platformTestWidgets(
      'floats above the message top-right without moving it',
      TargetPlatform.macOS,
      (tester) async {
        await pumpTarget(tester, [
          _item('reply', Icons.reply_rounded, () {}),
          _item('more', Icons.more_horiz_rounded, () {}),
        ]);
        final before = tester.getRect(find.byKey(_childKey));
        expect(find.byKey(_barKey), findsNothing);

        final gesture = await hover(tester, before.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));
        // Anchored to the message's top-right corner, fully above it.
        expect(bar.right, closeTo(before.right, 0.01));
        expect(bar.bottom, closeTo(before.top - 6, 0.01));
        expect(bar.height, 38);
        // The message itself never moves or resizes.
        expect(tester.getRect(find.byKey(_childKey)), before);
        await leave(tester, gesture);
        expect(find.byKey(_barKey), findsNothing);
      },
    );

    platformTestWidgets(
      'stays open while the pointer rests on the bar',
      TargetPlatform.windows,
      (tester) async {
        await pumpTarget(tester, [_item('reply', Icons.reply_rounded, () {})]);
        final target = tester.getRect(find.byKey(_childKey));
        final gesture = await hover(tester, target.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));

        // Leaving the message starts the grace period; reaching the bar
        // within it keeps the menu open.
        await gesture.moveTo(bar.center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_barKey), findsOneWidget);

        // Leaving both closes it.
        await gesture.moveTo(const Offset(5, 5));
        await tester.pump();
        expect(find.byKey(_barKey), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(_barKey), findsNothing);
        await leave(tester, gesture);
      },
    );

    platformTestWidgets('runs the action and closes', TargetPlatform.macOS, (
      tester,
    ) async {
      var taps = 0;
      await pumpTarget(tester, [
        _item('reply', Icons.reply_rounded, () => taps++),
      ]);
      final gesture = await hover(
        tester,
        tester.getRect(find.byKey(_childKey)).center,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hover-action-reply')));
      await tester.pump();
      expect(taps, 1);
      expect(find.byKey(_barKey), findsNothing);
      await leave(tester, gesture);
    });

    platformTestWidgets('no bar without actions', TargetPlatform.macOS, (
      tester,
    ) async {
      await pumpTarget(tester, const []);
      final gesture = await hover(
        tester,
        tester.getRect(find.byKey(_childKey)).center,
      );
      await tester.pump();
      expect(find.byKey(_barKey), findsNothing);
      await leave(tester, gesture);
    });

    platformTestWidgets(
      'touch platforms get no hover bar',
      TargetPlatform.android,
      (tester) async {
        await pumpTarget(tester, [_item('reply', Icons.reply_rounded, () {})]);
        final gesture = await hover(
          tester,
          tester.getRect(find.byKey(_childKey)).center,
        );
        await tester.pump();
        expect(find.byKey(_barKey), findsNothing);
        expect(find.byType(MessageHoverMenu), findsOneWidget);
        await leave(tester, gesture);
      },
    );
  });

  group('room timeline hover menu', () {
    Future<FeaturesBackend> pumpRoom(
      WidgetTester tester,
      ChatEntry entry,
    ) async {
      final backend = FeaturesBackend()..entries = [entry];
      await tester.pumpWidget(room(backend, Drafts()));
      await tester.pumpAndSettle();
      return backend;
    }

    platformTestWidgets(
      'own message offers react, reply, thread, edit, pin and more',
      TargetPlatform.macOS,
      (tester) async {
        await pumpRoom(tester, _entry(r'$own', mine: true));
        final gesture = await hover(
          tester,
          tester.getCenter(find.text('Hover target')),
        );
        await tester.pump();
        for (final id in [
          'hover.react',
          'hover.reply',
          'hover.thread',
          'hover.edit',
          'reactions.pin',
          'hover.more',
        ]) {
          expect(
            find.byKey(ValueKey('hover-action-$id')),
            findsOneWidget,
            reason: id,
          );
        }

        await tester.tap(
          find.byKey(const ValueKey('hover-action-hover.reply')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Replying to Me: Hover target'), findsOneWidget);
        expect(find.byKey(_barKey), findsNothing);
        await leave(tester, gesture);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    platformTestWidgets(
      "someone else's message has no edit, and more opens the full sheet",
      TargetPlatform.macOS,
      (tester) async {
        await pumpRoom(tester, _entry(r'$other', mine: false));
        final gesture = await hover(
          tester,
          tester.getCenter(find.text('Hover target')),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('hover-action-hover.edit')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('hover-action-hover.reply')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('hover-action-hover.more')));
        await tester.pumpAndSettle();
        // The long-press action sheet, unchanged.
        expect(find.text('Forward'), findsOneWidget);
        expect(find.byKey(_barKey), findsNothing);
        await leave(tester, gesture);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    platformTestWidgets(
      'edit loads the message into the composer',
      TargetPlatform.windows,
      (tester) async {
        await pumpRoom(tester, _entry(r'$own', mine: true));
        final gesture = await hover(
          tester,
          tester.getCenter(find.text('Hover target')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('hover-action-hover.edit')));
        await tester.pumpAndSettle();
        expect(find.text('Editing: Hover target'), findsOneWidget);
        await leave(tester, gesture);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );

    platformTestWidgets('Windows shows the same bar', TargetPlatform.windows, (
      tester,
    ) async {
      await pumpRoom(tester, _entry(r'$other', mine: false));
      final gesture = await hover(
        tester,
        tester.getCenter(find.text('Hover target')),
      );
      await tester.pump();
      expect(find.byKey(_barKey), findsOneWidget);
      await leave(tester, gesture);
      expect(find.byKey(_barKey), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    platformTestWidgets(
      'Android keeps long press only',
      TargetPlatform.android,
      (tester) async {
        await pumpRoom(tester, _entry(r'$own', mine: true));
        final gesture = await hover(
          tester,
          tester.getCenter(find.text('Hover target')),
        );
        await tester.pump();
        expect(find.byKey(_barKey), findsNothing);
        await leave(tester, gesture);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  });

  group('hover bar viewport placement', () {
    final palette = paletteFor(VisualTheme.parallax);

    /// A timeline-like viewport below a fixed header: the bar must stay
    /// inside the ListView's bounds, never paint over the header.
    Future<void> pumpTimeline(
      WidgetTester tester, {
      required double topPad,
      required double itemHeight,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  height: 60,
                  child: Center(child: Text('Header')),
                ),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.only(top: topPad),
                    children: [
                      MessageHoverMenu(
                        actionsBuilder: () => [
                          _item('reply', Icons.reply_rounded, () {}),
                        ],
                        palette: palette,
                        child: Container(
                          key: _childKey,
                          height: itemHeight,
                          color: palette.surface,
                        ),
                      ),
                      // Filler so the timeline is taller than the viewport
                      // and can actually scroll.
                      const SizedBox(height: 900),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    platformTestWidgets(
      'a message near the top flips the bar below it, not over the header',
      TargetPlatform.windows,
      (tester) async {
        await pumpTimeline(tester, topPad: 10, itemHeight: 60);
        final item = tester.getRect(find.byKey(_childKey));
        final gesture = await hover(tester, item.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));
        // Below the message's bottom edge, inside the viewport (which
        // starts at y=60, below the header).
        expect(bar.top, closeTo(item.bottom + 6, 0.01));
        expect(bar.top, greaterThanOrEqualTo(60));
        expect(bar.right, closeTo(item.right, 0.01));
        await leave(tester, gesture);
      },
    );

    platformTestWidgets(
      'with room above, the bar stays above the message',
      TargetPlatform.macOS,
      (tester) async {
        await pumpTimeline(tester, topPad: 120, itemHeight: 60);
        final item = tester.getRect(find.byKey(_childKey));
        final gesture = await hover(tester, item.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));
        expect(bar.bottom, closeTo(item.top - 6, 0.01));
        await leave(tester, gesture);
      },
    );

    platformTestWidgets(
      'scrolling a hovered message to the top flips the bar below',
      TargetPlatform.windows,
      (tester) async {
        await pumpTimeline(tester, topPad: 120, itemHeight: 60);
        final gesture = await hover(
          tester,
          tester.getRect(find.byKey(_childKey)).center,
        );
        await tester.pump();
        expect(
          tester.getRect(find.byKey(_barKey)).bottom,
          closeTo(tester.getRect(find.byKey(_childKey)).top - 6, 0.01),
        );
        await tester.drag(find.byType(ListView), const Offset(0, -100));
        await tester.pump();
        // Follow the message so the hover stays alive.
        final item = tester.getRect(find.byKey(_childKey));
        await gesture.moveTo(item.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));
        expect(bar.top, closeTo(item.bottom + 6, 0.01));
        await leave(tester, gesture);
      },
    );

    platformTestWidgets(
      'a message partially scrolled out of the top gets the bar at its '
      'visible bottom',
      TargetPlatform.windows,
      (tester) async {
        await pumpTimeline(tester, topPad: 0, itemHeight: 100);
        final gesture = await hover(
          tester,
          tester.getRect(find.byKey(_childKey)).center,
        );
        await tester.pump();
        await tester.drag(find.byType(ListView), const Offset(0, -50));
        await tester.pump();
        final item = tester.getRect(find.byKey(_childKey));
        expect(item.top, lessThan(60)); // partially out of frame
        await gesture.moveTo(item.center);
        await tester.pump();
        final bar = tester.getRect(find.byKey(_barKey));
        expect(bar.top, closeTo(item.bottom + 6, 0.01));
        expect(bar.top, greaterThanOrEqualTo(60));
        await leave(tester, gesture);
      },
    );

    platformTestWidgets(
      'a message taller than the viewport hides the bar',
      TargetPlatform.macOS,
      (tester) async {
        await pumpTimeline(tester, topPad: 0, itemHeight: 600);
        final gesture = await hover(
          tester,
          tester.getRect(find.byKey(_childKey)).center,
        );
        await tester.pump();
        expect(find.byKey(_barKey), findsNothing);
        await leave(tester, gesture);
      },
    );
  });
}
