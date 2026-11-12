import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/timeline/bubble_column.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'widget_test.dart' show FakeBackend;

const _screen = Size(400, 800);

void main() {
  group('BubbleColumn', () {
    Future<void> pump(
      WidgetTester tester,
      List<Widget> children, {
      double maxWidth = 300,
      TextDirection direction = TextDirection.ltr,
    }) => tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: BubbleColumn(
              key: const ValueKey('column'),
              children: children,
            ),
          ),
        ),
      ),
    );

    testWidgets('is as wide as its widest child, not the space it has', (
      tester,
    ) async {
      await pump(tester, [
        const SizedBox(key: ValueKey('a'), width: 80, height: 20),
        const SizedBox(key: ValueKey('b'), width: 120, height: 10),
      ]);
      expect(
        tester.getSize(find.byKey(const ValueKey('column'))),
        const Size(120, 30),
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('a'))), Offset.zero);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('b'))),
        const Offset(0, 20),
      );
    });

    testWidgets('puts BubbleEnd children at the trailing edge', (tester) async {
      await pump(tester, [
        const SizedBox(key: ValueKey('text'), width: 150, height: 20),
        const BubbleEnd(
          child: SizedBox(key: ValueKey('time'), width: 40, height: 10),
        ),
      ]);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('time'))),
        const Offset(110, 20),
      );

      await pump(direction: TextDirection.rtl, tester, [
        const SizedBox(key: ValueKey('text'), width: 150, height: 20),
        const BubbleEnd(
          child: SizedBox(key: ValueKey('time'), width: 40, height: 10),
        ),
      ]);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('time'))),
        const Offset(0, 20),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('text'))),
        Offset.zero,
      );
    });

    testWidgets('a wide child is capped at the maximum width', (tester) async {
      await pump(maxWidth: 100, tester, [
        const SizedBox(key: ValueKey('wide'), width: 500, height: 10),
      ]);
      expect(tester.getSize(find.byKey(const ValueKey('column'))).width, 100);
    });

    testWidgets('lays out LayoutBuilder bodies (images) without intrinsics', (
      tester,
    ) async {
      await pump(tester, [
        LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            key: const ValueKey('image'),
            width: constraints.maxWidth < 240 ? constraints.maxWidth : 240,
            height: 50,
          ),
        ),
        const BubbleEnd(child: SizedBox(width: 40, height: 10)),
      ]);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const ValueKey('column'))).width, 240);
    });
  });

  group('message bubbles', () {
    final palette = paletteFor(VisualTheme.parallax);
    final backend = FakeBackend()..currentUserId = '@me:example.org';

    Future<Rect> bubble(WidgetTester tester, ChatEntry entry) async {
      tester.view
        ..physicalSize = _screen
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: EdgeInsets.zero,
              children: [
                MessageBubble(
                  entry: entry,
                  backend: backend,
                  roomId: '!r:example.org',
                  palette: palette,
                  group: false,
                  onHeart: () {},
                  onAction: () {},
                  onReaction: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      // The bubble is the DecoratedBox around the BubbleColumn.
      return tester.getRect(
        find
            .ancestor(
              of: find.byType(BubbleColumn),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
    }

    ChatEntry message(String body, {required bool mine}) => ChatEntry(
      id: r'$e',
      sender: mine ? '@me:example.org' : '@bo:example.org',
      body: body,
      time: DateTime(2026, 11, 12, 21, 13),
      mine: mine,
    );

    const long =
        'This is a long message that wraps over several lines so the bubble '
        'reaches its widest, which for your own messages must leave a gap on '
        'the left like other people’s bubbles leave on the right.';

    /// Width of the widest rendered line containing one of [texts].
    double widest(WidgetTester tester, List<String> texts) {
      var width = 0.0;
      for (final element
          in find
              .descendant(
                of: find.byType(BubbleColumn),
                matching: find.byType(RichText),
              )
              .evaluate()) {
        final plain = (element.widget as RichText).text.toPlainText();
        if (texts.any(plain.contains)) {
          final size = element.size!;
          if (size.width > width) width = size.width;
        }
      }
      return width;
    }

    testWidgets('a short message of yours is short and on the right', (
      tester,
    ) async {
      final rect = await bubble(tester, message('90ml f wee', mine: true));
      expect(rect.right, _screen.width);
      // As wide as its text plus 14 px padding each side.
      expect(rect.width, closeTo(widest(tester, ['90ml f wee']) + 28, 0.5));
      expect(rect.width, lessThan(_screen.width * 0.5));
    });

    testWidgets('a long message of yours stops well short of the left', (
      tester,
    ) async {
      final rect = await bubble(tester, message(long, mine: true));
      final max = bubbleMaxWidth(_screen.width, mine: true, avatars: false);
      expect(rect.right, _screen.width);
      expect(rect.width, lessThanOrEqualTo(max));
      expect(rect.width, greaterThan(max * 0.8));
      // At least the avatar column plus 17% of the screen stays free.
      expect(rect.left, greaterThanOrEqualTo(_screen.width * 0.17 + 40));
    });

    testWidgets('others\' short messages are short too, after the avatar', (
      tester,
    ) async {
      final rect = await bubble(tester, message('F wee 70ml', mine: false));
      expect(rect.left, 40);
      // The widest line (here the sender's name) plus padding; the border is
      // drawn inside the bubble.
      expect(
        rect.width,
        closeTo(widest(tester, ['F wee 70ml', 'bo:example.org']) + 28, 0.5),
      );
      expect(rect.width, lessThan(_screen.width * 0.6));
    });

    testWidgets('the time sits at the bubble\'s right edge', (tester) async {
      final rect = await bubble(tester, message('ok', mine: true));
      final time = tester.getRect(find.text('9:13 PM'));
      expect(rect.right - time.right, closeTo(14, 0.5));
      // The bubble is wide enough for the time, even for "ok".
      expect(rect.width, greaterThanOrEqualTo(time.width + 28));
    });

    test('bubbles stay readable on tablets', () {
      expect(bubbleMaxWidth(1200, mine: true, avatars: false), 520);
      expect(bubbleMaxWidth(1200, mine: false, avatars: true), 520);
      expect(
        bubbleMaxWidth(400, mine: false, avatars: false),
        closeTo(332, 0.01),
      );
    });
  });
}
