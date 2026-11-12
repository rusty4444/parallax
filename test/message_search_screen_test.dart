import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/local_message_search.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/message_search_screen.dart';
import 'package:parallax/messaging_features.dart';

class _SearchBackend extends ChatBackend implements MessagingFeatures {
  String account = 'session-a';
  String? currentUser = '@me:matrix.example';
  SessionStatus status = SessionStatus.ready;
  final requests =
      <({String query, String? cursor, Completer<MessageSearchPage> result})>[];

  @override
  String get accountKey => account;
  @override
  String? get userId => currentUser;
  @override
  SessionStatus get connection => status;

  @override
  Future<MessageSearchPage> searchMessages(String query, {String? nextBatch}) {
    final result = Completer<MessageSearchPage>();
    requests.add((query: query, cursor: nextBatch, result: result));
    return result.future;
  }

  void replaceAccount() {
    account = 'session-b';
    notifyListeners();
  }

  void signOut() {
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MessageHit _hit(String id) => MessageHit(
  id: id,
  roomId: '!room:matrix.example',
  roomName: 'General',
  sender: '@alice:matrix.example',
  body: id,
  time: DateTime(2026),
);

Widget _screen(_SearchBackend backend) => MaterialApp(
  home: MessageSearchScreen(
    backend: backend,
    palette: paletteFor(VisualTheme.parallax),
  ),
);

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _startOldPage(WidgetTester tester, _SearchBackend backend) async {
  await tester.pumpWidget(_screen(backend));
  await _type(tester, 'older');
  backend.requests[0].result.complete(
    MessageSearchPage(hits: [_hit('Old result')], nextBatch: 'old-cursor'),
  );
  await tester.pump();
  await tester.tap(find.text('Load more'));
  await tester.pump();
  expect(backend.requests[1].cursor, 'old-cursor');
}

void main() {
  testWidgets('new query can paginate before an obsolete page settles', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await _startOldPage(tester, backend);
    await _type(tester, 'fresh');
    backend.requests[2].result.complete(
      MessageSearchPage(
        hits: [_hit('Fresh result')],
        nextBatch: 'fresh-cursor',
      ),
    );
    await tester.pump();
    expect(find.text('Old result'), findsNothing);
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(backend.requests, hasLength(4));
    expect(backend.requests[3].query, 'fresh');
    expect(backend.requests[3].cursor, 'fresh-cursor');
    backend.requests[1].result.complete(const MessageSearchPage(hits: []));
    backend.requests[3].result.complete(const MessageSearchPage(hits: []));
    await tester.pump();
  });

  for (final fail in [false, true]) {
    testWidgets(
      'obsolete page ${fail ? 'error' : 'success'} cannot release a newer page guard',
      (tester) async {
        final backend = _SearchBackend();
        await _startOldPage(tester, backend);
        await _type(tester, 'fresh');
        backend.requests[2].result.complete(
          MessageSearchPage(
            hits: [_hit('Fresh result')],
            nextBatch: 'fresh-cursor',
          ),
        );
        await tester.pump();
        expect(find.text('Load more'), findsOneWidget);
        await tester.tap(find.text('Load more'));
        await tester.pump();
        expect(backend.requests, hasLength(4));
        if (fail) {
          backend.requests[1].result.completeError(StateError('old page'));
        } else {
          backend.requests[1].result.complete(
            MessageSearchPage(hits: [_hit('Stale result')], nextBatch: 'wrong'),
          );
        }
        await tester.pump();
        expect(find.text('Loading…'), findsOneWidget);
        expect(find.text('Stale result'), findsNothing);
        expect(find.textContaining('Couldn’t'), findsNothing);
        // Even a second tap before the pending page returns must be ignored.
        await tester.tap(find.text('Loading…'));
        await tester.pump();
        expect(backend.requests, hasLength(4));
        backend.requests[3].result.complete(
          MessageSearchPage(hits: [_hit('Fresh page')]),
        );
        await tester.pump();
        expect(find.text('Fresh page'), findsOneWidget);
        expect(find.text('Loading…'), findsNothing);
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'obsolete first-page ${fail ? 'error' : 'success'} is ignored',
      (tester) async {
        final backend = _SearchBackend();
        await tester.pumpWidget(_screen(backend));
        await _type(tester, 'older');
        await _type(tester, 'fresh');
        if (fail) {
          backend.requests[0].result.completeError(StateError('old search'));
        } else {
          backend.requests[0].result.complete(
            MessageSearchPage(hits: [_hit('Stale result')]),
          );
        }
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Stale result'), findsNothing);
        expect(find.textContaining('Couldn’t'), findsNothing);
        backend.requests[1].result.complete(
          MessageSearchPage(hits: [_hit('Fresh result')]),
        );
        await tester.pump();
        expect(find.text('Fresh result'), findsOneWidget);
      },
    );
  }

  testWidgets('clearing the query retires its page without blocking a retry', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await _startOldPage(tester, backend);
    await _type(tester, 'x');
    expect(
      find.text('Type at least two characters to search.'),
      findsOneWidget,
    );
    expect(find.text('Old result'), findsNothing);
    await _type(tester, 'older');
    backend.requests[2].result.complete(
      MessageSearchPage(
        hits: [_hit('Retried result')],
        nextBatch: 'retry-cursor',
      ),
    );
    await tester.pump();
    expect(find.text('Load more'), findsOneWidget);
    backend.requests[1].result.completeError(StateError('old page'));
    await tester.pump();
    expect(find.textContaining('Couldn’t'), findsNothing);
    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(backend.requests[3].cursor, 'retry-cursor');
    backend.requests[3].result.complete(const MessageSearchPage(hits: []));
    await tester.pump();
  });

  for (final change in ['account', 'logout']) {
    for (final fail in [false, true]) {
      testWidgets(
        '$change clears private results and ignores late ${fail ? 'error' : 'success'}',
        (tester) async {
          final backend = _SearchBackend();
          await _startOldPage(tester, backend);
          if (change == 'account') {
            backend.replaceAccount();
          } else {
            backend.signOut();
          }
          await tester.pump();
          expect(find.text('Old result'), findsNothing);
          expect(find.textContaining('Account changed'), findsOneWidget);
          expect(
            tester.widget<TextField>(find.byType(TextField)).enabled,
            isFalse,
          );
          if (fail) {
            backend.requests[1].result.completeError(StateError('old account'));
          } else {
            backend.requests[1].result.complete(
              MessageSearchPage(hits: [_hit('Private late result')]),
            );
          }
          await tester.pump();
          expect(find.text('Private late result'), findsNothing);
          expect(find.textContaining('Couldn’t'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('account switch cancels a search still in debounce', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await tester.pumpWidget(_screen(backend));
    await tester.enterText(find.byType(TextField), 'private');
    backend.replaceAccount();
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.requests, isEmpty);
    expect(find.textContaining('Account changed'), findsOneWidget);
  });

  testWidgets('backend replacement clears state and retires pending work', (
    tester,
  ) async {
    final backend = _SearchBackend();
    final replacement = _SearchBackend();
    await _startOldPage(tester, backend);
    final state = tester.state(find.byType(MessageSearchScreen));
    await tester.pumpWidget(_screen(replacement));
    expect(tester.state(find.byType(MessageSearchScreen)), same(state));
    expect(find.text('Old result'), findsNothing);
    expect(
      find.text('Type at least two characters to search.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    // Notifications from the detached backend must not expire the new session.
    backend.replaceAccount();
    backend.requests[1].result.completeError(StateError('retired backend'));
    await _type(tester, 'fresh');
    replacement.requests.single.result.complete(
      MessageSearchPage(hits: [_hit('Replacement result')]),
    );
    await tester.pump();
    expect(find.text('Replacement result'), findsOneWidget);
    expect(find.textContaining('Account changed'), findsNothing);
    expect(find.textContaining('Couldn’t'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current page failure preserves hits and permits cursor retry', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await _startOldPage(tester, backend);
    backend.requests[1].result.completeError(StateError('offline'));
    await tester.pump();
    expect(find.text('Old result'), findsOneWidget);
    expect(find.text('Couldn’t load more matches.'), findsOneWidget);
    expect(find.text('Load more'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pump();
    expect(backend.requests[2].query, 'older');
    expect(backend.requests[2].cursor, 'old-cursor');
    backend.requests[2].result.complete(
      MessageSearchPage(hits: [_hit('Old result'), _hit('Recovered result')]),
    );
    await tester.pump();
    expect(find.text('Old result'), findsOneWidget);
    expect(find.text('Recovered result'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
  });

  testWidgets('current search failure is visible and a new query clears it', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await tester.pumpWidget(_screen(backend));
    await _type(tester, 'failed');
    backend.requests[0].result.completeError(StateError('offline'));
    await tester.pump();
    expect(
      find.text('Couldn’t search messages on this server.'),
      findsOneWidget,
    );
    await _type(tester, 'retry');
    backend.requests[1].result.complete(
      MessageSearchPage(hits: [_hit('Recovered result')]),
    );
    await tester.pump();
    expect(find.text('Recovered result'), findsOneWidget);
    expect(find.textContaining('Couldn’t'), findsNothing);
  });

  testWidgets('equivalent parent rebuild retains the current search', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await tester.pumpWidget(_screen(backend));
    await tester.enterText(find.byType(TextField), 'retained');
    await tester.pumpWidget(_screen(backend));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.requests.single.query, 'retained');
    backend.requests.single.result.complete(
      MessageSearchPage(hits: [_hit('Retained result')]),
    );
    await tester.pump();
    await tester.pumpWidget(_screen(backend));
    expect(find.text('Retained result'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'retained',
    );
  });

  testWidgets('backend replacement cancels a queued search before dispatch', (
    tester,
  ) async {
    final backend = _SearchBackend();
    final replacement = _SearchBackend();
    await tester.pumpWidget(_screen(backend));
    await tester.enterText(find.byType(TextField), 'private');
    await tester.pumpWidget(_screen(replacement));
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.requests, isEmpty);
    expect(replacement.requests, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('same-user login cannot revive a search from before logout', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await tester.pumpWidget(_screen(backend));
    await _type(tester, 'private');
    backend.signOut();
    backend.status = SessionStatus.ready;
    backend.notifyListeners();
    backend.requests.single.result.complete(
      MessageSearchPage(hits: [_hit('Retired session result')]),
    );
    await tester.pump();
    expect(find.text('Retired session result'), findsNothing);
    expect(find.textContaining('Account changed'), findsOneWidget);
  });

  for (final change in ['query', 'account']) {
    testWidgets('retired result tap is ignored after $change changes', (
      tester,
    ) async {
      final backend = _SearchBackend();
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MessageSearchScreen(
                      backend: backend,
                      palette: paletteFor(VisualTheme.parallax),
                    ),
                  ),
                );
              },
              child: const Text('Open search'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      await _type(tester, 'older');
      backend.requests.single.result.complete(
        MessageSearchPage(hits: [_hit('Old result')]),
      );
      await tester.pumpAndSettle();
      final oldTap = tester
          .widget<InkWell>(
            find
                .ancestor(
                  of: find.text('Old result'),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!;
      if (change == 'query') {
        // Invoke the platform edit callback before the old frame is replaced.
        tester.widget<TextField>(find.byType(TextField)).onChanged!('fresh');
      } else {
        backend.replaceAccount();
      }
      oldTap();
      await tester.pump();
      expect(find.byType(MessageSearchScreen), findsOneWidget);
      expect(selected, isNull);
      // Dispose the route before its fresh-query debounce can fire.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected, isNull);
      expect(backend.requests, hasLength(1));
    });
  }

  testWidgets('disposal cancels debounce and ignores pending page completion', (
    tester,
  ) async {
    final backend = _SearchBackend();
    await _startOldPage(tester, backend);
    await tester.pumpWidget(const SizedBox());
    backend.requests[1].result.completeError(StateError('closed screen'));
    backend.replaceAccount();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(_screen(backend));
    await tester.enterText(find.byType(TextField), 'unsent');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 400));
    expect(backend.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  group('device history search', () {
    /// Opens the search route; the returned getter yields the popped room.
    Future<String? Function()> openSearch(
      WidgetTester tester,
      _DeviceBackend backend,
    ) async {
      String? selected;
      var popped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MessageSearchScreen(
                        backend: backend,
                        palette: paletteFor(VisualTheme.parallax),
                      ),
                    ),
                  );
                  popped = true;
                },
                child: const Text('Open search'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open search'));
      await tester.pumpAndSettle();
      return () => popped ? selected : null;
    }

    testWidgets('combines device and server results and jumps to roots', (
      tester,
    ) async {
      final backend = _DeviceBackend();
      final popped = await openSearch(tester, backend);
      expect(backend.started, isTrue);
      expect(find.text('Search this device’s history'), findsOneWidget);
      await _type(tester, 'pizza');
      expect(backend.localQueries.single.query, 'pizza');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      backend.localQueries.single.result.complete(
        LocalSearchPage(
          hits: [
            _local(r'$thread-reply', root: r'$root'),
            _local(r'$plain'),
          ],
          nextOffset: 30,
        ),
      );
      backend.requests.single.result.complete(
        MessageSearchPage(hits: [_hit(r'$server')]),
      );
      await tester.pump();
      expect(find.text('ENCRYPTED ROOMS · THIS DEVICE'), findsOneWidget);
      expect(find.text('OTHER ROOMS · SERVER'), findsOneWidget);
      expect(find.text(r'$thread-reply'), findsOneWidget);
      expect(find.text('In a thread'), findsOneWidget);
      expect(find.text(r'$server'), findsOneWidget);

      await tester.tap(find.text('Load more from this device'));
      await tester.pump();
      expect(backend.localQueries.last.offset, 30);
      backend.localQueries.last.result.complete(
        LocalSearchPage(hits: [_local(r'$plain'), _local(r'$older')]),
      );
      await tester.pump();
      expect(find.text(r'$older'), findsOneWidget);
      expect(find.text(r'$plain'), findsOneWidget);
      expect(find.text('Load more from this device'), findsNothing);

      await tester.tap(find.text(r'$thread-reply'));
      await tester.pumpAndSettle();
      expect(backend.jumps.single, (
        room: '!secret:matrix.example',
        event: r'$root',
      ));
      expect(popped(), '!secret:matrix.example');
    });

    testWidgets('a failed jump still opens the room with a notice', (
      tester,
    ) async {
      final backend = _DeviceBackend()..failJump = true;
      final popped = await openSearch(tester, backend);
      await _type(tester, 'pizza');
      backend.localQueries.single.result.complete(
        const LocalSearchPage(hits: []),
      );
      backend.requests.single.result.complete(
        MessageSearchPage(hits: [_hit(r'$server')]),
      );
      await tester.pump();
      expect(find.text('No matches in this device’s history.'), findsOne);
      await tester.tap(find.text(r'$server'));
      await tester.pumpAndSettle();
      expect(backend.jumps.single.event, r'$server');
      expect(popped(), '!room:matrix.example');
      expect(
        find.text('Couldn’t jump to that message. Opening the room instead.'),
        findsOneWidget,
      );
    });

    testWidgets('local failures stay inline and server results still show', (
      tester,
    ) async {
      final backend = _DeviceBackend();
      await openSearch(tester, backend);
      await _type(tester, 'pizza');
      backend.localQueries.single.result.completeError(StateError('io'));
      backend.requests.single.result.complete(
        MessageSearchPage(hits: [_hit(r'$server')]),
      );
      await tester.pump();
      expect(find.text('Couldn’t search this device’s history.'), findsOne);
      expect(find.text(r'$server'), findsOneWidget);
    });

    testWidgets('turning device search off confirms and wipes the index', (
      tester,
    ) async {
      final backend = _DeviceBackend();
      await openSearch(tester, backend);
      await _type(tester, 'pizza');
      backend.localQueries.single.result.complete(
        LocalSearchPage(hits: [_local(r'$private')]),
      );
      backend.requests.single.result.complete(
        const MessageSearchPage(hits: []),
      );
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Turn off device search?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.enabledWrites, isEmpty);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn off'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.enabledWrites, [false]);
      // The query reruns as a server-only search.
      expect(find.text(r'$private'), findsNothing);
      expect(backend.requests, hasLength(2));
      expect(backend.localQueries, hasLength(1));
      backend.requests.last.result.complete(
        MessageSearchPage(hits: [_hit(r'$server')]),
      );
      await tester.pump();
      expect(find.text(r'$server'), findsOneWidget);
      expect(find.text('ENCRYPTED ROOMS · THIS DEVICE'), findsNothing);
    });

    testWidgets('account change discards late device results', (tester) async {
      final backend = _DeviceBackend();
      await openSearch(tester, backend);
      await _type(tester, 'pizza');
      backend.replaceAccount();
      await tester.pump();
      backend.localQueries.single.result.complete(
        LocalSearchPage(hits: [_local(r'$late-private')]),
      );
      await tester.pump();
      expect(find.text(r'$late-private'), findsNothing);
      expect(find.textContaining('Account changed'), findsOneWidget);
    });
  });
}

LocalMessageHit _local(String id, {String? root}) => LocalMessageHit(
  id: id,
  roomId: '!secret:matrix.example',
  roomName: 'Secret',
  sender: 'Alice',
  body: id,
  time: DateTime(2026),
  threadRootId: root,
);

class _DeviceBackend extends _SearchBackend
    implements LocalMessageSearch, TimelineNavigation {
  bool started = false;
  bool enabled = true;
  bool failJump = false;
  final enabledWrites = <bool>[];
  final localQueries =
      <({String query, int offset, Completer<LocalSearchPage> result})>[];
  final jumps = <({String room, String event})>[];

  @override
  void ensureStarted() => started = true;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> setEnabled(bool value) async {
    enabledWrites.add(value);
    enabled = value;
  }

  @override
  Future<void> clear() async {}
  @override
  Future<LocalSearchPage> search(
    String query, {
    int offset = 0,
    int limit = 30,
  }) {
    final result = Completer<LocalSearchPage>();
    localQueries.add((query: query, offset: offset, result: result));
    return result.future;
  }

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    jumps.add((room: roomId, event: eventId));
    if (failJump) throw StateError('gone');
  }

  @override
  String? focusedEventIn(String roomId) => null;
  @override
  bool hasNewerThanFocus(String roomId) => false;
  @override
  Future<void> jumpToLatest(String roomId) async {}
}
