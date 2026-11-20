import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/timeline/timeline_view.dart';

import 'widget_test.dart' show FakeBackend;

const _roomId = '!room:matrix.example';

/// Fake backend whose timeline can be jumped to an event.
class _JumpBackend extends FakeBackend implements TimelineNavigation {
  String? focused;
  int gen = 0;

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    focused = eventId;
    gen++;
  }

  @override
  String? focusedEventIn(String roomId) => focused;

  @override
  int jumpGenerationIn(String roomId) => gen;

  @override
  bool hasNewerThanFocus(String roomId) => false;

  @override
  Future<void> jumpToLatest(String roomId) async => focused = null;
}

ChatEntry _entry(int i) => ChatEntry(
  id: '\$m$i',
  sender: '@alice:example.org',
  senderName: 'Alice',
  body: 'message $i',
  time: DateTime(2026, 11, 20, 12, i),
  mine: false,
);

void main() {
  final palette = paletteFor(VisualTheme.parallax);
  final entries = [for (var i = 0; i < 30; i++) _entry(i)];

  Widget host(_JumpBackend backend) => MaterialApp(
    home: Scaffold(
      body: TimelineView(
        backend: backend,
        roomId: _roomId,
        palette: palette,
        entries: entries,
        compact: false,
        onHeart: (_) {},
        onAction: (_) {},
        onReaction: (_, _) {},
        onLoadOlder: () {},
      ),
    ),
  );

  ScrollController controllerOf(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  testWidgets('a jump scrolls the timeline up to the target', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // m5 is far above the newest messages, off-screen at the bottom.
    final backend = _JumpBackend()
      ..focused = r'$m5'
      ..gen = 1;
    await tester.pumpWidget(host(backend));
    await tester.pumpAndSettle();

    expect(controllerOf(tester).offset, greaterThan(0));
    final rect = tester.getRect(find.text('message 5'));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
  });

  testWidgets('without a jump the timeline stays at the newest messages', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(_JumpBackend()));
    await tester.pumpAndSettle();

    expect(controllerOf(tester).offset, 0);
    expect(find.text('message 29'), findsOneWidget);
  });

  testWidgets('jumping again re-scrolls to the same target', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = _JumpBackend()
      ..focused = r'$m5'
      ..gen = 1;
    await tester.pumpWidget(host(backend));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).offset, greaterThan(0));

    // The reader scrolls back to the bottom, then taps the same quote again.
    controllerOf(tester).jumpTo(0);
    await tester.pumpAndSettle();
    expect(controllerOf(tester).offset, 0);

    backend.gen = 2;
    await tester.pumpWidget(host(backend));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).offset, greaterThan(0));
    expect(find.text('message 5'), findsOneWidget);
  });
}
