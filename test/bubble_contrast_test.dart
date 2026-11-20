import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/appearance/bubble_colours.dart';
import 'package:parallax/features/appearance/colour_picker.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'widget_test.dart' show FakeBackend;

const _roomId = '!room:matrix.example';

/// Bubble colours people pick: the presets plus the mustard yellow that
/// hid "Jump to latest" under the Parallax theme's amber.
const _bubbles = [...bubbleSwatches, Color(0xFFF5C542)];

/// Focuses own messages, so they show "Jumped to this message".
class _FocusBackend extends FakeBackend implements TimelineNavigation {
  String? focused;

  @override
  Future<void> openRoomAt(String roomId, String eventId) async =>
      focused = eventId;

  @override
  String? focusedEventIn(String roomId) => focused;

  @override
  bool hasNewerThanFocus(String roomId) => focused != null;

  @override
  Future<void> jumpToLatest(String roomId) async => focused = null;
}

ChatEntry _entry(String id, {required bool mine, String? replyToId}) =>
    ChatEntry(
      id: id,
      sender: mine ? '@me:example.org' : '@alice:example.org',
      senderName: mine ? null : 'Alice',
      body: 'see https://example.org/menu for tonight',
      time: DateTime(2026, 11, 20, 12),
      mine: mine,
      replyToId: replyToId,
    );

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Every run of text inside [bubble], with the colour it is drawn in and
/// whether it is an icon glyph (judged as a graphic, not text).
List<(String, Color, bool)> _textRuns(WidgetTester tester, Finder bubble) {
  final runs = <(String, Color, bool)>[];
  for (final element
      in find
          .descendant(of: bubble, matching: find.byType(RichText))
          .evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    void visit(InlineSpan span, Color? inherited, String? family) {
      final colour = span.style?.color ?? inherited;
      final font = span.style?.fontFamily ?? family;
      if (span is TextSpan) {
        final text = span.text?.trim() ?? '';
        final icon = font?.contains('Icons') ?? false;
        if (text.isNotEmpty && colour != null) runs.add((text, colour, icon));
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child, colour, font);
        }
      }
    }

    visit(paragraph.text, null, null);
  }
  return runs;
}

double _drawnContrast(Color text, Color fill) =>
    contrastRatio(Color.alphaBlend(text, fill), fill);

