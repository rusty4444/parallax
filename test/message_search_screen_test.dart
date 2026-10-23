import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/app_theme.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/message_search_screen.dart';
import 'package:matrixpress/messaging_features.dart';

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
    palette: paletteFor(VisualTheme.ultraviolet),
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
                      palette: paletteFor(VisualTheme.ultraviolet),
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
}
