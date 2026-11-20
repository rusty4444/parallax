import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'widget_test.dart' show FakeBackend;

const _roomId = '!room:matrix.example';
const _sourceId = r'$source';
const _replyId = r'$reply';

/// Fake backend that can focus events, recording every jump.
class _JumpBackend extends FakeBackend implements TimelineNavigation {
  final jumps = <List<String>>[];
  String? focused;
  bool failJump = false;
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
}

ChatEntry _entry(
  String id, {
  String? replyToId,
  bool mine = false,
  String body = 'hello',
}) => ChatEntry(
  id: id,
  sender: mine ? '@me:example.org' : '@alice:example.org',
  senderName: 'Alice',
  body: body,
  time: DateTime(2026, 11, 20, 12),
  mine: mine,
  replyToId: replyToId,
);

void main() {
  final palette = paletteFor(VisualTheme.parallax);

  Future<void> pumpBubble(
    WidgetTester tester, {
    required ChatBackend backend,
    required ChatEntry entry,
    ChatEntry? replyPreview,
    VoidCallback? onHeart,
    VoidCallback? onAction,
  }) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: EdgeInsets.zero,
            children: [
              MessageBubble(
                entry: entry,
                backend: backend,
                roomId: _roomId,
                palette: palette,
                group: false,
                onHeart: onHeart ?? () {},
                onAction: onAction ?? () {},
                onReaction: (_) {},
                replyPreview: replyPreview,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // The bubble also listens for a double tap, so a single tap on the quote
  // only counts once that wait is over (same as in-bubble links).
  Future<void> tapQuote(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  group('reply quote jump', () {
    testWidgets('tapping the quote jumps to the original message', (
      tester,
    ) async {
      final backend = _JumpBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId, body: 'yes, pizza'),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
      );

      await tapQuote(tester, 'Alice: pizza tonight?');

      expect(backend.jumps, [
        [_roomId, _sourceId],
      ]);
    });

    testWidgets('a failed jump explains itself without leaving the room', (
      tester,
    ) async {
      final backend = _JumpBackend()
        ..currentUserId = '@me:example.org'
        ..failJump = true;
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
      );

      await tapQuote(tester, 'Alice: pizza tonight?');
      await tester.pump(const Duration(milliseconds: 300));

      expect(backend.jumps, [
        [_roomId, _sourceId],
      ]);
      expect(find.text('Couldn’t jump to that message.'), findsOneWidget);
    });

    testWidgets('a quote without a server event ID stays inert', (
      tester,
    ) async {
      final backend = _JumpBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        // A pending local echo has a transaction ID, not a `$` event ID.
        entry: _entry(_replyId, replyToId: 'txid-123'),
        replyPreview: _entry('txid-123', body: 'still sending'),
      );

      await tapQuote(tester, 'Alice: still sending');

      expect(backend.jumps, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('backends without timeline navigation stay inert', (
      tester,
    ) async {
      final backend = FakeBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
      );

      await tapQuote(tester, 'Alice: pizza tonight?');

      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping again re-jumps so the view scrolls back to it', (
      tester,
    ) async {
      // Nothing is hidden after a jump, so the reader may have scrolled away;
      // tapping the same quote again must scroll back to the source.
      final backend = _JumpBackend()
        ..currentUserId = '@me:example.org'
        ..focused = _sourceId;
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
      );

      await tapQuote(tester, 'Alice: pizza tonight?');

      expect(backend.jumps, [
        [_roomId, _sourceId],
      ]);
    });

    testWidgets('long-pressing the quote still opens the action menu', (
      tester,
    ) async {
      var actions = 0;
      final backend = _JumpBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
        onAction: () => actions++,
      );

      await tester.longPress(find.text('Alice: pizza tonight?'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(actions, 1);
      expect(backend.jumps, isEmpty);
    });

    testWidgets('double-tapping the body still reacts', (tester) async {
      var hearts = 0;
      final backend = _JumpBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId, body: 'yes, pizza'),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
        onHeart: () => hearts++,
      );

      await tester.tap(find.text('yes, pizza'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('yes, pizza'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(hearts, 1);
      expect(backend.jumps, isEmpty);
    });

    testWidgets('clicking works on desktop (inside the selection area)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final backend = _JumpBackend()..currentUserId = '@me:example.org';
      await pumpBubble(
        tester,
        backend: backend,
        entry: _entry(_replyId, replyToId: _sourceId),
        replyPreview: _entry(_sourceId, body: 'pizza tonight?'),
      );

      await tapQuote(tester, 'Alice: pizza tonight?');

      expect(backend.jumps, [
        [_roomId, _sourceId],
      ]);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('reply quote jump on the real backend', () {
    Map<String, Object?> event(
      String id,
      int ts, {
      String? body,
      String? inReplyTo,
    }) => {
      'event_id': id,
      'type': 'm.room.message',
      'sender': '@alice:matrix.example',
      'origin_server_ts': ts,
      'room_id': _roomId,
      'content': {
        'msgtype': 'm.text',
        'body': body ?? 'message $id',
        if (inReplyTo != null)
          'm.relates_to': {
            'm.in_reply_to': {'event_id': inReplyTo},
          },
      },
    };

    testWidgets('jumps to the source without hiding newer messages', (
      tester,
    ) async {
      final db = _Database()
        ..cached = [
          event(_replyId, 3000, body: 'yes, pizza', inReplyTo: _sourceId),
          event(_sourceId, 2000, body: 'pizza tonight?'),
          event(r'$older', 1000),
        ];
      final client = _Client(db, (request) async => http.Response('{}', 200));
      final backend = MatrixBackend.withClient(client);
      addTearDown(backend.dispose);
      await backend.openRoom(_roomId);

      final reply = backend.messages.firstWhere((e) => e.id == _replyId);
      final source = backend.messages.firstWhere((e) => e.id == _sourceId);
      expect(reply.replyToId, _sourceId);
      await pumpBubble(
        tester,
        backend: backend,
        entry: reply,
        replyPreview: source,
      );

      await tapQuote(tester, '${source.senderLabel}: pizza tonight?');

      expect(backend.focusedEventId, _sourceId);
      // The whole live timeline stays loaded: the reply (newer) is still
      // there below the source, so scrolling back down just works.
      expect(backend.messages.map((e) => e.id), [
        r'$older',
        _sourceId,
        _replyId,
      ]);

      await timelineNavigationOf(backend)!.jumpToLatest(_roomId);
      expect(backend.focusedEventId, isNull);
      expect(backend.messages.map((e) => e.id), [
        r'$older',
        _sourceId,
        _replyId,
      ]);
      // Flush the backend's member-lookup (10 s timeout each) and
      // mark-read timers.
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(seconds: 11));
    });
  });
}

class _Database extends Fake implements matrix.DatabaseApi {
  /// Locally cached timeline, newest first (as the SDK stores it).
  List<Map<String, Object?>> cached = const [];

  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => onlySending
      ? const []
      : [for (final json in cached) matrix.Event.fromJson(json, room)];

  @override
  Future<List<matrix.Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    matrix.Room room,
  ) async => const [];

  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async => null;

  @override
  Future<void> close() async {}
}

class _Client extends matrix.Client {
  _Client(this.db, Future<http.Response> Function(http.Request) respond)
    : super('reply-quote-test', database: db, httpClient: MockClient(respond)) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
    rooms.add(matrix.Room(id: _roomId, client: this));
  }
  final _Database db;
  @override
  String? get userID => '@sam:matrix.example';
  @override
  String? get deviceID => 'DEVICE';
}
