import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' as fixtures;

class HistoryBackend extends fixtures.FeaturesBackend {
  Completer<void>? historyGate;
  bool olderAvailable = true;
  bool historyLoading = false;
  int historyRequests = 0;

  @override
  bool get canLoadOlder => olderAvailable;

  @override
  bool get loadingHistory => historyLoading;

  @override
  Future<void> loadOlder(String roomId) async {
    historyRequests++;
    historyLoading = true;
    notifyListeners();
    try {
      await historyGate?.future;
    } finally {
      historyLoading = false;
      notifyListeners();
    }
  }
}

List<ChatEntry> historyEntries(int count) => List.generate(
  count,
  (index) => ChatEntry(
    id: 'message-$index',
    sender: '@friend:example.org',
    body: 'Message $index',
    time: DateTime(2026).add(Duration(minutes: index * 10)),
    mine: false,
  ),
);

Finder historyScrollable() => find.descendant(
  of: find.byType(ListView),
  matching: find.byType(Scrollable),
);

Future<void> revealHistoryControl(WidgetTester tester) async {
  final scrollable = tester.state<ScrollableState>(historyScrollable());
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
  await tester.pump();
  expect(find.text('Load earlier messages'), findsOneWidget);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  testWidgets(
    'room timeline pull-down paginates when visible, stays single-flight and keeps tap',
    (tester) async {
      final backend = HistoryBackend()..entries = historyEntries(40);
      await tester.pumpWidget(fixtures.room(backend, fixtures.Drafts()));
      await tester.pumpAndSettle();

      final list = find.byType(ListView);
      expect(backend.historyRequests, 0);
      expect(find.text('Load earlier messages'), findsNothing);

      // Off-screen control: pulling down does not load history.
      await tester.drag(list, const Offset(0, 80));
      await tester.pump();
      expect(backend.historyRequests, 0);

      // Ordinary scroll or ballistic fling that brings the control into view
      // from off-screen must not auto-paginate.
      final scrollable = tester.state<ScrollableState>(historyScrollable());
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent - 160);
      await tester.pump();
      expect(find.text('Load earlier messages'), findsNothing);
      await tester.drag(list, const Offset(0, 260));
      await tester.pumpAndSettle();
      expect(find.text('Load earlier messages'), findsOneWidget);
      expect(backend.historyRequests, 0);

      scrollable.position.jumpTo(scrollable.position.maxScrollExtent - 220);
      await tester.pump();
      await tester.fling(list, const Offset(0, 320), 1400);
      await tester.pumpAndSettle();
      expect(find.text('Load earlier messages'), findsOneWidget);
      expect(backend.historyRequests, 0);

      // Upward swipe while visible does not load history.
      await tester.drag(list, const Offset(0, -80));
      await tester.pump();
      expect(backend.historyRequests, 0);

      // Downward pull while visible triggers single-flight pagination.
      backend.historyGate = Completer<void>();
      await revealHistoryControl(tester);
      await tester.drag(
        find.text('Load earlier messages'),
        const Offset(0, 80),
      );
      await tester.pump();
      expect(backend.historyRequests, 1);
      expect(find.text('Loading…'), findsOneWidget);

      await tester.drag(find.text('Loading…'), const Offset(0, 80));
      await tester.pump();
      expect(backend.historyRequests, 1);

      backend.historyGate!.complete();
      await tester.pump();
      expect(find.text('Load earlier messages'), findsOneWidget);

      // Manual activation continues to work.
      await tester.tap(find.text('Load earlier messages'));
      await tester.pump();
      expect(backend.historyRequests, 2);
    },
  );

  testWidgets(
    'empty room state supports pull-down and manual tap when older history exists',
    (tester) async {
      final backend = HistoryBackend()..entries = [];
      await tester.pumpWidget(fixtures.room(backend, fixtures.Drafts()));
      await tester.pumpAndSettle();

      expect(find.text('Start something good.'), findsOneWidget);
      expect(find.text('Load earlier messages'), findsOneWidget);

      // Upward swipe does nothing.
      await tester.drag(
        find.text('Start something good.'),
        const Offset(0, -80),
      );
      await tester.pump();
      expect(backend.historyRequests, 0);

      // Downward pull triggers once and respects single-flight.
      backend.historyGate = Completer<void>();
      await tester.drag(
        find.text('Start something good.'),
        const Offset(0, 80),
      );
      await tester.pump();
      expect(backend.historyRequests, 1);
      expect(find.text('Loading…'), findsOneWidget);

      await tester.drag(
        find.text('Start something good.'),
        const Offset(0, 80),
      );
      await tester.pump();
      expect(backend.historyRequests, 1);

      backend.historyGate!.complete();
      await tester.pump();
      await tester.tap(find.text('Load earlier messages'));
      await tester.pump();
      expect(backend.historyRequests, 2);
    },
  );
}
