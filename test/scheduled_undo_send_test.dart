import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/scheduled/undo_send.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/messaging_features.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, room;
import 'scheduled_fakes.dart';

const _roomId = '!r:example.org';

class _UndoBackend extends FeaturesBackend implements UndoSendFeatures {
  final deadlines = <String, DateTime>{};
  final undone = <String>[];
  UndoneSend? restored;

  @override
  DateTime? undoDeadline(String pendingId) => deadlines[pendingId];

  @override
  Future<UndoneSend?> undoSend(String pendingId) async {
    undone.add(pendingId);
    final result = restored;
    if (result != null) {
      outbox = [
        for (final item in outbox)
          if (item.id != pendingId) item,
      ];
      deadlines.remove(pendingId);
      notifyListeners();
    }
    return result;
  }
}

PendingSend _queued(String id, String body) => PendingSend(
  id: id,
  roomId: _roomId,
  body: body,
  state: DeliveryState.queued,
  createdAt: DateTime(2026),
);

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).last).controller!.text;

/// Settles the room route before held items (whose countdown ticks every
/// second) are added, so later pumps are bounded.
Future<void> _openRoom(
  WidgetTester tester,
  _UndoBackend backend,
  Drafts drafts,
) async {
  await tester.pumpWidget(room(backend, drafts));
  await tester.pumpAndSettle();
}

