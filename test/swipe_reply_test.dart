import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/timeline/swipe_reply.dart';

void main() {
  test('edge fade stays a band on short and tall rows', () {
    final short = swipeReplyGradient(const Color(0xFFFF5A36), 20);
    final tall = swipeReplyGradient(const Color(0xFFFF5A36), 1000);
    final unknown = swipeReplyGradient(
      const Color(0xFFFF5A36),
      double.infinity,
    );
    expect(short.stops![1], 0.4);
    expect(short.stops![2], closeTo(0.6, 0.0000001));
    expect(tall.stops![1], 0.08);
    expect(tall.stops![2], closeTo(0.92, 0.0000001));
    expect(unknown.stops![1], 0.22);
    expect(unknown.stops![2], closeTo(0.78, 0.0000001));
    expect(short.colors.first.a, 0);
    expect(short.colors[1].a, closeTo(0.12, 0.001));
  });

  testWidgets('swipe reply tint fades at the top and bottom', (tester) async {
    final palette = paletteFor(VisualTheme.parallax);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeReply(
            key: const ValueKey('swipe'),
            palette: palette,
            onReply: () {},
            child: const SizedBox(width: 240, height: 80),
          ),
        ),
      ),
    );
    // The reveal is only mounted while the row is away from rest.
    await tester.drag(find.byType(SwipeReply), const Offset(36, 0));
    await tester.pump();

    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(Dismissible),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = decorated.decoration as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    final fade = swipeReplyEdgeFade / 80;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last.a, 0);
    expect(gradient.colors[1].a, closeTo(0.12, 0.001));
    expect(gradient.colors[1], gradient.colors[2]);
    expect(gradient.colors.first, gradient.colors.last);
    expect(gradient.stops, [0, fade, 1 - fade, 1]);
    expect(find.text('Reply'), findsOneWidget);
  });
}