void main() {
  group('bubble ink', () {
    test('automatic text reads at 3:1 or better on any bubble', () {
      for (final fill in _bubbles) {
        expect(
          contrastRatio(readableOn(fill), fill),
          greaterThanOrEqualTo(3),
          reason: _hex(fill),
        );
      }
      // Saturated presets keep white text; light ones switch to near-black.
      expect(readableOn(const Color(0xFF0A7CFF)), const Color(0xFFFFFFFF));
      expect(readableOn(const Color(0xFF27AE60)), const Color(0xFF141414));
      expect(readableOn(const Color(0xFFF5C542)), const Color(0xFF141414));
    });

    test('keeps accents legible on every theme and bubble colour', () {
      for (final theme in VisualTheme.values) {
        final base = paletteFor(theme);
        for (final colour in _bubbles) {
          for (final mine in [true, false]) {
            final palette =
                (mine
                        ? BubbleColours(mine: colour)
                        : BubbleColours(theirs: colour))
                    .apply(base);
            final fill = mine ? palette.bubble : palette.surface;
            final text = mine ? palette.bubbleText : palette.foreground;
            final ink = palette.inkOn(fill, text: text);
            final best = math.min(4.5, contrastRatio(readableOn(fill), fill));
            final why =
                '${theme.name} ${mine ? 'mine' : 'theirs'} ${_hex(fill)}';
            expect(
              _drawnContrast(ink.secondary, fill),
              greaterThanOrEqualTo(best - 0.01),
              reason: '$why secondary',
            );
            expect(
              _drawnContrast(ink.muted, fill),
              greaterThanOrEqualTo(best - 0.01),
              reason: '$why muted',
            );
            expect(
              _drawnContrast(ink.accent, fill),
              greaterThanOrEqualTo(2.99),
              reason: '$why accent',
            );
            expect(
              contrastRatio(ink.accentOn, ink.accent),
              greaterThanOrEqualTo(
                math.min(
                      4.5,
                      contrastRatio(readableOn(ink.accent), ink.accent),
                    ) -
                    0.01,
              ),
              reason: '$why accent label',
            );
          }
        }
      }
    });

    test('theme bubbles keep their colours where they already read', () {
      for (final theme in VisualTheme.values) {
        final palette = paletteFor(theme);
        final ink = palette.inkOn(palette.surface, text: palette.foreground);
        expect(ink.secondary, palette.secondary, reason: theme.name);
        expect(ink.muted, palette.muted, reason: theme.name);
      }
    });

    test('accents follow the bubble text, even a hard-to-read custom one', () {
      const green = Color(0xFF27AE60);
      // Near-black body text on green: accents darken too, never turn white.
      final dark = legibleOn(
        green,
        const Color(0xFFFFB238),
        toward: readableOn(green),
      );
      expect(dark.computeLuminance(), lessThan(green.computeLuminance()));
      expect(contrastRatio(dark, green), greaterThanOrEqualTo(4.49));
      // A custom text colour that barely shows still gets readable accents.
      const yellow = Color(0xFFF5C542);
      final accent = legibleOn(
        yellow,
        const Color(0xFFFFB238),
        toward: const Color(0xFFFFD54F),
      );
      expect(contrastRatio(accent, yellow), greaterThanOrEqualTo(4.49));
    });
  });

  group('bubble text', () {
    Future<void> pumpRoom(
      WidgetTester tester, {
      required AppPalette palette,
      required BubbleColours colours,
      required List<ChatEntry> entries,
      required ChatBackend backend,
    }) async {
      tester.view
        ..physicalSize = const Size(420, 1400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // A fresh tree per colour: buttons animate text colour changes.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BubbleColoursScope(
              colours: colours,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final entry in entries)
                    MessageBubble(
                      key: ValueKey(entry.id),
                      entry: entry,
                      backend: backend,
                      roomId: _roomId,
                      palette: palette,
                      group: false,
                      onHeart: () {},
                      onAction: () {},
                      onReaction: (_) {},
                      entries: entries,
                      replyPreview: entry.replyToId == null
                          ? null
                          : entries.firstWhere((e) => e.id == entry.replyToId),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Finder bubbleOf(String id) => find
        .descendant(
          of: find.byKey(ValueKey(id)),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius != null &&
                (w.decoration as BoxDecoration).color != null,
          ),
        )
        .first;

    Color fillOf(WidgetTester tester, Finder bubble) =>
        ((tester.widget<DecoratedBox>(bubble)).decoration as BoxDecoration)
            .color!;

    testWidgets('"Jump to latest" stays legible on a yellow bubble', (
      tester,
    ) async {
      // The reported case: Parallax theme, own messages in mustard yellow.
      final backend = _FocusBackend()
        ..currentUserId = '@me:example.org'
        ..focused = r'$mine';
      await pumpRoom(
        tester,
        palette: paletteFor(VisualTheme.parallax),
        colours: const BubbleColours(mine: Color(0xFFF5C542)),
        entries: [_entry(r'$mine', mine: true)],
        backend: backend,
      );
      expect(find.text('Jump to latest'), findsOneWidget);
      final bubble = bubbleOf(r'$mine');
      final fill = fillOf(tester, bubble);
      final colour = tester
          .widget<RichText>(
            find.descendant(
              of: find.text('Jump to latest'),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style!
          .color!;
      final chip = Color.alphaBlend(
        paletteFor(
          VisualTheme.parallax,
        ).inkOn(fill).accent.withValues(alpha: 0.12),
        fill,
      );
      expect(_drawnContrast(colour, chip), greaterThanOrEqualTo(4.5));
    });

    for (final theme in VisualTheme.values) {
      testWidgets('every word in a bubble reads on it (${theme.name})', (
        tester,
      ) async {
        final palette = paletteFor(theme);
        final failures = <String>[];
        for (final colour in _bubbles) {
          final backend = _FocusBackend()
            ..currentUserId = '@me:example.org'
            ..focused = r'$mine';
          final entries = [
            _entry(r'$theirs', mine: false),
            _entry(r'$reply', mine: false, replyToId: r'$theirs'),
            _entry(r'$mine', mine: true, replyToId: r'$theirs'),
          ];
          await pumpRoom(
            tester,
            palette: palette,
            colours: BubbleColours(mine: colour, theirs: colour),
            entries: entries,
            backend: backend,
          );
          for (final entry in entries) {
            final bubble = bubbleOf(entry.id);
            final fill = fillOf(tester, bubble);
            // Accent-coloured text (sender names, links, buttons) aims for
            // 4.5:1, or the bubble's own text contrast when that is lower;
            // faded details such as times get at least 3:1.
            final best = math.min(4.5, contrastRatio(readableOn(fill), fill));
            final runs = _textRuns(tester, bubble);
            expect(runs, isNotEmpty);
            for (final (text, ink, icon) in runs) {
              final contrast = _drawnContrast(ink, fill);
              final faded = ink.a < 1 || RegExp(r'^\d').hasMatch(text);
              final floor = icon || faded ? 3.0 : best;
              if (contrast < math.min(floor, best) - 0.01) {
                failures.add(
                  '${_hex(colour)} ${entry.id} ${icon ? 'icon' : '"$text"'} '
                  '${_hex(ink)}@${ink.a.toStringAsFixed(2)} '
                  '${contrast.toStringAsFixed(2)}:1',
                );
              }
            }
          }
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
      });
    }
  });
}
