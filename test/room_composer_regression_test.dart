// Keep the original review probes, including their diagnostics, verbatim.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' as fixtures;

RichMessageComposer composer(WidgetTester tester) =>
    tester.widget<RichMessageComposer>(find.byType(RichMessageComposer));

class BusyBackend extends fixtures.FeaturesBackend {
  bool busy = false;
  @override
  bool get sending => busy;
}

class HeldClosingDrafts extends fixtures.Drafts {
  final writeStarted = Completer<void>();
  final writeGate = Completer<void>();

  @override
  Future<void> write(String accountKey, String roomId, String text) async {
    if (text == 'Closed typed buffer') {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await writeGate.future;
    }
    await super.write(accountKey, roomId, text);
  }
}

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

  // dart format off
  testWidgets('typing before draft hydration survives close and reopen', (tester) async {
    final backend = fixtures.FeaturesBackend();
    final gate = Completer<String>();
    final drafts = fixtures.Drafts()
      ..values['account-a/${fixtures.roomId}'] = 'Earlier stored draft'
      ..readGate = gate;
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'New unsent text');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    gate.complete('Earlier stored draft');
    await tester.pumpAndSettle();
    drafts.readGate = null;
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pumpAndSettle();
    final text = tester.widget<RichMessageComposer>(find.byType(RichMessageComposer)).controller.text;
    print('CLOSE DURING HYDRATION: visible=$text stored=${drafts.values['account-a/${fixtures.roomId}']} writes=${drafts.writes}');
    expect(text, 'New unsent text');
  });

  testWidgets('a refused busy send must not acknowledge or clear an unsent draft', (tester) async {
    final backend = BusyBackend();
    final drafts = fixtures.Drafts();
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Never accepted');
    await tester.pump();
    final send = tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Send message'));
    backend.busy = true;
    backend.notifyListeners();
    // A platform submit/tap can arrive after a notification but before the frame.
    send.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final text = tester.widget<RichMessageComposer>(find.byType(RichMessageComposer)).controller.text;
    print('BUSY REFUSAL: queued=${backend.queuedText} visible=$text stored=${drafts.values['account-a/${fixtures.roomId}']}');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backend.queuedText, isNull);
    expect(text, 'Never accepted');
  });
  // dart format on

  for (final identicalText in [false, true]) {
    testWidgets(
      'replacement route fences a closed hydration flush with ${identicalText ? 'identical' : 'new'} text',
      (tester) async {
        final backend = fixtures.FeaturesBackend();
        final gate = Completer<String>();
        final drafts = fixtures.Drafts()
          ..values['account-a/${fixtures.roomId}'] =
              'Stored before either route'
          ..readGate = gate;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pump();
        await tester.enterText(
          find.byType(TextField).last,
          'Closed typed buffer',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        drafts.readGate = null;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pump();
        await tester.enterText(find.byType(TextField).last, 'Intermediate');
        final replacement = identicalText
            ? 'Closed typed buffer'
            : 'New route buffer';
        await tester.enterText(find.byType(TextField).last, replacement);
        gate.complete('Stored before either route');
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        expect(composer(tester).controller.text, replacement);
        expect(drafts.values['account-a/${fixtures.roomId}'], replacement);
        expect(drafts.writes, [replacement]);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        expect(composer(tester).controller.text, replacement);
      },
    );
  }

  testWidgets('reopened read joins an already-started closed hydration write', (
    tester,
  ) async {
    final backend = fixtures.FeaturesBackend();
    final gate = Completer<String>();
    final drafts = HeldClosingDrafts()
      ..values['account-a/${fixtures.roomId}'] = 'Stored before close'
      ..readGate = gate;
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Closed typed buffer');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    gate.complete('Stored before close');
    await tester.pump();
    expect(drafts.writeStarted.isCompleted, isTrue);
    drafts.readGate = null;
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pump();
    await tester.enterText(
      find.byType(TextField).last,
      'Reopened newer buffer',
    );
    drafts.writeGate.complete();
    await tester.pumpAndSettle();
    expect(composer(tester).controller.text, 'Reopened newer buffer');
    expect(drafts.writes, ['Closed typed buffer', 'Reopened newer buffer']);
    expect(
      drafts.values['account-a/${fixtures.roomId}'],
      'Reopened newer buffer',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pumpAndSettle();
    expect(composer(tester).controller.text, 'Reopened newer buffer');
  });

  for (final replaceAccount in [false, true]) {
    testWidgets(
      'closed hydration cannot flush after ${replaceAccount ? 'account replacement' : 'same-account logout and login'}',
      (tester) async {
        final backend = fixtures.FeaturesBackend();
        final gate = Completer<String>();
        final drafts = fixtures.Drafts()
          ..values['account-a/${fixtures.roomId}'] = 'Retained account A'
          ..values['account-b/${fixtures.roomId}'] = 'Retained account B'
          ..readGate = gate;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pump();
        await tester.enterText(
          find.byType(TextField).last,
          'Obsolete private buffer',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        if (replaceAccount) {
          backend.account = 'account-b';
          backend.notifyListeners();
        } else {
          backend.status = SessionStatus.signedOut;
          backend.notifyListeners();
          backend.status = SessionStatus.ready;
          backend.notifyListeners();
        }
        gate.complete('Retained account A');
        await tester.pumpAndSettle();
        expect(drafts.writes, isEmpty);
        expect(
          drafts.values['account-a/${fixtures.roomId}'],
          'Retained account A',
        );
        expect(
          drafts.values['account-b/${fixtures.roomId}'],
          'Retained account B',
        );
        expect(tester.takeException(), isNull);
        drafts.readGate = null;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        expect(
          composer(tester).controller.text,
          replaceAccount ? 'Retained account B' : 'Retained account A',
        );
      },
    );
  }

  for (final closed in [false, true]) {
    testWidgets(
      'late hydration error ${closed ? 'after close' : 'before close'} preserves unread storage',
      (tester) async {
        final backend = fixtures.FeaturesBackend();
        final gate = Completer<String>();
        final drafts = fixtures.Drafts()
          ..values['account-a/${fixtures.roomId}'] = 'Unread secure draft'
          ..readGate = gate;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pump();
        await tester.enterText(
          find.byType(TextField).last,
          'Typed while unread',
        );
        if (closed) {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
        gate.completeError(StateError('late read failure'));
        await tester.pumpAndSettle();
        if (!closed) {
          expect(composer(tester).controller.text, 'Typed while unread');
          expect(
            find.text('Saved draft unavailable. Not overwriting storage.'),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
        expect(drafts.writes, isEmpty);
        expect(
          drafts.values['account-a/${fixtures.roomId}'],
          'Unread secure draft',
        );
        expect(tester.takeException(), isNull);
        drafts.readGate = null;
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        expect(composer(tester).controller.text, 'Unread secure draft');
      },
    );
  }

  testWidgets(
    'successful read retry preserves typing made during the failed read',
    (tester) async {
      final backend = fixtures.FeaturesBackend();
      final drafts = fixtures.Drafts()
        ..values['account-a/${fixtures.roomId}'] = 'Previously saved draft'
        ..failRead = true;
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'Keep typed retry buffer',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(drafts.writes, isEmpty);
      drafts.failRead = false;
      await tester.tap(find.text('Retry draft'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(composer(tester).controller.text, 'Keep typed retry buffer');
      expect(
        drafts.values['account-a/${fixtures.roomId}'],
        'Keep typed retry buffer',
      );
    },
  );

  testWidgets('busy refusal retains reply, GIF, and reopened draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = BusyBackend()..entries = [entry('reply', 'Reply target')];
    final drafts = fixtures.Drafts();
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pumpAndSettle();
    await action(tester, 'Reply target', 'Reply');
    await tester.enterText(find.byType(TextField).last, 'Unaccepted caption');
    await insertGif(tester);
    final send = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Send message',
      ),
    );
    backend.busy = true;
    backend.notifyListeners();
    send.onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.queuedMedia, isNull);
    expect(composer(tester).controller.text, 'Unaccepted caption');
    expect(find.text('keyboard.gif'), findsOneWidget);
    expect(
      find.textContaining('Replying to @friend:s: Reply target'),
      findsOneWidget,
    );
    expect(drafts.values['account-a/${fixtures.roomId}'], 'Unaccepted caption');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    backend.busy = false;
    await tester.pumpWidget(fixtures.room(backend, drafts));
    await tester.pumpAndSettle();
    expect(composer(tester).controller.text, 'Unaccepted caption');
  });

  for (final reason in [
    'busy',
    'empty',
    'ended session',
    'closed route',
    'duplicate',
  ]) {
    testWidgets(
      'nonaccepted $reason send reports failure instead of acknowledgement',
      (tester) async {
        final backend = BusyBackend();
        final drafts = fixtures.Drafts();
        await tester.pumpWidget(fixtures.room(backend, drafts));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'Still unsent');
        final input = composer(tester);
        Future<void>? first;
        switch (reason) {
          case 'busy':
            backend.busy = true;
            backend.notifyListeners();
          case 'ended session':
            backend.account = 'account-b';
            backend.notifyListeners();
          case 'closed route':
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          case 'duplicate':
            backend.queueGate = Completer<void>();
            first = input.onSend('First accepted body', null);
          case 'empty':
            break;
        }
        await expectLater(
          input.onSend(reason == 'empty' ? '  ' : 'Still unsent', null),
          throwsStateError,
        );
        expect(
          backend.queuedText,
          reason == 'duplicate' ? 'First accepted body' : isNull,
        );
        if (first != null) {
          backend.queueGate!.complete();
          await first;
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'busy state reached during hydration rejects before queue acceptance',
    (tester) async {
      final backend = BusyBackend();
      final gate = Completer<String>();
      final drafts = fixtures.Drafts()..readGate = gate;
      await tester.pumpWidget(fixtures.room(backend, drafts));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).last,
        'Keep after hydration refusal',
      );
      final send = composer(
        tester,
      ).onSend('Keep after hydration refusal', null);
      final rejected = expectLater(send, throwsStateError);
      backend.busy = true;
      backend.notifyListeners();
      gate.complete('Earlier draft');
      await rejected;
      // The deliberately busy backend keeps its progress indicator animating.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(backend.queuedText, isNull);
      expect(composer(tester).controller.text, 'Keep after hydration refusal');
      expect(
        drafts.values['account-a/${fixtures.roomId}'],
        'Keep after hydration refusal',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

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
