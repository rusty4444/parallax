import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/thread_features.dart';
import 'package:parallax/features/threads/thread_hooks.dart';
import 'package:parallax/features/threads/thread_list_screen.dart';
import 'package:parallax/features/threads/thread_models.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/thread_screen.dart';

const _roomId = '!room:example.org';
final _palette = paletteFor(VisualTheme.parallax);

class _Backend extends ChatBackend
    implements MessagingFeatures, ThreadFeatures, TimelineNavigation {
  String account = 'account-a';
  final listRequests =
      <
        ({
          ThreadListFilter filter,
          String? cursor,
          Completer<ThreadListPage> result,
        })
      >[];
  final threadRequests = <({String? cursor, Completer<ThreadPage> result})>[];
  final receipts = <({String root, String event, bool public})>[];
  final sends = <({String text, String? reply, String? thread})>[];
  final activity = StreamController<String>.broadcast();
  String? focused;
  bool newer = true;
  int jumps = 0;

  @override
  String get accountKey => account;
  @override
  String get userId => '@me:example.org';
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  List<ChatRoom> get rooms => [
    ChatRoom(
      id: _roomId,
      name: 'Weekend crew',
      preview: '',
      lastActivity: null,
    ),
  ];
  @override
  List<PendingSend> get pendingSends => const [];

  @override
  Future<ThreadListPage> loadThreads(
    String roomId, {
    ThreadListFilter filter = ThreadListFilter.all,
    String? nextBatch,
  }) {
    final result = Completer<ThreadListPage>();
    listRequests.add((filter: filter, cursor: nextBatch, result: result));
    return result.future;
  }

  @override
  Future<void> markThreadRead(
    String roomId,
    String rootId,
    String eventId, {
    required bool public,
  }) async {
    receipts.add((root: rootId, event: eventId, public: public));
  }

  @override
  Stream<String> threadActivity(String roomId) => activity.stream;

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
    sends.add((text: text, reply: replyToId, thread: threadRootId));
  }

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    focused = eventId;
  }

  @override
  String? focusedEventIn(String roomId) => roomId == _roomId ? focused : null;
  @override
  bool hasNewerThanFocus(String roomId) => focused != null && newer;
  @override
  Future<void> jumpToLatest(String roomId) async {
    jumps++;
    focused = null;
    notifyListeners();
  }

  void replaceAccount() {
    account = 'account-b';
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A backend without any thread/navigation features.
class _PlainBackend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry _entry(
  String id, {
  String body = '',
  String sender = '@alice:example.org',
  String? name = 'Alice',
  int minute = 0,
  int replies = 0,
  String? latest,
  bool mine = false,
}) => ChatEntry(
  id: id,
  sender: sender,
  senderName: name,
  body: body.isEmpty ? 'body $id' : body,
  time: DateTime(2026, 1, 1, 9, minute),
  mine: mine,
  threadReplyCount: replies,
  threadLatestBody: latest,
);

ThreadSummary _thread(
  String id, {
  int replies = 2,
  bool? unread,
  String latestBody = 'latest reply',
}) => ThreadSummary(
  root: _entry(id, body: 'Root $id'),
  replyCount: replies,
  latest: _entry('$id-latest', body: latestBody, name: 'Bob', minute: 5),
  unread: unread,
);

Widget _app(Widget home) =>
    MaterialApp(theme: themeFor(VisualTheme.parallax), home: home);

void main() {
  group('threads list', () {
    testWidgets('shows summaries, unread dots and opens a thread', (
      tester,
    ) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadsListScreen(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Weekend crew'), findsOneWidget);
      backend.listRequests.single.result.complete(
        ThreadListPage([
          _thread(r'$one', unread: true),
          _thread(r'$two', replies: 1, unread: false),
        ]),
      );
      await tester.pump();
      expect(find.text(r'Root $one'), findsOneWidget);
      expect(find.text('2 replies'), findsOneWidget);
      expect(find.text('1 reply'), findsOneWidget);
      expect(find.text('Bob: latest reply'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('thread-unread-dot')), findsOneWidget);

      await tester.tap(find.text(r'Root $one'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final screen = tester.widget<ThreadScreen>(find.byType(ThreadScreen));
      expect(screen.root.id, r'$one');
      expect(screen.roomId, _roomId);
    });

    testWidgets('My threads filter ignores a stale All response', (
      tester,
    ) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadsListScreen(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
          ),
        ),
      );
      await tester.tap(find.text('My threads'));
      await tester.pump();
      expect(backend.listRequests, hasLength(2));
      expect(backend.listRequests[1].filter, ThreadListFilter.participated);
      backend.listRequests[0].result.complete(
        ThreadListPage([_thread(r'$stale')]),
      );
      await tester.pump();
      expect(find.text(r'Root $stale'), findsNothing);
      backend.listRequests[1].result.complete(const ThreadListPage([]));
      await tester.pump();
      expect(
        find.text('You haven’t taken part in any threads in this room yet.'),
        findsOneWidget,
      );
    });

    testWidgets('paginates with the server cursor and reports failure', (
      tester,
    ) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadsListScreen(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
          ),
        ),
      );
      backend.listRequests.single.result.complete(
        ThreadListPage([_thread(r'$one')], nextBatch: 'page-2'),
      );
      await tester.pump();
      await tester.tap(find.text('Load more threads'));
      await tester.pump();
      expect(backend.listRequests.last.cursor, 'page-2');
      backend.listRequests.last.result.completeError(StateError('offline'));
      await tester.pump();
      expect(find.text('Couldn’t load more threads.'), findsOneWidget);
      await tester.tap(find.text('Couldn’t load more threads.'));
      await tester.pump();
      backend.listRequests.last.result.complete(
        ThreadListPage([_thread(r'$one'), _thread(r'$two')]),
      );
      await tester.pump();
      expect(find.text(r'Root $two'), findsOneWidget);
      expect(find.text(r'Root $one'), findsOneWidget);
      expect(find.text('Load more threads'), findsNothing);
    });

    testWidgets('unsupported servers and account changes are explained', (
      tester,
    ) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadsListScreen(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
          ),
        ),
      );
      backend.listRequests.single.result.completeError(
        const ThreadListUnsupported(),
      );
      await tester.pump();
      expect(find.textContaining('doesn’t provide a threads list'), findsOne);
      backend.replaceAccount();
      await tester.pump();
      expect(find.text('Account changed. Reopen this room.'), findsOneWidget);
    });

    testWidgets('new thread activity refreshes quietly', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadsListScreen(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
          ),
        ),
      );
      backend.listRequests.single.result.complete(
        ThreadListPage([_thread(r'$one')]),
      );
      await tester.pump();
      backend.activity.add(r'$two');
      await tester.pump();
      expect(backend.listRequests, hasLength(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(r'Root $one'), findsOneWidget);
      backend.listRequests[1].result.complete(
        ThreadListPage([_thread(r'$two')]),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text(r'Root $two'), findsOneWidget);
      expect(find.text(r'Root $one'), findsOneWidget);
    });
  });

  group('thread screen', () {
    testWidgets('sends a threaded receipt and quotes replies in thread', (
      tester,
    ) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(
          ThreadScreen(
            backend: backend,
            roomId: _roomId,
            root: _entry(r'$root', body: 'Root message', replies: 2),
          ),
        ),
      );
      expect(find.text('Weekend crew'), findsOneWidget);
      backend.threadRequests.single.result.complete(
        ThreadPage([
          _entry(r'$r1', body: 'first reply', minute: 1),
          _entry(
            r'$r2',
            body: 'my reply',
            minute: 2,
            mine: true,
            sender: '@me:example.org',
          ),
        ]),
      );
      await tester.pump();
      expect(find.text('2 replies'), findsOneWidget);
      expect(find.text('Alice'), findsNWidgets(2));
      expect(backend.receipts.single.event, r'$r2');
      expect(backend.receipts.single.root, r'$root');
      expect(backend.receipts.single.public, isTrue);

      await tester.longPress(find.text('first reply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quote in reply'));
      await tester.pumpAndSettle();
      expect(find.text('Replying to Alice: first reply'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'agreed');
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pump();
      expect(backend.sends.single.text, 'agreed');
      expect(backend.sends.single.reply, r'$r1');
      expect(backend.sends.single.thread, r'$root');
      expect(find.textContaining('Replying to'), findsNothing);

      // Activity in this thread refreshes without clearing the replies.
      backend.threadRequests.last.result.complete(const ThreadPage([]));
      await tester.pump();
      backend.activity.add(r'$root');
      await tester.pump();
      expect(find.text('first reply'), findsOneWidget);
      backend.threadRequests.last.result.complete(
        ThreadPage([_entry(r'$r3', body: 'new reply', minute: 3)]),
      );
      await tester.pump();
      expect(find.text('new reply'), findsOneWidget);
      expect(find.text('first reply'), findsOneWidget);
      expect(backend.receipts.last.event, r'$r3');
      // Other threads' activity is ignored.
      final requests = backend.threadRequests.length;
      backend.activity.add(r'$other');
      await tester.pump();
      expect(backend.threadRequests, hasLength(requests));
    });
  });

  group('hooks', () {
    Widget hooked(ChatBackend backend, ChatEntry entry) => _app(
      Scaffold(
        body: Builder(
          builder: (context) {
            final room = RoomHookContext(
              backend: backend,
              roomId: _roomId,
              palette: _palette,
            );
            final entryContext = EntryHookContext(
              backend: backend,
              roomId: _roomId,
              palette: _palette,
              entry: entry,
            );
            return ListView(
              children: [
                Row(children: threadRoomHeaderActions(context, room)),
                ?threadEntryFooter(context, entryContext),
                ...threadRoomDetailsSections(context, room),
              ],
            );
          },
        ),
      ),
    );

    testWidgets('thread summary chip opens the thread', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(
        hooked(backend, _entry(r'$root', replies: 3, latest: 'see you there')),
      );
      expect(find.text('3 replies'), findsOneWidget);
      expect(find.text('see you there'), findsOneWidget);
      expect(find.byTooltip('Threads'), findsOneWidget);
      expect(find.byTooltip('Jump to latest'), findsNothing);
      expect(find.text('Threads'), findsOneWidget);
      await tester.tap(find.text('3 replies'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.widget<ThreadScreen>(find.byType(ThreadScreen)).root.id,
        r'$root',
      );
    });

    testWidgets('focused event is marked and can jump to latest', (
      tester,
    ) async {
      final backend = _Backend()..focused = r'$hit';
      await tester.pumpWidget(hooked(backend, _entry(r'$hit')));
      expect(find.text('Jumped to this message'), findsOneWidget);
      expect(find.byTooltip('Jump to latest'), findsOneWidget);
      // One header slot: "Jump to latest" replaces "Threads" while focused.
      expect(find.byTooltip('Threads'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Jump to latest'));
      await tester.pump();
      expect(backend.jumps, 1);
      await tester.pumpWidget(hooked(backend, _entry(r'$hit')));
      expect(find.text('Jumped to this message'), findsNothing);
      expect(find.byTooltip('Jump to latest'), findsNothing);
      expect(find.byTooltip('Threads'), findsOneWidget);
    });

    testWidgets('plain backends get no thread actions', (tester) async {
      await tester.pumpWidget(hooked(_PlainBackend(), _entry(r'$x')));
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('Threads'), findsNothing);
      expect(find.text('Jumped to this message'), findsNothing);
    });
  });
}
