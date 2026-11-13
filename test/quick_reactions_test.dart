import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  group('EmojiRecents usage', () {
    test('reaction picks count, composer picks do not', () async {
      final recents = EmojiRecents.instance;
      await recents.record('👍', reaction: true);
      await recents.record('👍', reaction: true);
      await recents.record('❤️', reaction: true);
      await recents.record('😂'); // composer pick, not a reaction
      final usage = await recents.loadUsage();
      expect(usage['👍'], 2);
      expect(usage['❤️'], 1);
      expect(usage.containsKey('😂'), isFalse);
    });

    test('mostUsed orders by count and tops up with defaults', () async {
      final recents = EmojiRecents.instance;
      await recents.record('😂', reaction: true);
      await recents.record('😂', reaction: true);
      await recents.record('👍', reaction: true);
      final row = await recents.mostUsed();
      expect(row.first, '😂');
      expect(row[1], '👍');
      expect(row.length, 8);
      expect(row.toSet().length, row.length); // no duplicates
    });

    test('mostUsed breaks count ties by recency', () async {
      final recents = EmojiRecents.instance;
      await recents.record('😂', reaction: true);
      await recents.record('👍', reaction: true); // same count, more recent
      final row = await recents.mostUsed();
      expect(row.first, '👍');
      expect(row[1], '😂');
    });

    test('usage survives a fresh instance (disk read)', () async {
      await EmojiRecents.instance.record('🎉', reaction: true);
      final fresh = EmojiRecents();
      expect((await fresh.loadUsage())['🎉'], 1);
    });
  });

  group('resolveQuickReactions', () {
    test('defaults to most used', () async {
      await EmojiRecents.instance.record('🔥', reaction: true);
      await EmojiRecents.instance.record('🔥', reaction: true);
      final row = await resolveQuickReactions();
      expect(row.first, '🔥');
    });

    test('recent mode keeps recency order', () async {
      await QuickReactionSettings.instance.setMode(QuickReactionMode.recent);
      await EmojiRecents.instance.record('👍');
      await EmojiRecents.instance.record('❤️');
      final row = await resolveQuickReactions();
      expect(row.first, '❤️');
      expect(row[1], '👍');
    });

    test('manual mode uses the saved list, defaults when empty', () async {
      final settings = QuickReactionSettings.instance;
      await settings.setMode(QuickReactionMode.manual);
      expect(
        await resolveQuickReactions(),
        defaultQuickEmojis.take(manualReactionLimit).toList(),
      );
      await settings.setManual(['🚀', '🎉']);
      expect(await resolveQuickReactions(), ['🚀', '🎉']);
    });
  });

  group('QuickReactionSettings persistence', () {
    test('mode and manual list round-trip through a fresh instance', () async {
      await QuickReactionSettings.instance.setMode(QuickReactionMode.manual);
      await QuickReactionSettings.instance.setManual([
        '🚀',
        '❤️',
        '🎉',
        '😂',
        '👍',
        '😮',
        '🙏',
      ]);
      final fresh = QuickReactionSettings();
      expect(await fresh.mode(), QuickReactionMode.manual);
      // Capped at the row length.
      expect(await fresh.manual(), ['🚀', '❤️', '🎉', '😂', '👍', '😮']);
    });

    test('unknown mode falls back to most used', () async {
      SharedPreferences.setMockInitialValues({
        QuickReactionSettings.modeKey: 'bogus',
      });
      expect(await QuickReactionSettings().mode(), QuickReactionMode.mostUsed);
    });
  });

  group('QuickReactionSettingsSection', () {
    testWidgets('switches mode and edits the manual list', (tester) async {
      SharedPreferences.setMockInitialValues({
        QuickReactionSettings.modeKey: 'manual',
        QuickReactionSettings.manualKey: '["🚀", "🎉"]',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuickReactionSettingsSection(
              palette: paletteFor(VisualTheme.parallax),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quick-reaction-settings')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('manual-reaction-🚀')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-reaction-🎉')), findsOneWidget);

      // Remove a chip; the change persists. The chip's only Icon is its
      // delete button (the label is the emoji Text).
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('manual-reaction-🚀')),
          matching: find.byType(Icon),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('manual-reaction-🚀')), findsNothing);
      expect(await QuickReactionSettings.instance.manual(), ['🎉']);

      // Switch to most used; the manual editor hides and the mode persists.
      await tester.tap(find.text('Most used'));
      await tester.pumpAndSettle();
      expect(
        await QuickReactionSettings.instance.mode(),
        QuickReactionMode.mostUsed,
      );
      expect(find.byKey(const ValueKey('manual-reaction-add')), findsNothing);
    });
  });
}
