import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/app_theme.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/directory_screen.dart';

class _Request {
  _Request(this.query, this.cursor);

  final String query;
  final String? cursor;
  final result = Completer<PublicRoomPage>();

  void succeed(List<String> names, {String? nextBatch}) => result.complete(
    PublicRoomPage(
      rooms: [
        for (final name in names)
          PublicRoom(id: '!$name:example.org', name: name, members: 1),
      ],
      nextBatch: nextBatch,
    ),
  );

  void fail() => result.completeError(StateError('private transport detail'));
}

class _Backend extends ChatBackend {
  final requests = <_Request>[];

  @override
  Future<PublicRoomPage> searchPublicRooms(String query, {String? nextBatch}) {
    final request = _Request(query, nextBatch);
    requests.add(request);
    return request.result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _directory(_Backend backend) => DirectoryScreen(
  backend: backend,
  palette: paletteFor(VisualTheme.ultraviolet),
);

Future<_Backend> _mount(
  WidgetTester tester, {
  bool holdInitial = false,
  bool routed = false,
}) async {
  final backend = _Backend();
  // Dispose before draining held requests, including when an assertion fails.
  // The tests themselves never have to release an obsolete request to progress.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final request in backend.requests) {
      if (!request.result.isCompleted) request.succeed([]);
    }
    await tester.pump();
    backend.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.ultraviolet),
      home: routed
          ? Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => _directory(backend),
                    transitionDuration: Duration.zero,
                    reverseTransitionDuration: Duration.zero,
                  ),
                ),
                child: const Text('Open directory'),
              ),
            )
          : _directory(backend),
    ),
  );
  if (routed) {
    await tester.tap(find.text('Open directory'));
    await tester.pump();
    await tester.pump();
  }
  expect(backend.requests, hasLength(1));
  expect(backend.requests.single.query, '');
  expect(backend.requests.single.cursor, isNull);
  if (!holdInitial) {
    backend.requests.single.succeed([]);
    await tester.pump();
  }
  return backend;
}

Future<_Request> _search(
  WidgetTester tester,
  _Backend backend,
  String query,
) async {
  final before = backend.requests.length;
  await tester.enterText(find.byType(TextField), query);
  // Advance only the production debounce in fake time, not network completion.
  await tester.pump(const Duration(milliseconds: 350));
  expect(backend.requests, hasLength(before + 1));
  final request = backend.requests.last;
  expect(request.query, query.trim());
  expect(request.cursor, isNull);
  return request;
}

Future<_Backend> _seed(WidgetTester tester, {bool routed = false}) async {
  final backend = await _mount(tester, routed: routed);
  final alpha = await _search(tester, backend, 'alpha');
  alpha.succeed(['Alpha'], nextBatch: 'alpha:next');
  await tester.pump();
  return backend;
}

