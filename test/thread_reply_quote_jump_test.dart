import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/thread_features.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/thread_screen.dart';

const _roomId = '!room:example.org';

class _Backend extends ChatBackend
    implements MessagingFeatures, ThreadFeatures, TimelineNavigation {
  _Backend(this.page);
  final ThreadPage page;
  String? focused;
  bool failJump = false;
  final jumps = <List<String>>[];

  @override
  String get accountKey => 'account-a';
  @override
  String? get userId => '@me:example.org';
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
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) async => page;

  @override
  Future<void> markThreadRead(
    String roomId,
    String rootId,
    String eventId, {
    required bool public,
  }) async {}

  @override
  Stream<String> threadActivity(String roomId) => const Stream.empty();

  @override
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
    String? font,
  }) async {}

  int _jumpGen = 0;

  @override
  Future<void> openRoomAt(String roomId, String eventId) async {
    jumps.add([roomId, eventId]);
    if (failJump) throw StateError('Message unavailable');
    focused = eventId;
    _jumpGen++;
  }

  @override
  String? focusedEventIn(String roomId) => focused;
  @override
  int jumpGenerationIn(String roomId) => _jumpGen;
  @override
  bool hasNewerThanFocus(String roomId) => false;
  @override
  Future<void> jumpToLatest(String roomId) async {
    focused = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry _entry(
  String id, {
  String body = '',
  int minute = 0,
  String? replyToId,
}) => ChatEntry(
  id: id,
  sender: '@alice:example.org',
  senderName: 'Alice',
  body: body.isEmpty ? 'body $id' : body,
  time: DateTime(2026, 1, 1, 9, minute),
  mine: false,
  replyToId: replyToId,
);

Widget _app(Widget home) =>
    MaterialApp(theme: themeFor(VisualTheme.parallax), home: home);

void main() {
  Future<void> pumpThread(
    WidgetTester tester,
    _Backend backend,
    ChatEntry root,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(ThreadScreen(backend: backend, roomId: _roomId, root: root)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapping a quote scrolls to the source loaded in the thread', (
    tester,
  ) async {
    final replies = [
      for (var i = 1; i <= 40; i++)
        _entry(
          '\$r$i',
          body: 'reply $i',
          minute: i,
          replyToId: i == 40 ? r'$r1' : null,
        ),
    ];
    final backend = _Backend(ThreadPage(replies));
    await pumpThread(tester, backend, _entry(r'$root', body: 'Root message'));

    // Scroll down until the last reply's quote of reply 1 is on screen.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Alice: reply 1'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));

    await tester.tap(find.text('Alice: reply 1'));
    await tester.pumpAndSettle();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, lessThan(before));
    // The source bubble itself is back on screen; no room jump happened.
    final sourceTop = tester.getTopLeft(find.text('reply 1'));
    expect(sourceTop.dy, greaterThanOrEqualTo(0));
    expect(sourceTop.dy, lessThan(800));
    expect(backend.jumps, isEmpty);
    expect(backend.focused, isNull);
  });

  testWidgets('a quote whose source is not in the thread focuses the room', (
    tester,
  ) async {
    final backend = _Backend(
      ThreadPage([
        _entry(
          r'$r1',
          body: 'first reply',
          minute: 1,
          replyToId: r'$elsewhere',
        ),
      ]),
    );
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ThreadScreen(
                      backend: backend,
                      roomId: _roomId,
                      root: _entry(r'$root', body: 'Root message'),
                    ),
                  ),
                ),
                child: const Text('open thread'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open thread'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('In reply to an earlier message'));
    await tester.pumpAndSettle();

    expect(backend.jumps, [
      [_roomId, r'$elsewhere'],
    ]);
    expect(backend.focused, r'$elsewhere');
    expect(find.byType(ThreadScreen), findsNothing);
    expect(find.text('open thread'), findsOneWidget);
  });

  testWidgets('a failed room jump keeps the thread and explains itself', (
    tester,
  ) async {
    final backend = _Backend(
      ThreadPage([
        _entry(r'$r1', body: 'first reply', minute: 1, replyToId: r'$gone'),
      ]),
    )..failJump = true;
    await pumpThread(tester, backend, _entry(r'$root', body: 'Root message'));

    await tester.tap(find.text('In reply to an earlier message'));
    await tester.pumpAndSettle();

    expect(find.text('Couldn’t jump to that message.'), findsOneWidget);
    expect(find.byType(ThreadScreen), findsOneWidget);
  });

  testWidgets('long-pressing a quote still opens the action menu', (
    tester,
  ) async {
    final backend = _Backend(
      ThreadPage([
        _entry(r'$r1', body: 'first reply', minute: 1, replyToId: r'$root'),
      ]),
    );
    await pumpThread(tester, backend, _entry(r'$root', body: 'Root message'));

    await tester.longPress(find.text('Alice: Root message'));
    await tester.pumpAndSettle();

    expect(find.text('Quote in reply'), findsOneWidget);
    expect(backend.jumps, isEmpty);
  });
}
