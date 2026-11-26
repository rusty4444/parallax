import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/features/appearance/bubble_colours_screen.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/timeline/overlap_up.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;

final _palette = paletteFor(VisualTheme.parallax);

ChatEntry _entry(
  String id,
  String body, {
  required bool mine,
  List<ChatReaction> reactions = const [],
  int minute = 0,
}) => ChatEntry(
  id: id,
  sender: mine ? '@me:example.org' : '@friend:example.org',
  senderName: mine ? null : 'Friend',
  body: body,
  time: DateTime(2026, 1, 1, 10, minute),
  mine: mine,
  reactions: reactions,
);

Color? _bubbleColour(WidgetTester tester, String text) {
  final box = tester.widget<DecoratedBox>(
    find
        .ancestor(of: find.text(text), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  group('OverlapUp', () {
    testWidgets('takes less height and stays tappable where it overlaps', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 100, height: 50),
                OverlapUp(
                  overlap: 10,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                    child: const SizedBox(
                      key: ValueKey('pill'),
                      width: 40,
                      height: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final pill = tester.getRect(find.byKey(const ValueKey('pill')));
      expect(pill.top, 40);
      expect(tester.getSize(find.byType(OverlapUp)).height, 14);
      // The raised part, over the box above, still hits the pill.
      await tester.tapAt(const Offset(20, 44));
      expect(taps, 1);
    });
  });

  group('reactions on the bubble edge', () {
    testWidgets('hang from the bubble bottom and toggle on a single tap', (
      tester,
    ) async {
      final backend = FakeBackend()
        ..currentUserId = '@me:example.org'
        ..entries = [
          _entry(
            'theirs',
            'Their message',
            mine: false,
            reactions: const [
              ChatReaction(
                emoji: '❤️',
                count: 2,
                mine: true,
                senders: [
                  ChatReactionSender(
                    userId: '@alice:example.org',
                    name: 'Alice',
                  ),
                  ChatReactionSender(userId: '@me:example.org', name: 'Me'),
                ],
              ),
            ],
          ),
          _entry(
            'mine',
            'My message',
            mine: true,
            minute: 1,
            reactions: const [ChatReaction(emoji: '😂', count: 1, mine: false)],
          ),
          _entry('next', 'Next message', mine: true, minute: 2),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: RoomScreen(
            backend: backend,
            palette: _palette,
            roomId: '!r:example.org',
            backgroundStore: FakeBackgroundStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (text, emoji, mine) in [
        ('Their message', '❤️ 2', false),
        ('My message', '😂 1', true),
      ]) {
        final bubble = tester.getRect(
          find
              .ancestor(
                of: find.text(text),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final pill = tester.getRect(find.text(emoji));
        // Straddles the bottom edge, outside the bubble's padding.
        expect(pill.top, lessThan(bubble.bottom), reason: text);
        expect(pill.bottom, greaterThan(bubble.bottom), reason: text);
        // Toward the bubble's outer corner.
        if (mine) {
          expect(pill.right, greaterThan(bubble.right - 40), reason: text);
        } else {
          expect(pill.left, lessThan(bubble.left + 40), reason: text);
        }
      }
      // The next message (same sender, grouped) isn't crowded by the pill.
      final next = tester.getRect(
        find
            .ancestor(
              of: find.text('Next message'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final lastPill = tester.getRect(
        find.byKey(const ValueKey('reaction-mine-😂')),
      );
      expect(next.top - lastPill.bottom, greaterThanOrEqualTo(4));
      // One tap toggles (no double-tap wait inside the bubble).
      await tester.tap(find.text('❤️ 2'));
      await tester.pump();
      expect(backend.lastReaction, '❤️');
      // Hovering names who reacted, not the tap action.
      expect(find.byTooltip('You and Alice reacted with ❤️'), findsOneWidget);
      expect(find.byTooltip('1 person reacted with 😂'), findsOneWidget);
    });
  });

  group('bubble colours', () {
    test('apply to bubbles, with readable automatic text', () {
      const colours = BubbleColours(
        mine: Color(0xFF0A7CFF),
        theirs: Color(0xFFE4E6EB),
      );
      final applied = colours.apply(_palette);
      expect(applied.bubble, const Color(0xFF0A7CFF));
      expect(applied.bubbleText, const Color(0xFFFFFFFF));
      expect(applied.surface, const Color(0xFFE4E6EB));
      expect(applied.foreground, const Color(0xFF141414));
      // Everything outside bubbles keeps the theme.
      expect(applied.background, _palette.background);
      expect(applied.accent, _palette.accent);
      expect(BubbleColours.none.apply(_palette), _palette);
      const custom = BubbleColours(
        mine: Color(0xFF000000),
        mineText: Color(0xFFFFE082),
      );
      expect(custom.apply(_palette).bubbleText, const Color(0xFFFFE082));
    });

    test('round-trip through JSON and ignore malformed values', () {
      const colours = BubbleColours(
        mine: Color(0xFF8E44EC),
        theirsText: Color(0xFF050505),
      );
      expect(BubbleColours.fromJson(colours.toJson()), colours);
      expect(
        BubbleColours.fromJson({'mine': 'blue', 'theirs': '#12345', 'x': 1}),
        BubbleColours.none,
      );
      expect(colourFromHex('0a7cff'), const Color(0xFF0A7CFF));
      expect(colourToHex(const Color(0xFF0A7CFF)), '#0A7CFF');
    });

    test('are saved per room on this device', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = RoomBubbleColourStore(preferences: prefs);
      await store.save('!a:x', const BubbleColours(mine: Color(0xFF27AE60)));
      final fresh = RoomBubbleColourStore(preferences: prefs);
      expect((await fresh.load('!a:x')).mine, const Color(0xFF27AE60));
      expect(await fresh.load('!b:x'), BubbleColours.none);
      await store.save('!a:x', BubbleColours.none);
      expect(prefs.getKeys(), isEmpty);
    });

    testWidgets('a room uses its colours and the screen saves changes', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = RoomBubbleColourStore(preferences: prefs);
      final backend = FakeBackend()
        ..entries = [
          _entry('theirs', 'Their message', mine: false),
          _entry('mine', 'My message', mine: true, minute: 1),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: RoomScreen(
            backend: backend,
            palette: _palette,
            roomId: '!r:example.org',
            backgroundStore: FakeBackgroundStore(),
            bubbleColourStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_bubbleColour(tester, 'My message'), _palette.bubble);

      await tester.tap(find.byTooltip('Room background'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bubble colours…'));
      await tester.pumpAndSettle();
      expect(find.byType(BubbleColoursScreen), findsOneWidget);
      // Your messages: Messenger blue.
      await tester.tap(find.byKey(const ValueKey('swatch-#0A7CFF')).first);
      await tester.pumpAndSettle();
      // Their messages: light grey.
      await tester.tap(find.text('Their messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('swatch-#E4E6EB')).first);
      await tester.pumpAndSettle();
      expect(
        (await RoomBubbleColourStore(
          preferences: prefs,
        ).load('!r:example.org')),
        const BubbleColours(mine: Color(0xFF0A7CFF), theirs: Color(0xFFE4E6EB)),
      );

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_bubbleColour(tester, 'My message'), const Color(0xFF0A7CFF));
      expect(_bubbleColour(tester, 'Their message'), const Color(0xFFE4E6EB));
      final theirText = tester
          .widgetList<RichText>(
            find.descendant(
              of: find
                  .ancestor(
                    of: find.text('Their message'),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
              matching: find.byType(RichText),
            ),
          )
          .firstWhere((r) => r.text.toPlainText() == 'Their message');
      expect(theirText.text.style?.color, const Color(0xFF141414));
    });
  });
}
