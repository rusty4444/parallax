import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/timeline/timeline_view.dart';

import 'widget_test.dart' show FakeBackend;

const _roomId = '!room:matrix.example';

/// Fake backend with a focused timeline, recording every reveal of newer
/// messages.
class _FocusBackend extends FakeBackend implements TimelineNavigation {
  String? focused;
  bool newer = true;
  bool failNewer = false;
  int newerLoads = 0;

  @override
  Future<void> openRoomAt(String roomId, String eventId) async =>
      focused = eventId;

  @override
  String? focusedEventIn(String roomId) => roomId == _roomId ? focused : null;

  @override
  bool hasNewerThanFocus(String roomId) =>
      roomId == _roomId && focused != null && newer;

  @override
  Future<void> jumpToLatest(String roomId) async => focused = null;

  @override
  Future<void> loadNewer(String roomId) async {
    newerLoads++;
    if (failNewer) throw StateError('offline');
  }
}

ChatEntry _entry(String id) => ChatEntry(
  id: id,
  sender: '@alice:example.org',
  senderName: 'Alice',
  body: 'message $id',
  time: DateTime(2026, 11, 20, 12),
  mine: false,
);

void main() {
  final palette = paletteFor(VisualTheme.parallax);

  Future<void> pumpTimeline(
    WidgetTester tester, {
    required _FocusBackend backend,
    required List<ChatEntry> entries,
  }) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();
  }

  testWidgets('scrolling down at the bottom reveals newer messages', (
    tester,
  ) async {
    final backend = _FocusBackend()..focused = r'$target';
    await pumpTimeline(
      tester,
      backend: backend,
      entries: [_entry(r'$older'), _entry(r'$target')],
    );

    // Dragging up scrolls towards newer messages; at the bottom it reveals them.
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();
    expect(backend.newerLoads, 1);

    // One page per gesture: a second pull loads the next page.
    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();
    expect(backend.newerLoads, 2);
  });

  testWidgets('a fling to the bottom also reveals newer messages', (
    tester,
  ) async {
    final backend = _FocusBackend()..focused = r'$target';
    await pumpTimeline(
      tester,
      backend: backend,
      entries: [for (var i = 0; i < 30; i++) _entry('\$m$i')],
    );

    // Move away from the bottom (towards older), then fling back down to it.
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(backend.newerLoads, 0);
    await tester.fling(find.byType(ListView), const Offset(0, -600), 2000);
    await tester.pumpAndSettle();
    expect(backend.newerLoads, 1);
  });

  testWidgets('scrolling towards older messages does not load newer ones', (
    tester,
  ) async {
    final backend = _FocusBackend()..focused = r'$target';
    await pumpTimeline(
      tester,
      backend: backend,
      entries: [for (var i = 0; i < 30; i++) _entry('\$m$i')],
    );

    // Dragging down scrolls towards older messages, away from the bottom.
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    expect(backend.newerLoads, 0);
    // Let the bubble's double-tap window close before the test ends.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('without a focus or newer messages nothing loads', (
    tester,
  ) async {
    final backend = _FocusBackend();
    await pumpTimeline(
      tester,
      backend: backend,
      entries: [_entry(r'$a'), _entry(r'$b')],
    );
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pump();
    expect(backend.newerLoads, 0);

    backend
      ..focused = r'$b'
      ..newer = false;
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pump();
    expect(backend.newerLoads, 0);
  });

  testWidgets('a failed reveal explains itself', (tester) async {
    final backend = _FocusBackend()
      ..focused = r'$target'
      ..failNewer = true;
    await pumpTimeline(
      tester,
      backend: backend,
      entries: [_entry(r'$older'), _entry(r'$target')],
    );

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Couldn’t load newer messages.'), findsOneWidget);
  });
}
