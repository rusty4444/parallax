// Visual QA for the threads/search module. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set (see test/visual/render_screens_test.dart):
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/threads_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/threads/local_message_search.dart';
import 'package:parallax/features/threads/thread_features.dart';
import 'package:parallax/features/threads/thread_list_screen.dart';
import 'package:parallax/features/threads/thread_models.dart';
import 'package:parallax/features/threads/timeline_navigation.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/thread_screen.dart';

import 'widget_test.dart' show FakeBackend;

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
const _roomId = '!a:example.org';

Future<void> _loadFonts() async {
  final grotesk = FontLoader('SpaceGrotesk')
    ..addFont(
      File(
        'assets/fonts/SpaceGrotesk.ttf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  await grotesk.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  }
}

Future<void> _shoot(
  WidgetTester tester,
  String name,
  Widget child, {
  Future<void> Function()? before,
}) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: key, child: child));
  await before?.call();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

ChatEntry _e(
  String id,
  String body, {
  String name = 'Mia',
  int minutesAgo = 0,
  bool mine = false,
  int replies = 0,
  String? latest,
}) => ChatEntry(
  id: id,
  sender: mine ? '@sam:example.org' : '@${name.toLowerCase()}:example.org',
  senderName: mine ? 'Sam' : name,
  body: body,
  time: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  mine: mine,
  threadReplyCount: replies,
  threadLatestBody: latest,
);

class _Backend extends FakeBackend
    implements
        MessagingFeatures,
        ThreadFeatures,
        TimelineNavigation,
        LocalMessageSearch {
  String? focused;
  @override
  String get accountKey => 'visual';
  @override
  List<PendingSend> get pendingSends => const [];
  @override
  Future<ThreadListPage> loadThreads(
    String roomId, {
    ThreadListFilter filter = ThreadListFilter.all,
    String? nextBatch,
  }) async => ThreadListPage([
    ThreadSummary(
      root: _e(r'$t1', 'Sunset at the pier this Saturday?', minutesAgo: 90),
      replyCount: 7,
      latest: _e(r'$l1', 'I can bring the camera!', name: 'Alex'),
      unread: true,
    ),
    ThreadSummary(
      root: _e(
        r'$t2',
        'Packing list for the camping trip — add anything missing',
        name: 'Alex',
        minutesAgo: 3000,
      ),
      replyCount: 1,
      latest: _e(r'$l2', 'Torch and spare batteries', mine: true),
      unread: false,
    ),
  ]);
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
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  }) async => ThreadPage([
    _e(r'$r1', 'Count me in 🙌', name: 'Alex', minutesAgo: 40),
    _e(r'$r2', 'Same. What time?', mine: true, minutesAgo: 30),
    _e(r'$r3', 'Golden hour is around 7:40', minutesAgo: 10),
  ]);
  @override
  Future<void> openRoomAt(String roomId, String eventId) async =>
      focused = eventId;
  @override
  String? focusedEventIn(String roomId) => focused;
  @override
  bool hasNewerThanFocus(String roomId) => focused != null;
  @override
  Future<void> jumpToLatest(String roomId) async => focused = null;
  @override
  void ensureStarted() {}
  @override
  Future<bool> isEnabled() async => true;
  @override
  Future<void> setEnabled(bool enabled) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<LocalSearchPage> search(
    String query, {
    int offset = 0,
    int limit = 30,
  }) async => LocalSearchPage(
    hits: [
      LocalMessageHit(
        id: r'$h1',
        roomId: _roomId,
        roomName: 'Weekend crew',
        sender: 'Mia',
        body: 'Sunset at the pier this Saturday?',
        time: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      LocalMessageHit(
        id: r'$h2',
        roomId: _roomId,
        roomName: 'Weekend crew',
        sender: 'Alex',
        body: 'The pier café opens at 7',
        time: DateTime.now().subtract(const Duration(days: 3)),
        threadRootId: r'$t1',
      ),
    ],
  );
  @override
  Future<MessageSearchPage> searchMessages(
    String query, {
    String? nextBatch,
  }) async => MessageSearchPage(
    hits: [
      MessageHit(
        id: r'$s1',
        roomId: '!c:example.org',
        roomName: 'Matrix HQ',
        sender: '@alex:example.org',
        body: 'Anyone been to the new pier market?',
        time: DateTime.now().subtract(const Duration(days: 9)),
      ),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_Backend _backend() => _Backend()
  ..currentUserId = '@sam:example.org'
  ..roomList = [
    ChatRoom(
      id: _roomId,
      name: 'Weekend crew',
      preview: '',
      lastActivity: DateTime.now(),
      encrypted: true,
    ),
  ]
  ..entries = [
    _e(r'$1', 'Who is around this weekend?', name: 'Alex', minutesAgo: 120),
    _e(
      r'$t1',
      'Sunset at the pier this Saturday?',
      minutesAgo: 90,
      replies: 7,
      latest: 'I can bring the camera!',
    ),
  ];

void main() {
  final skip = _dir == null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);
    Widget app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFor(style),
      home: home,
    );

    testWidgets('threads list ${style.name}', skip: skip, (tester) async {
      await _shoot(
        tester,
        'threads_list_${style.name}',
        app(
          ThreadsListScreen(backend: _backend(), roomId: _roomId, palette: p),
        ),
      );
    });

    testWidgets('thread ${style.name}', skip: skip, (tester) async {
      await _shoot(
        tester,
        'thread_${style.name}',
        app(
          ThreadScreen(
            backend: _backend(),
            roomId: _roomId,
            root: _e(r'$t1', 'Sunset at the pier this Saturday?', replies: 3),
            palette: p,
          ),
        ),
      );
    });

    testWidgets('room with thread and focus ${style.name}', skip: skip, (
      tester,
    ) async {
      final backend = _backend()..focused = r'$t1';
      await _shoot(
        tester,
        'room_threads_${style.name}',
        app(RoomScreen(backend: backend, palette: p, roomId: _roomId)),
      );
    });

    testWidgets('message search ${style.name}', skip: skip, (tester) async {
      await _shoot(
        tester,
        'message_search_${style.name}',
        app(
          InboxScreen(
            backend: _backend(),
            palette: p,
            style: style,
            onThemeChanged: (_) {},
          ),
        ),
        before: () async {
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('home.search_toggle')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('home.conversation_search')),
            'pier',
          );
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          unawaited(Future<void>.value());
        },
      );
    });
  }
}
