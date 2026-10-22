import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/messaging_features.dart';
import 'package:matrixpress/user_directory_screen.dart';
import 'package:matrixpress/space_browser_screen.dart';
import 'package:matrixpress/thread_screen.dart';
import 'package:matrixpress/message_receipts_sheet.dart';

class _Backend extends ChatBackend implements MessagingFeatures {
  String account = 'account-a';
  @override
  String get accountKey => account;
  @override
  String get userId => '@me:example.org';
  final searches = <Completer<List<DirectoryUser>>>[];
  final spaceRequests =
      <({String id, String? cursor, Completer<SpacePage> result})>[];
  final threadRequests = <({String? cursor, Completer<ThreadPage> result})>[];
  final sends = <({String room, String text, String? thread})>[];
  Completer<void>? sendGate;
  bool sendFails = false;
  @override
  List<PendingSend> get pendingSends => const [];
  @override
  List<SpaceSummary> get spaces => const [
    SpaceSummary(id: '!space', name: 'My space', isSpace: true, joined: true),
  ];
  @override
  Future<List<DirectoryUser>> searchUsers(String query) {
    final result = Completer<List<DirectoryUser>>();
    searches.add(result);
    return result.future;
  }

  @override
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) {
    final result = Completer<SpacePage>();
    spaceRequests.add((id: spaceId, cursor: nextBatch, result: result));
    return result.future;
  }

  @override
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) {
    final result = Completer<ThreadPage>();
    threadRequests.add((cursor: nextBatch, result: result));
    return result.future;
  }

  @override
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
  }) async {
    sends.add((room: roomId, text: text, thread: threadRootId));
    if (sendGate != null) await sendGate!.future;
    if (sendFails) throw StateError('offline');
  }

  @override
  Future<void> refreshRooms() async {}
  @override
  Future<String> joinPublicRoom(String roomId) async => roomId;
  @override
  Future<List<MessageReader>> messageReaders(
    String roomId,
    String eventId,
  ) async => [
    MessageReader(
      userId: '@alice:example.org',
      name: 'Alice',
      time: DateTime(2026),
    ),
  ];
  void replaceAccount() {
    account = 'account-b';
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NotifyingSpaceBackend extends _Backend {
  final requestPhases = <SchedulerPhase>[];

  @override
  Future<void> refreshRooms() async {
    requestPhases.add(SchedulerBinding.instance.schedulerPhase);
    notifyListeners();
  }

  @override
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch}) {
    requestPhases.add(SchedulerBinding.instance.schedulerPhase);
    final result = super.loadSpace(spaceId, nextBatch: nextBatch);
    notifyListeners();
    return result;
  }
}

ChatEntry _message(String id) => ChatEntry(
  id: id,
  sender: 'Alice',
  body: id,
  time: DateTime(2026),
  mine: false,
);
const _spaceRoom = SpaceSummary(id: '!room', name: 'Chat room');

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump(const Duration(milliseconds: 400));
}

// Flush lifecycle changes without completing a frame. This exposes the interval
// between reserving a refresh and its deferred backend start, without timers.
void _rebuildBeforeFrame(WidgetTester tester) {
  final owner = tester.binding.buildOwner!;
  owner.buildScope(tester.binding.rootElement!);
  owner.finalizeTree();
}

Future<ValueNotifier<Widget>> _pendingSpaceStart(
  WidgetTester tester,
  _NotifyingSpaceBackend backend, {
  required String? spaceId,
  bool rebind = false,
}) async {
  final content = ValueNotifier<Widget>(const SizedBox());
  addTearDown(content.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: ValueListenableBuilder<Widget>(
        valueListenable: content,
        builder: (_, child, _) => child,
      ),
    ),
  );
  State? previousState;
  if (rebind) {
    final previous = _NotifyingSpaceBackend();
    content.value = SpaceBrowserScreen(backend: previous, spaceId: spaceId);
    await tester.pump();
    expect(previous.requestPhases, hasLength(1));
    if (spaceId != null) {
      previous.spaceRequests.single.result.complete(const SpacePage([]));
    }
    await tester.pump();
    previousState = tester.state(find.byType(SpaceBrowserScreen));
  }
  content.value = SpaceBrowserScreen(backend: backend, spaceId: spaceId);
  _rebuildBeforeFrame(tester);
  if (previousState != null) {
    expect(tester.state(find.byType(SpaceBrowserScreen)), same(previousState));
  }
  expect(backend.requestPhases, isEmpty);
  expect(find.byType(CircularProgressIndicator), findsOneWidget);
  return content;
}