VoidCallback _readyMore(WidgetTester tester) {
  final button = find.widgetWithText(TextButton, 'Load more');
  expect(
    button,
    findsOneWidget,
    reason: 'The current query must not wait for an obsolete page to settle.',
  );
  final callback = tester.widget<TextButton>(button).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<_Request> _more(WidgetTester tester, _Backend backend) async {
  final before = backend.requests.length;
  _readyMore(tester);
  final button = find.widgetWithText(TextButton, 'Load more');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  expect(backend.requests, hasLength(before + 1));
  return backend.requests.last;
}

void _expectPaging(WidgetTester tester) {
  final button = find.widgetWithText(TextButton, 'Loading…');
  expect(button, findsOneWidget);
  expect(tester.widget<TextButton>(button).onPressed, isNull);
  expect(find.text('Load more'), findsNothing);
}

void _expectNoError(WidgetTester tester) {
  expect(find.textContaining('Couldn’t'), findsNothing);
  expect(find.textContaining('private transport detail'), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('new query paginates while obsolete page never settles', (
    tester,
  ) async {
    final backend = await _seed(tester);
    final obsolete = await _more(tester, backend);
    expect(obsolete.query, 'alpha');
    expect(obsolete.cursor, 'alpha:next');

    final beta = await _search(tester, backend, ' beta ');
    beta.succeed(['Beta'], nextBatch: 'beta:next');
    await tester.pump();
    final next = await _more(tester, backend);
    expect(next.query, 'beta');
    expect(next.cursor, 'beta:next');
    next.succeed(['Beta', 'Beta two', 'Beta two'], nextBatch: 'beta:last');
    await tester.pump();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Beta two'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    final last = await _more(tester, backend);
    expect(last.query, 'beta');
    expect(last.cursor, 'beta:last');
    last.succeed(['Beta three']);
    await tester.pump();
    expect(find.text('Beta three'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(find.text('Loading…'), findsNothing);
    expect(obsolete.result.isCompleted, isFalse);
    _expectNoError(tester);
  });

  for (final fails in [false, true]) {
    final outcome = fails ? 'error' : 'success';
    for (final phase in ['first page', 'ready', 'pagination', 'complete']) {
      testWidgets('stale page $outcome during $phase cannot change owner', (
        tester,
      ) async {
        final backend = await _seed(tester);
        final obsolete = await _more(tester, backend);
        final beta = await _search(tester, backend, 'beta');
        _Request? currentPage;
        VoidCallback? retainedMore;
        if (phase != 'first page') {
          beta.succeed(['Beta'], nextBatch: 'beta:next');
          await tester.pump();
          if (phase != 'ready') {
            retainedMore = _readyMore(tester);
            currentPage = await _more(tester, backend);
            expect(currentPage.cursor, 'beta:next');
            if (phase == 'complete') {
              currentPage.succeed(['Beta two'], nextBatch: 'beta:last');
              await tester.pump();
            }
          }
        }

        if (fails) {
          obsolete.fail();
        } else {
          obsolete.succeed(['Obsolete'], nextBatch: 'wrong:cursor');
        }
        await tester.pump();
        expect(find.text('Obsolete'), findsNothing);
        expect(find.text('Alpha'), findsNothing);
        _expectNoError(tester);

        if (phase == 'first page') {
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          beta.succeed(['Beta'], nextBatch: 'beta:next');
          await tester.pump();
        } else if (phase == 'pagination') {
          // Stale finally must not release this page's single-flight guard.
          _expectPaging(tester);
          final count = backend.requests.length;
          retainedMore!();
          retainedMore();
          await tester.pump();
          expect(backend.requests, hasLength(count));
          currentPage!.succeed(['Beta two'], nextBatch: 'beta:last');
          await tester.pump();
        }
        expect(find.text('Beta'), findsOneWidget);
        final next = await _more(tester, backend);
        expect(next.query, 'beta');
        expect(
          next.cursor,
          phase == 'pagination' || phase == 'complete'
              ? 'beta:last'
              : 'beta:next',
        );
        next.succeed([]);
        await tester.pump();
        expect(find.text('Load more'), findsNothing);
        _expectNoError(tester);
      });
    }

    testWidgets('stale first-page $outcome cannot finish a newer search', (
      tester,
    ) async {
      final backend = await _mount(tester, holdInitial: true);
      final obsolete = backend.requests.single;
      final alpha = await _search(tester, backend, 'alpha');
      if (fails) {
        obsolete.fail();
      } else {
        obsolete.succeed(['Obsolete'], nextBatch: 'wrong:cursor');
      }
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Obsolete'), findsNothing);
      _expectNoError(tester);
      alpha.succeed(['Alpha'], nextBatch: 'alpha:next');
      await tester.pump();
      final next = await _more(tester, backend);
      expect(next.query, 'alpha');
      expect(next.cursor, 'alpha:next');
      next.succeed([]);
      await tester.pump();
    });

    testWidgets('repeated query and cursor still reject stale $outcome', (
      tester,
    ) async {
      final backend = await _seed(tester);
      final obsolete = await _more(tester, backend);
      final beta = await _search(tester, backend, 'beta');
      beta.succeed(['Beta'], nextBatch: 'beta:next');
      await tester.pump();
      final alpha = await _search(tester, backend, ' alpha ');
      alpha.succeed(['Fresh alpha'], nextBatch: 'alpha:next');
      await tester.pump();
      final retainedMore = _readyMore(tester);
      final current = await _more(tester, backend);
      expect(current.query, obsolete.query);
      expect(current.cursor, obsolete.cursor);
      if (fails) {
        obsolete.fail();
      } else {
        obsolete.succeed(['Obsolete'], nextBatch: 'wrong:cursor');
      }
      await tester.pump();
      _expectPaging(tester);
      retainedMore();
      await tester.pump();
      expect(backend.requests.last, same(current));
      current.succeed(['Alpha two'], nextBatch: 'alpha:last');
      await tester.pump();
      expect(find.text('Fresh alpha'), findsOneWidget);
      expect(find.text('Alpha two'), findsOneWidget);
      expect(find.text('Obsolete'), findsNothing);
      _expectNoError(tester);
      final last = await _more(tester, backend);
      expect(last.query, 'alpha');
      expect(last.cursor, 'alpha:last');
      last.succeed([]);
      await tester.pump();
    });

    for (final pendingPage in [false, true]) {
      testWidgets(
        'disposed directory ignores held ${pendingPage ? 'page' : 'search'} $outcome',
        (tester) async {
          final backend = await _seed(tester, routed: true);
          final obsolete = await _more(tester, backend);
          final beta = await _search(tester, backend, 'beta');
          _Request current = beta;
          if (pendingPage) {
            beta.succeed(['Beta'], nextBatch: 'beta:next');
            await tester.pump();
            current = await _more(tester, backend);
          }
          final state = tester.state(find.byType(DirectoryScreen));
          Navigator.pop(tester.element(find.byType(DirectoryScreen)));
          await tester.pump();
          await tester.pump();
          expect(state.mounted, isFalse);
          expect(obsolete.result.isCompleted, isFalse);
          expect(current.result.isCompleted, isFalse);
          if (fails) {
            obsolete.fail();
            current.fail();
          } else {
            obsolete.succeed(['Obsolete'], nextBatch: 'wrong:cursor');
            current.succeed(['Late beta'], nextBatch: 'beta:last');
          }
          await tester.pump();
          expect(find.text('Open directory'), findsOneWidget);
          expect(find.text('Obsolete'), findsNothing);
          expect(find.text('Late beta'), findsNothing);
          _expectNoError(tester);
        },
      );
    }
  }

  testWidgets('query change rejects retained pagination before next frame', (
    tester,
  ) async {
    final backend = await _seed(tester);
    final retainedMore = _readyMore(tester);
    final before = backend.requests.length;
    tester.widget<TextField>(find.byType(TextField)).onChanged!('beta');
    retainedMore();
    expect(backend.requests, hasLength(before));
    await tester.pump(const Duration(milliseconds: 350));
    final beta = backend.requests.last;
    expect(beta.query, 'beta');
    expect(beta.cursor, isNull);
    // No old cursor may be paired with beta while its first page is pending.
    retainedMore();
    expect(backend.requests, hasLength(before + 1));
    beta.succeed(['Beta'], nextBatch: 'beta:next');
    await tester.pump();
    final next = await _more(tester, backend);
    expect(next.cursor, 'beta:next');
    next.succeed([]);
    await tester.pump();
    _expectNoError(tester);
  });

  testWidgets('current page failure releases only its own guard for retry', (
    tester,
  ) async {
    final backend = await _seed(tester);
    final retainedMore = _readyMore(tester);
    // Re-entrant taps before a rebuild must also remain single-flight.
    retainedMore();
    retainedMore();
    await tester.pump();
    final request = backend.requests.last;
    expect(backend.requests, hasLength(3));
    _expectPaging(tester);
    request.fail();
    await tester.pump();
    expect(find.text('Couldn’t load more rooms.'), findsOneWidget);
    expect(find.textContaining('private transport detail'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
    final retry = await _more(tester, backend);
    expect(retry.query, request.query);
    expect(retry.cursor, request.cursor);
    retry.succeed(['Alpha', 'Alpha two']);
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Alpha two'), findsOneWidget);
    expect(find.text('Load more'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed replacement search can retry without obsolete page', (
    tester,
  ) async {
    final backend = await _seed(tester);
    final obsolete = await _more(tester, backend);
    final failed = await _search(tester, backend, 'beta');
    failed.fail();
    await tester.pump();
    expect(
      find.text('Couldn’t search this server’s public rooms.'),
      findsOneWidget,
    );
    // Edit the raw text so TextField emits onChanged for the same trimmed term.
    final retry = await _search(tester, backend, ' beta ');
    retry.succeed(['Beta'], nextBatch: 'beta:next');
    await tester.pump();
    final next = await _more(tester, backend);
    expect(next.query, 'beta');
    expect(next.cursor, 'beta:next');
    next.succeed([]);
    await tester.pump();
    expect(obsolete.result.isCompleted, isFalse);
    _expectNoError(tester);
  });

  testWidgets('debounce coalesces edits and empty query starts a fresh scan', (
    tester,
  ) async {
    final backend = await _seed(tester);
    final obsolete = await _more(tester, backend);
    final before = backend.requests.length;
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump(const Duration(milliseconds: 349));
    await tester.enterText(find.byType(TextField), 'gamma');
    await tester.pump(const Duration(milliseconds: 349));
    expect(backend.requests, hasLength(before));
    await tester.pump(const Duration(milliseconds: 1));
    expect(backend.requests, hasLength(before + 1));
    final gamma = backend.requests.last;
    expect(gamma.query, 'gamma');
    final empty = await _search(tester, backend, '   ');
    empty.succeed(['Unfiltered'], nextBatch: 'unfiltered:next');
    await tester.pump();
    final next = await _more(tester, backend);
    expect(next.query, '');
    expect(next.cursor, 'unfiltered:next');
    gamma.succeed(['Obsolete gamma'], nextBatch: 'wrong:cursor');
    await tester.pump();
    _expectPaging(tester);
    next.succeed([]);
    await tester.pump();
    expect(find.text('Unfiltered'), findsOneWidget);
    expect(find.text('Obsolete gamma'), findsNothing);
    expect(obsolete.result.isCompleted, isFalse);
    _expectNoError(tester);
  });

  testWidgets('dispose cancels queued debounce without starting a request', (
    tester,
  ) async {
    final backend = await _seed(tester);
    await tester.enterText(find.byType(TextField), 'beta');
    final before = backend.requests.length;
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 1));
    expect(backend.requests, hasLength(before));
    expect(tester.takeException(), isNull);
  });
}
