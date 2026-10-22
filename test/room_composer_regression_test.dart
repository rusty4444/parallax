import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/rich_message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' as fixtures;

RichMessageComposer composer(WidgetTester tester) =>
    tester.widget<RichMessageComposer>(find.byType(RichMessageComposer));

class ClearingDrafts extends fixtures.Drafts {
  final clearStarted = Completer<void>();
  final clearGate = Completer<void>();

  @override
  Future<void> write(String accountKey, String roomId, String text) async {
    if (text.isEmpty) {
      if (!clearStarted.isCompleted) clearStarted.complete();
      await clearGate.future;
    }
    await super.write(accountKey, roomId, text);
  }
}

ChatEntry entry(String id, String body, {bool mine = false}) => ChatEntry(
  id: id,
  sender: mine ? '@me:s' : '@friend:s',
  body: body,
  time: DateTime(2026),
  mine: mine,
);

Future<void> action(WidgetTester tester, String body, String action) async {
  await tester.longPress(find.text(body).first);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(action),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

Future<void> insertGif(WidgetTester tester) async {
  tester
      .widget<TextField>(find.byType(TextField).last)
      .contentInsertionConfiguration!
      .onContentInserted(
        KeyboardInsertedContent(
          mimeType: 'image/gif',
          uri: 'content://keyboard/item',
          data: Uint8List.fromList([1, 2, 3]),
        ),
      );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'same-body new Reply survives an already-started accepted draft clear',
    (tester) async {
      final backend = fixtures.FeaturesBackend()
        ..entries = [
          entry('first', 'First target'),
          entry('next', 'Next target'),
        ];
      final drafts = ClearingDrafts();
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      await action(tester, 'First target', 'Reply');
      await tester.enterText(find.byType(TextField).last, 'Same body');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();
      expect(drafts.clearStarted.isCompleted, isTrue);
      await tester.longPress(find.text('Next target'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      drafts.clearGate.complete();
      await tester.pumpAndSettle();
      expect(composer(tester).controller.text, 'Same body');
      expect(
        find.textContaining('Replying to @friend:s: Next target'),
        findsOneWidget,
      );
      expect(drafts.values['account-a/${fixtures.roomId}'], 'Same body');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      expect(composer(tester).controller.text, 'Same body');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'parent send leaves edit controller untouched until composer ack',
    (tester) async {
      final backend = fixtures.FeaturesBackend()
        ..entries = [entry('edit', 'Edit original', mine: true)];
      final drafts = fixtures.Drafts()
        ..values['account-a/${fixtures.roomId}'] = 'Ordinary draft';
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      await action(tester, 'Edit original', 'Edit message');
      await tester.enterText(find.byType(TextField).last, 'Accepted edit');
      final input = composer(tester);
      await input.onSend('Accepted edit', null);
      expect(input.controller.text, 'Accepted edit');
      expect(drafts.values['account-a/${fixtures.roomId}'], 'Ordinary draft');
      // Exercise the documented post-ack boundary independently of the button.
      input.controller.clear();
      input.onAcknowledged!(true);
      await tester.pumpAndSettle();
      expect(input.controller.text, 'Ordinary draft');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'same-route edit back to identical body survives queue acceptance',
    (tester) async {
      final backend = fixtures.FeaturesBackend()..queueGate = Completer<void>();
      final drafts = fixtures.Drafts();
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Same body');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Intermediate');
      await tester.enterText(find.byType(TextField).last, 'Same body');
      await tester.pump(const Duration(milliseconds: 500));
      backend.queueGate!.complete();
      await tester.pumpAndSettle();
      expect(composer(tester).controller.text, 'Same body');
      expect(drafts.values['account-a/${fixtures.roomId}'], 'Same body');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      expect(composer(tester).controller.text, 'Same body');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'accepted identical edit preserves visible and persisted normal draft',
    (tester) async {
      final backend = fixtures.FeaturesBackend()
        ..entries = [entry('edit-id', 'Edit original', mine: true)];
      final drafts = fixtures.Drafts()
        ..values['account-a/${fixtures.roomId}'] = 'Normal draft';
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      await action(tester, 'Edit original', 'Edit message');
      await tester.enterText(find.byType(TextField).last, 'Normal draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(backend.queuedEdit, 'edit-id');
      expect(composer(tester).controller.text, 'Normal draft');
      expect(find.textContaining('Editing:'), findsNothing);
      await tester.pump(const Duration(milliseconds: 500));
      expect(drafts.values['account-a/${fixtures.roomId}'], 'Normal draft');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      expect(composer(tester).controller.text, 'Normal draft');
    },
  );

  for (final sameBody in [false, true]) {
    testWidgets(
      'old route acceptance preserves reopened ${sameBody ? 'identical re-edited' : 'new'} draft',
      (tester) async {
        final backend = fixtures.FeaturesBackend()
          ..queueGate = Completer<void>();
        final drafts = fixtures.Drafts();
        const first = 'First queued text';
        final replacement = sameBody ? first : 'New draft after reopening';
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, first);
        await tester.pump();
        await tester.tap(find.byTooltip('Send message'));
        await tester.pump();
        expect(backend.queuedText, first);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).last,
          'Intermediate typing',
        );
        await tester.enterText(find.byType(TextField).last, replacement);
        await tester.pump(const Duration(milliseconds: 500));
        expect(drafts.values['account-a/${fixtures.roomId}'], replacement);
        backend.queueGate!.complete();
        await tester.pumpAndSettle();
        expect(composer(tester).controller.text, replacement);
        expect(drafts.values['account-a/${fixtures.roomId}'], replacement);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        expect(composer(tester).controller.text, replacement);
      },
    );
  }

  testWidgets(
    'Reply and context cancellation retain staged GIF until explicit removal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = fixtures.FeaturesBackend()
        ..entries = [entry('reply-target', 'Reply target')];
      await tester.pumpWidget(fixtures.room(backend, fixtures.Drafts()));
      await tester.pumpAndSettle();
      await insertGif(tester);
      final originalState = tester.state(find.byType(RichMessageComposer));
      await action(tester, 'Reply target', 'Reply');
      expect(find.text('keyboard.gif'), findsOneWidget);
      expect(
        tester.state(find.byType(RichMessageComposer)),
        same(originalState),
      );
      await tester.tap(find.byTooltip('Cancel reply or edit'));
      await tester.pumpAndSettle();
      expect(find.text('keyboard.gif'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(find.text('keyboard.gif'), findsNothing);
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'older ${fail ? 'failed' : 'accepted'} send preserves same-body new reply and GIF',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = fixtures.FeaturesBackend()
          ..queueGate = Completer<void>()
          ..entries = [
            entry('first', 'First target'),
            entry('next', 'Next target'),
          ];
        final drafts = fixtures.Drafts();
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        await action(tester, 'First target', 'Reply');
        await tester.enterText(find.byType(TextField).last, 'Same body');
        await insertGif(tester);
        await tester.tap(find.byTooltip('Send message'));
        await tester.pump();
        expect(backend.queuedReply, 'first');
        // Drain only the modal animation: acceptance remains intentionally held.
        await tester.longPress(find.text('Next target'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Reply'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        if (fail) {
          backend.queueGate!.completeError(StateError('obsolete send failure'));
        } else {
          backend.queueGate!.complete();
        }
        await tester.pumpAndSettle();
        expect(composer(tester).controller.text, 'Same body');
        expect(find.text('keyboard.gif'), findsOneWidget);
        expect(
          find.textContaining('Replying to @friend:s: Next target'),
          findsOneWidget,
        );
        expect(find.textContaining('Could not send'), findsNothing);
        expect(find.text('Message not sent. Try again.'), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(drafts.values['account-a/${fixtures.roomId}'], 'Same body');
        backend.queueGate = null;
        await tester.tap(find.byTooltip('Send message'));
        await tester.pumpAndSettle();
        expect(backend.queuedReply, 'next');
        expect(backend.queuedMedia!.name, 'keyboard.gif');
        expect(composer(tester).controller.text, isEmpty);
        expect(find.text('keyboard.gif'), findsNothing);
        expect(find.textContaining('Replying to'), findsNothing);
      },
    );
  }
}