Future<void> _hold(
  WidgetTester tester,
  _UndoBackend backend,
  String body,
) async {
  backend
    ..outbox = [_queued('tx-held', body)]
    ..deadlines['tx-held'] = DateTime.now().add(const Duration(seconds: 5));
  backend.notifyListeners();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pending panel', () {
    testWidgets('held sends count down and Undo restores the composer', (
      tester,
    ) async {
      final backend = _UndoBackend()
        ..restored = const UndoneSend(text: 'Oops, wrong room');
      final drafts = Drafts();
      await _openRoom(tester, backend, drafts);
      await _hold(tester, backend, 'Oops, wrong room');
      expect(
        find.textContaining(RegExp(r'^Sending in [45] s ·$')),
        findsOneWidget,
      );
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(backend.undone, ['tx-held']);
      expect(backend.cancelled, isNull);
      expect(find.text('Undo'), findsNothing);
      expect(_composerText(tester), 'Oops, wrong room');
      await tester.pump(const Duration(milliseconds: 500));
      expect(drafts.values['account-a/$_roomId'], 'Oops, wrong room');
    });

    testWidgets('restored text goes before newer typing and keeps the reply', (
      tester,
    ) async {
      final backend = _UndoBackend()
        ..restored = const UndoneSend(text: 'First', replyToId: 'original')
        ..entries = [
          ChatEntry(
            id: 'original',
            sender: '@friend:s',
            body: 'Original',
            time: DateTime(2026),
            mine: false,
          ),
        ];
      await _openRoom(tester, backend, Drafts());
      await tester.enterText(find.byType(TextField).last, 'Second');
      await _hold(tester, backend, 'First');
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(_composerText(tester), 'First\nSecond');
      expect(find.text('Replying to @friend:s: Original'), findsOneWidget);
    });

    testWidgets('too late to undo leaves the composer alone', (tester) async {
      final backend = _UndoBackend();
      await _openRoom(tester, backend, Drafts());
      await tester.enterText(find.byType(TextField).last, 'Keep me');
      await _hold(tester, backend, 'Already going');
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(
        find.text('Too late to undo. This message is already sending.'),
        findsOneWidget,
      );
      expect(_composerText(tester), 'Keep me');
    });

    testWidgets('undoing an attachment explains it was removed', (
      tester,
    ) async {
      final backend = _UndoBackend()
        ..restored = const UndoneSend(text: '', attachmentName: 'photo.png');
      await _openRoom(tester, backend, Drafts());
      await _hold(tester, backend, 'photo.png');
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(
        find.text('Attachment removed. Attach it again to send it.'),
        findsOneWidget,
      );
      expect(_composerText(tester), '');
    });

    testWidgets('queued sends without a hold keep Cancel', (tester) async {
      final backend = _UndoBackend();
      await _openRoom(tester, backend, Drafts());
      backend.outbox = [_queued('tx-plain', 'Plain')];
      backend.notifyListeners();
      await tester.pump();
      expect(find.text('Queued'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(backend.cancelled, 'tx-plain');
      expect(backend.undone, isEmpty);
    });
  });

  group('MatrixBackend undo-send wiring', () {
    MatrixBackend backendWith(Duration hold) {
      final backend = MatrixBackend.withClient(
        ScheduledClient(RecordingTransport((_) async => jsonResponse({}))),
        localStorage: MemoryStore(),
        undoSendDelay: () async => hold,
      );
      addTearDown(backend.dispose);
      return backend;
    }

    test('new messages are held and Undo returns their text', () async {
      final backend = backendWith(const Duration(seconds: 5));
      await backend.queueMessage(
        scheduledRoomId,
        'Take this back',
        replyToId: r'$reply',
      );
      final pending = backend.pendingSends.single;
      expect(pending.state, DeliveryState.queued);
      final deadline = backend.undoDeadline(pending.id);
      expect(deadline, isNotNull);
      expect(
        deadline!.difference(DateTime.now()).inSeconds,
        inInclusiveRange(3, 5),
      );
      final undone = await backend.undoSend(pending.id);
      expect(undone!.text, 'Take this back');
      expect(undone.replyToId, r'$reply');
      expect(backend.pendingSends, isEmpty);
    });

    test('edits, thread replies and "Off" skip the grace period', () async {
      final backend = backendWith(const Duration(seconds: 10));
      await backend.queueMessage(
        scheduledRoomId,
        'Fixed',
        editEventId: r'$edit',
      );
      await backend.queueMessage(
        scheduledRoomId,
        'In thread',
        threadRootId: r'$root',
      );
      for (final pending in backend.pendingSends) {
        expect(backend.undoDeadline(pending.id), isNull);
      }
      final off = backendWith(Duration.zero);
      await off.queueMessage(scheduledRoomId, 'Straight away');
      expect(off.undoDeadline(off.pendingSends.single.id), isNull);
    });

    test('media captions come back; the attachment is named', () async {
      final backend = backendWith(const Duration(seconds: 5));
      await backend.queueMedia(
        scheduledRoomId,
        MediaSelection(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'photo.png',
          mimeType: 'image/png',
        ),
        caption: 'Look',
      );
      final undone = await backend.undoSend(backend.pendingSends.single.id);
      expect(undone!.text, 'Look');
      expect(undone.attachmentName, 'photo.png');
    });

    testWidgets('backgrounding the app releases held sends', (tester) async {
      final backend = MatrixBackend.withClient(
        ScheduledClient(RecordingTransport((_) async => jsonResponse({}))),
        localStorage: MemoryStore(),
        undoSendDelay: () async => const Duration(seconds: 20),
      );
      await tester.runAsync(
        () => backend.queueMessage(scheduledRoomId, 'Held'),
      );
      final id = backend.pendingSends.single.id;
      expect(backend.undoDeadline(id), isNotNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(backend.undoDeadline(id), isNotNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(backend.undoDeadline(id), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() async {
        backend.dispose();
        await pumpEventQueue();
      });
    });
  });

  test('countdown rounds up and never goes negative', () {
    final now = DateTime(2026, 11, 12, 10);
    expect(secondsUntil(now.add(const Duration(milliseconds: 4100)), now), 5);
    expect(secondsUntil(now.add(const Duration(seconds: 5)), now), 5);
    expect(secondsUntil(now, now), 0);
    expect(secondsUntil(now.subtract(const Duration(seconds: 1)), now), 0);
  });
}
