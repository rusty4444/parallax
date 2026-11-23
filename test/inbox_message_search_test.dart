import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/local_message_search.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/messaging_features.dart';

import 'home_options.dart';
import 'widget_test.dart' show FakeBackend;

class _InboxSearchBackend extends FakeBackend
    implements MessagingFeatures, LocalMessageSearch, TimelineNavigation {
  _InboxSearchBackend() {
    currentUserId = '@sam:example.org';
    roomList = [
      _room('!secret:example.org', name: 'Secret', encrypted: true),
      _room('!general:example.org', name: 'General'),
      _room('!dm:example.org', name: 'Alex', direct: true),
    ];
  }

  String account = 'session-a';
  SessionStatus currentStatus = SessionStatus.ready;
  bool started = false;
  bool deviceSearchEnabled = true;
  bool failJump = false;

  final serverQueries =
      <({String query, String? cursor, Completer<MessageSearchPage> result})>[];
  final localQueries =
      <
        ({
          String query,
          int offset,
          int limit,
          Completer<LocalSearchPage> result,
        })
      >[];
  final jumps = <({String room, String event})>[];

  @override
  String get accountKey => account;

  @override
  SessionStatus get connection => currentStatus;

  @override
  List<PendingSend> get pendingSends => const [];

  @override
  bool isFavourite(String roomId) => false;

  @override
  void ensureStarted() => started = true;

  @override
  Future<bool> isEnabled() async => deviceSearchEnabled;

  @override
  Future<void> setEnabled(bool value) async => deviceSearchEnabled = value;

  @override
  Future<void> clear() async {}

  @override
  Future<LocalSearchPage> search(
    String query, {
    int offset = 0,
    int limit = 30,
  }) {
    final result = Completer<LocalSearchPage>();
    localQueries.add((
      query: query,
      offset: offset,
      limit: limit,
      result: result,
    ));
    return result.future;
  }

  @override
  Future<MessageSearchPage> searchMessages(String query, {String? nextBatch}) {
    final result = Completer<MessageSearchPage>();
    serverQueries.add((query: query, cursor: nextBatch, result: result));
    return result.future;
  }

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    jumps.add((room: roomId, event: eventId));
    if (failJump) throw StateError('jump failed');
  }

  @override
  String? focusedEventIn(String roomId) => null;

  @override
  bool hasNewerThanFocus(String roomId) => false;

  @override
  Future<void> jumpToLatest(String roomId) async {}

  void replaceAccount() {
    account = 'session-b';
    notifyListeners();
  }

  void signOut() {
    currentStatus = SessionStatus.signedOut;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatRoom _room(
  String id, {
  required String name,
  bool direct = false,
  bool encrypted = false,
}) => ChatRoom(
  id: id,
  name: name,
  preview: '',
  lastActivity: DateTime(2026),
  isDirect: direct,
  encrypted: encrypted,
);

MessageHit _serverHit(
  String id, {
  String roomId = '!general:example.org',
  String roomName = 'General',
  String? body,
  DateTime? time,
}) => MessageHit(
  id: id,
  roomId: roomId,
  roomName: roomName,
  sender: 'Alex',
  body: body ?? id,
  time: time ?? DateTime(2026, 1, 2),
);

LocalMessageHit _localHit(
  String id, {
  String roomId = '!secret:example.org',
  String roomName = 'Secret',
  String? body,
  String? root,
  DateTime? time,
}) => LocalMessageHit(
  id: id,
  roomId: roomId,
  roomName: roomName,
  sender: 'Jordan',
  body: body ?? id,
  time: time ?? DateTime(2026, 1, 3),
  threadRootId: root,
);

Future<void> _pumpInbox(
  WidgetTester tester,
  _InboxSearchBackend backend, {
  Size size = const Size(400, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: InboxScreen(
        backend: backend,
        palette: paletteFor(VisualTheme.parallax),
        style: VisualTheme.parallax,
        onThemeChanged: (_) {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openAndType(
  WidgetTester tester,
  String query, {
  bool waitForDebounce = true,
}) async {
  if (find
      .byKey(const ValueKey('home.conversation_search'))
      .evaluate()
      .isEmpty) {
    await tester.tap(find.byKey(const ValueKey('home.search_toggle')));
    await tester.pumpAndSettle();
  }
  await tester.enterText(
    find.byKey(const ValueKey('home.conversation_search')),
    query,
  );
  await tester.pump();
  if (waitForDebounce) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets(
    'runs local and server message search in parallel with searching animation',
    (tester) async {
      final backend = _InboxSearchBackend();
      await _pumpInbox(tester, backend);
      expect(backend.started, isTrue);

      await _openAndType(tester, 'pizza', waitForDebounce: false);
      // Searching animation appears right away during debounce, not "No matches yet".
      expect(
        find.byKey(const ValueKey('home.message_search_spinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home.message_search_shimmer')),
        findsOneWidget,
      );
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('No matches yet'), findsNothing);

      // Advance past debounce: BOTH local and server queries dispatch in parallel.
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.localQueries, hasLength(1));
      expect(backend.serverQueries, hasLength(1));

      // Server finishes BEFORE local (proving server is not blocked on SQLite).
      backend.serverQueries.single.result.complete(
        MessageSearchPage(hits: [_serverHit(r'$srv', body: 'Server pizza')]),
      );
      await tester.pump();
      expect(find.text('Server pizza', findRichText: true), findsOneWidget);
      // Shimmer disappears once hits arrive, while the compact searching dots stay
      // until the local search finishes too.
      expect(
        find.byKey(const ValueKey('home.message_search_shimmer')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('home.message_search_spinner')),
        findsOneWidget,
      );

      // Local encrypted-room search completes: both hits show, animation stops.
      backend.localQueries.single.result.complete(
        LocalSearchPage(
          hits: [_localHit(r'$loc', body: 'Encrypted pizza', root: r'$root')],
        ),
      );
      await tester.pump();
      expect(find.text('Encrypted pizza', findRichText: true), findsOneWidget);
      expect(find.text('Server pizza', findRichText: true), findsOneWidget);
      expect(find.text('In a thread'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('home.message_search_spinner')),
        findsNothing,
      );
    },
  );

  testWidgets('re-checks device search setting dynamically on each search', (
    tester,
  ) async {
    final backend = _InboxSearchBackend()..deviceSearchEnabled = false;
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'secret');
    expect(backend.localQueries, isEmpty);
    expect(backend.serverQueries, hasLength(1));
    backend.serverQueries.last.result.complete(
      const MessageSearchPage(hits: []),
    );
    await tester.pump();

    // User turns device search on in Settings without restarting InboxScreen.
    backend.deviceSearchEnabled = true;
    await _openAndType(tester, 'secret2');
    expect(backend.localQueries, hasLength(1));
    expect(backend.serverQueries, hasLength(2));
    backend.localQueries.single.result.complete(
      LocalSearchPage(hits: [_localHit(r'$enc', body: 'Secret2 message')]),
    );
    backend.serverQueries.last.result.complete(
      const MessageSearchPage(hits: []),
    );
    await tester.pump();
    expect(find.text('Secret2 message', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'caps matching chats above message matches and expands on demand',
    (tester) async {
      final backend = _InboxSearchBackend()
        ..roomList = [
          for (var i = 1; i <= 6; i++)
            _room('!proj$i:example.org', name: 'Project $i'),
        ];
      await _pumpInbox(tester, backend);

      await _openAndType(tester, 'project');
      backend.localQueries.single.result.complete(
        const LocalSearchPage(hits: []),
      );
      backend.serverQueries.single.result.complete(
        MessageSearchPage(
          hits: [
            _serverHit(
              r'$m1',
              roomId: '!proj1:example.org',
              roomName: 'Project 1',
              body: 'Project timeline update',
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('CHATS'), findsOneWidget);
      expect(find.text('Project 1'), findsWidgets);
      expect(find.text('Project 3'), findsOneWidget);
      expect(find.text('Project 4'), findsNothing);
      expect(find.text('Show all 6 chats'), findsOneWidget);
      expect(find.text('MESSAGE MATCHES'), findsOneWidget);
      expect(
        find.text('Project timeline update', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('home.search_show_all_chats')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Project 4'), findsOneWidget);
      expect(find.text('Project 6'), findsOneWidget);
      expect(find.text('Show all 6 chats'), findsNothing);
    },
  );

  testWidgets(
    'paginates local and server matches inline and ignores obsolete pages',
    (tester) async {
      final backend = _InboxSearchBackend();
      await _pumpInbox(tester, backend);

      await _openAndType(tester, 'older');
      backend.localQueries[0].result.complete(
        LocalSearchPage(
          hits: [_localHit(r'$l1', body: 'Older local 1')],
          nextOffset: 20,
        ),
      );
      backend.serverQueries[0].result.complete(
        MessageSearchPage(
          hits: [_serverHit(r'$s1', body: 'Older server 1')],
          nextBatch: 'cursor-1',
        ),
      );
      await tester.pump();
      expect(find.text('Load more messages'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('home.search_load_more')));
      await tester.pump();
      expect(backend.localQueries, hasLength(2));
      expect(backend.localQueries[1].offset, 20);
      expect(backend.serverQueries, hasLength(2));
      expect(backend.serverQueries[1].cursor, 'cursor-1');

      // Start a brand-new query before page 2 settles.
      await _openAndType(tester, 'fresh');
      backend.localQueries[2].result.complete(
        LocalSearchPage(
          hits: [_localHit(r'$lf1', body: 'Fresh local 1')],
          nextOffset: 20,
        ),
      );
      backend.serverQueries[2].result.complete(
        const MessageSearchPage(hits: []),
      );
      await tester.pump();

      // Late completions for the obsolete page must be ignored.
      backend.localQueries[1].result.complete(
        LocalSearchPage(hits: [_localHit(r'$stale', body: 'Stale local')]),
      );
      backend.serverQueries[1].result.completeError(StateError('old page'));
      await tester.pump();
      expect(find.text('Stale local', findRichText: true), findsNothing);
      expect(find.text('Couldn’t load more matches.'), findsNothing);
      expect(find.text('Fresh local 1', findRichText: true), findsOneWidget);

      // Load page 2 of the fresh query (dedupes repeated IDs).
      await tester.tap(find.byKey(const ValueKey('home.search_load_more')));
      await tester.pump();
      expect(backend.localQueries[3].offset, 20);
      backend.localQueries[3].result.complete(
        LocalSearchPage(
          hits: [
            _localHit(r'$lf1', body: 'Fresh local 1'),
            _localHit(r'$lf2', body: 'Fresh local 2'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Fresh local 2', findRichText: true), findsOneWidget);
      expect(find.text('Load more messages'), findsNothing);
    },
  );

  testWidgets('load more error preserves hits and allows retry', (
    tester,
  ) async {
    final backend = _InboxSearchBackend();
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'hello');
    backend.localQueries[0].result.complete(const LocalSearchPage(hits: []));
    backend.serverQueries[0].result.complete(
      MessageSearchPage(
        hits: [_serverHit(r'$s1', body: 'First hello')],
        nextBatch: 'page-2',
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('home.search_load_more')));
    await tester.pump();
    backend.serverQueries[1].result.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('First hello', findRichText: true), findsOneWidget);
    expect(find.text('Couldn’t load more matches.'), findsOneWidget);
    expect(find.text('Load more messages'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home.search_load_more')));
    await tester.pump();
    backend.serverQueries[2].result.complete(
      MessageSearchPage(hits: [_serverHit(r'$s2', body: 'Second hello')]),
    );
    await tester.pump();
    expect(find.text('Second hello', findRichText: true), findsOneWidget);
    expect(find.text('Load more messages'), findsNothing);
  });

  testWidgets('partial error keeps other source hits and retry recovers', (
    tester,
  ) async {
    final backend = _InboxSearchBackend();
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'report');
    backend.localQueries[0].result.completeError(StateError('io'));
    backend.serverQueries[0].result.complete(
      MessageSearchPage(hits: [_serverHit(r'$s1', body: 'Server report')]),
    );
    await tester.pump();
    expect(find.text('Server report', findRichText: true), findsOneWidget);
    expect(find.text('Couldn’t search this device’s history.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home.search_retry')));
    await tester.pump();
    backend.localQueries[1].result.complete(
      LocalSearchPage(hits: [_localHit(r'$l1', body: 'Recovered report')]),
    );
    backend.serverQueries[1].result.complete(const MessageSearchPage(hits: []));
    await tester.pump();
    expect(find.text('Recovered report', findRichText: true), findsOneWidget);
    expect(find.text('Couldn’t search this device’s history.'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('clear button resets query while keeping search bar open', (
    tester,
  ) async {
    final backend = _InboxSearchBackend();
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'pizza', waitForDebounce: false);
    expect(find.byKey(const ValueKey('home.search_clear')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home.search_clear')));
    await tester.pump(const Duration(milliseconds: 400));

    // Pending debounce was cancelled and search bar stayed open.
    expect(backend.localQueries, isEmpty);
    expect(backend.serverQueries, isEmpty);
    expect(
      find.byKey(const ValueKey('home.conversation_search')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('home.search_clear')), findsNothing);
  });

  testWidgets(
    'keyboard submit dispatches immediately without waiting debounce',
    (tester) async {
      final backend = _InboxSearchBackend();
      await _pumpInbox(tester, backend);

      await _openAndType(tester, 'urgent', waitForDebounce: false);
      expect(backend.serverQueries, isEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(backend.localQueries, hasLength(1));
      expect(backend.serverQueries, hasLength(1));
      backend.localQueries.single.result.complete(
        const LocalSearchPage(hits: []),
      );
      backend.serverQueries.single.result.complete(
        const MessageSearchPage(hits: []),
      );
      await tester.pump();
    },
  );

  testWidgets('tapping a thread message hit jumps to its thread root', (
    tester,
  ) async {
    final backend = _InboxSearchBackend();
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'pier');
    backend.localQueries.single.result.complete(
      LocalSearchPage(
        hits: [_localHit(r'$reply', body: 'Meet at the pier', root: r'$root')],
      ),
    );
    backend.serverQueries.single.result.complete(
      const MessageSearchPage(hits: []),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey(r'home-hit-$reply')));
    await tester.pumpAndSettle();
    expect(backend.jumps.single, (
      room: '!secret:example.org',
      event: r'$root',
    ));
  });

  testWidgets('account change ignores late search results', (tester) async {
    final backend = _InboxSearchBackend();
    await _pumpInbox(tester, backend);

    await _openAndType(tester, 'private');
    backend.replaceAccount();
    await tester.pump();
    backend.localQueries.single.result.complete(
      LocalSearchPage(hits: [_localHit(r'$late', body: 'Leaked message')]),
    );
    backend.serverQueries.single.result.complete(
      MessageSearchPage(hits: [_serverHit(r'$late2', body: 'Leaked server')]),
    );
    await tester.pump();
    expect(find.text('Leaked message', findRichText: true), findsNothing);
    expect(find.text('Leaked server', findRichText: true), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'active inbox filter scopes message matches and clearing restores them',
    (tester) async {
      final backend = _InboxSearchBackend();
      await _pumpInbox(tester, backend);

      await _openAndType(tester, 'lunch');
      backend.localQueries.single.result.complete(
        LocalSearchPage(
          hits: [
            _localHit(
              r'$dm-hit',
              roomId: '!dm:example.org',
              roomName: 'Alex',
              body: 'DM lunch',
            ),
            _localHit(
              r'$group-hit',
              roomId: '!secret:example.org',
              roomName: 'Secret',
              body: 'Group lunch',
            ),
          ],
        ),
      );
      backend.serverQueries.single.result.complete(
        const MessageSearchPage(hits: []),
      );
      await tester.pump();
      expect(find.text('DM lunch', findRichText: true), findsOneWidget);
      expect(find.text('Group lunch', findRichText: true), findsOneWidget);

      await openHomeOptions(tester);
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('DM lunch', findRichText: true), findsOneWidget);
      expect(find.text('Group lunch', findRichText: true), findsNothing);

      // Deselect People: group hit reappears immediately without re-querying.
      await tester.tap(find.text('People'));
      await tester.pumpAndSettle();
      expect(find.text('Group lunch', findRichText: true), findsOneWidget);
    },
  );
}