void main() {
  for (final oldFails in [false, true]) {
    testWidgets(
      'directory ignores stale ${oldFails ? 'error' : 'success'} and finally',
      (tester) async {
        final backend = _Backend();
        await tester.pumpWidget(
          MaterialApp(home: UserDirectoryScreen(backend: backend)),
        );
        await _type(tester, 'alice');
        await _type(tester, 'bob');
        expect(backend.searches, hasLength(2));
        if (oldFails) {
          backend.searches[0].completeError(StateError('old'));
        } else {
          backend.searches[0].complete(const [
            DirectoryUser(id: '@alice:example.org', name: 'Alice'),
          ]);
        }
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Alice'), findsNothing);
        backend.searches[1].complete(const [
          DirectoryUser(id: '@bob:example.org', name: 'Bob'),
        ]);
        await tester.pump();
        expect(find.text('Bob'), findsOneWidget);
        expect(find.textContaining('Couldn’t'), findsNothing);
      },
    );
  }

  testWidgets('directory returns selected MXID and clears on account switch', (
    tester,
  ) async {
    final backend = _Backend();
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await Navigator.push<String>(
                context,
                MaterialPageRoute(
                  builder: (_) => UserDirectoryScreen(backend: backend),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await _type(tester, 'bob');
    backend.searches.single.complete(const [
      DirectoryUser(id: '@bob:example.org', name: 'Bob'),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(selected, '@bob:example.org');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await _type(tester, 'alice');
    backend.replaceAccount();
    backend.searches.last.complete(const [
      DirectoryUser(id: '@secret:example.org', name: 'Secret'),
    ]);
    await tester.pump();
    expect(find.text('Secret'), findsNothing);
    expect(find.textContaining('Account changed'), findsOneWidget);
  });

  for (final spaceId in <String?>[null, '!space']) {
    final scope = spaceId == null ? 'joined Spaces' : 'Space hierarchy';
    for (final rebind in [false, true]) {
      final start = rebind ? 'rebound' : 'initial';
      testWidgets('$scope close cancels $start deferred start', (tester) async {
        final backend = _NotifyingSpaceBackend();
        final content = await _pendingSpaceStart(
          tester,
          backend,
          spaceId: spaceId,
          rebind: rebind,
        );
        final state = tester.state(find.byType(SpaceBrowserScreen));
        content.value = const SizedBox();
        _rebuildBeforeFrame(tester);
        expect(state.mounted, isFalse);
        await tester.pump();
        expect(backend.requestPhases, isEmpty);
        expect(backend.spaceRequests, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$scope rebind cancels $start deferred start', (
        tester,
      ) async {
        final backend = _NotifyingSpaceBackend();
        final content = await _pendingSpaceStart(
          tester,
          backend,
          spaceId: spaceId,
          rebind: rebind,
        );
        final state = tester.state(find.byType(SpaceBrowserScreen));
        final replacement = _NotifyingSpaceBackend();
        final replacementId = spaceId == null ? null : '!replacement';
        content.value = SpaceBrowserScreen(
          backend: replacement,
          spaceId: replacementId,
        );
        _rebuildBeforeFrame(tester);
        expect(tester.state(find.byType(SpaceBrowserScreen)), same(state));
        expect(backend.requestPhases, isEmpty);
        expect(replacement.requestPhases, isEmpty);
        // An equivalent parent rebuild must not cancel the valid start.
        content.value = SpaceBrowserScreen(
          backend: replacement,
          spaceId: replacementId,
        );
        _rebuildBeforeFrame(tester);
        await tester.pump();
        expect(backend.requestPhases, isEmpty);
        expect(backend.spaceRequests, isEmpty);
        expect(replacement.requestPhases, hasLength(1));
        expect(
          replacement.requestPhases,
          isNot(contains(SchedulerPhase.persistentCallbacks)),
        );
        if (replacementId != null) {
          expect(replacement.spaceRequests.single.id, replacementId);
          replacement.spaceRequests.single.result.complete(
            const SpacePage([_spaceRoom]),
          );
        }
        backend.replaceAccount();
        // An immediately completed first result needs just the usual next pump.
        await tester.pump();
        expect(
          find.text(replacementId == null ? 'My space' : 'Chat room'),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('Account changed'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$scope Space-ID rebind cancels deferred start', (
      tester,
    ) async {
      final backend = _NotifyingSpaceBackend();
      final content = await _pendingSpaceStart(
        tester,
        backend,
        spaceId: spaceId,
      );
      final state = tester.state(find.byType(SpaceBrowserScreen));
      content.value = SpaceBrowserScreen(
        backend: backend,
        spaceId: '!replacement',
      );
      _rebuildBeforeFrame(tester);
      expect(tester.state(find.byType(SpaceBrowserScreen)), same(state));
      expect(backend.requestPhases, isEmpty);
      await tester.pump();
      expect(backend.requestPhases, hasLength(1));
      expect(backend.spaceRequests.single.id, '!replacement');
      backend.spaceRequests.single.result.complete(
        const SpacePage([_spaceRoom]),
      );
      await tester.pump();
      expect(find.text('Chat room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$scope newer refresh cancels deferred start', (tester) async {
      final backend = _NotifyingSpaceBackend();
      await _pendingSpaceStart(tester, backend, spaceId: spaceId);
      // Invoke the existing action before a frame can drain the pending start.
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
          .onPressed!();
      expect(backend.requestPhases, hasLength(1));
      if (spaceId != null) {
        backend.spaceRequests.single.result.complete(
          const SpacePage([_spaceRoom]),
        );
      }
      await tester.pump();
      expect(backend.requestPhases, hasLength(1));
      expect(
        find.text(spaceId == null ? 'My space' : 'Chat room'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$scope account change cancels deferred start', (tester) async {
      final backend = _NotifyingSpaceBackend();
      await _pendingSpaceStart(tester, backend, spaceId: spaceId);
      backend.replaceAccount();
      await tester.pump();
      expect(backend.requestPhases, isEmpty);
      expect(backend.spaceRequests, isEmpty);
      expect(find.textContaining('Account changed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final oldFails in [false, true]) {
    testWidgets(
      'space refresh invalidates stale page ${oldFails ? 'error' : 'success'}',
      (tester) async {
        final backend = _Backend();
        await tester.pumpWidget(
          MaterialApp(
            home: SpaceBrowserScreen(backend: backend, spaceId: '!space'),
          ),
        );
        backend.spaceRequests[0].result.complete(
          const SpacePage([_spaceRoom], nextBatch: 'old-page'),
        );
        await tester.pump();
        await tester.tap(find.text('Load more'));
        await tester.pump();
        expect(backend.spaceRequests[1].cursor, 'old-page');
        await tester.tap(find.byTooltip('Refresh'));
        await tester.pump();
        expect(backend.spaceRequests, hasLength(3));
        if (oldFails) {
          backend.spaceRequests[1].result.completeError(StateError('old'));
        } else {
          backend.spaceRequests[1].result.complete(
            const SpacePage([
              SpaceSummary(id: '!stale', name: 'Stale room'),
            ], nextBatch: 'wrong'),
          );
        }
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        backend.spaceRequests[2].result.complete(
          const SpacePage([
            SpaceSummary(id: '!fresh', name: 'Fresh room'),
          ], nextBatch: 'fresh-page'),
        );
        await tester.pump();
        expect(find.text('Stale room'), findsNothing);
        expect(find.text('Fresh room'), findsOneWidget);
        await tester.tap(find.text('Load more'));
        await tester.pump();
        expect(backend.spaceRequests.last.cursor, 'fresh-page');
        backend.spaceRequests.last.result.complete(const SpacePage([]));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('space browser recursively returns joined room ID', (
    tester,
  ) async {
    final backend = _Backend();
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await Navigator.push<String>(
                context,
                MaterialPageRoute(
                  builder: (_) => SpaceBrowserScreen(backend: backend),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My space'));
    await tester.pump();
    backend.spaceRequests.single.result.complete(const SpacePage([_spaceRoom]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(selected, '!room');
  });

  testWidgets('thread preserves failed draft and sends with thread root', (
    tester,
  ) async {
    final backend = _Backend()..sendFails = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ThreadScreen(
          backend: backend,
          roomId: '!room',
          root: _message('root'),
        ),
      ),
    );
    backend.threadRequests.single.result.complete(
      ThreadPage([_message('reply')], nextBatch: 'history'),
    );
    await tester.pump();
    expect(find.text('root'), findsOneWidget);
    expect(find.text('reply'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.tap(find.byTooltip('Send reply'));
    await tester.pump();
    expect(find.text('Keep this draft'), findsOneWidget);
    expect(backend.sends.single.thread, 'root');
    expect(backend.sends.single.room, '!room');
    backend.sendFails = false;
    backend.sendGate = Completer<void>();
    await tester.tap(find.byTooltip('Send reply'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Newer draft');
    backend.sendGate!.complete();
    await tester.pump();
    expect(find.text('Newer draft'), findsOneWidget);
    if (backend.threadRequests.length > 1) {
      backend.threadRequests.last.result.complete(const ThreadPage([]));
      await tester.pump();
    }
  });

  testWidgets(
    'thread refresh ignores stale history and preserves fresh cursor',
    (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(
        MaterialApp(
          home: ThreadScreen(
            backend: backend,
            roomId: '!room',
            root: _message('root'),
          ),
        ),
      );
      backend.threadRequests[0].result.complete(
        ThreadPage([_message('reply')], nextBatch: 'old'),
      );
      await tester.pump();
      await tester.tap(find.text('Load older replies'));
      await tester.pump();
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pump();
      backend.threadRequests[1].result.completeError(StateError('old page'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      backend.threadRequests[2].result.complete(
        ThreadPage([_message('fresh')], nextBatch: 'new'),
      );
      await tester.pump();
      expect(find.text('fresh'), findsOneWidget);
      await tester.tap(find.text('Load older replies'));
      await tester.pump();
      expect(backend.threadRequests.last.cursor, 'new');
      backend.threadRequests.last.result.complete(const ThreadPage([]));
      await tester.pump();
    },
  );

  for (final screen in ['space', 'thread']) {
    for (final fail in [false, true]) {
      testWidgets(
        '$screen old refresh ${fail ? 'error' : 'success'} cannot finish newer refresh',
        (tester) async {
          final backend = _Backend();
          await tester.pumpWidget(
            MaterialApp(
              home: screen == 'space'
                  ? SpaceBrowserScreen(backend: backend, spaceId: '!space')
                  : ThreadScreen(
                      backend: backend,
                      roomId: '!room',
                      root: _message('root'),
                    ),
            ),
          );
          await tester.tap(find.byTooltip('Refresh'));
          await tester.pump();
          if (screen == 'space') {
            if (fail) {
              backend.spaceRequests[0].result.completeError(
                StateError('stale refresh'),
              );
            } else {
              backend.spaceRequests[0].result.complete(
                const SpacePage([SpaceSummary(id: '!old', name: 'Old result')]),
              );
            }
          } else {
            if (fail) {
              backend.threadRequests[0].result.completeError(
                StateError('stale refresh'),
              );
            } else {
              backend.threadRequests[0].result.complete(
                ThreadPage([_message('Old result')]),
              );
            }
          }
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.text('Old result'), findsNothing);
          expect(find.textContaining('Couldn’t'), findsNothing);
          if (screen == 'space') {
            backend.spaceRequests[1].result.complete(
              const SpacePage([SpaceSummary(id: '!new', name: 'Fresh result')]),
            );
          } else {
            backend.threadRequests[1].result.complete(
              ThreadPage([_message('Fresh result')]),
            );
          }
          await tester.pump();
          expect(find.text('Fresh result'), findsOneWidget);
        },
      );
    }
  }

  testWidgets('stale space page finally cannot release the new page guard', (
    tester,
  ) async {
    final backend = _Backend();
    await tester.pumpWidget(
      MaterialApp(
        home: SpaceBrowserScreen(backend: backend, spaceId: '!space'),
      ),
    );
    backend.spaceRequests[0].result.complete(
      const SpacePage([_spaceRoom], nextBatch: 'old'),
    );
    await tester.pump();
    await tester.tap(find.text('Load more'));
    await tester.pump();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    backend.spaceRequests[2].result.complete(
      const SpacePage([_spaceRoom], nextBatch: 'fresh'),
    );
    await tester.pump();
    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(backend.spaceRequests[3].cursor, 'fresh');
    backend.spaceRequests[1].result.completeError(StateError('obsolete page'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(find.textContaining('Couldn’t'), findsNothing);
    backend.spaceRequests[3].result.complete(const SpacePage([]));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'account switch clears thread root and draft before late send failure',
    (tester) async {
      final backend = _Backend()
        ..sendGate = Completer<void>()
        ..sendFails = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ThreadScreen(
            backend: backend,
            roomId: '!room',
            root: _message('Private root'),
          ),
        ),
      );
      backend.threadRequests.single.result.complete(const ThreadPage([]));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Private draft');
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pump();
      backend.replaceAccount();
      backend.sendGate!.complete();
      await tester.pump();
      expect(find.text('Private root'), findsNothing);
      expect(find.text('Private draft'), findsNothing);
      expect(find.textContaining('Account changed'), findsOneWidget);
      expect(find.textContaining('Couldn’t send'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('receipt sheet shows real reader name and ID', (tester) async {
    final backend = _Backend();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMessageReceipts(
              context,
              backend: backend,
              roomId: '!room',
              eventId: 'message',
            ),
            child: const Text('Readers'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Readers'));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('@alice:example.org'), findsOneWidget);
  });
}
