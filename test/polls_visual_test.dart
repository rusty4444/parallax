// Visual QA for the polls/location module. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/polls_visual_test.dart
// Map tiles are replaced by a placeholder (no network in tests).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/polls/create_poll_screen.dart';
import 'package:parallax/features/polls/location_map.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/features/polls/poll_features.dart';
import 'package:parallax/features/polls/poll_history_screen.dart';
import 'package:parallax/features/polls/poll_model.dart';
import 'package:parallax/features/polls/share_location_screen.dart';
import 'package:parallax/timeline/message_bubble.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
const _me = '@sam:example.org';
const _room = '!a:example.org';

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

Future<void> _shoot(WidgetTester tester, String name, Widget child) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: key, child: child));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

class _Backend extends ChatBackend implements PollFeatures, LocationFeatures {
  final _updates = ValueNotifier<int>(0);
  final snapshots = <String, PollSnapshot>{};
  List<ChatEntry> entries = const [];

  @override
  String? get userId => _me;
  @override
  String? get activeRoomId => _room;
  @override
  List<ChatEntry> get messages => entries;
  @override
  List<ChatRoom> get rooms => const [];
  @override
  bool get canLoadOlder => true;
  @override
  bool get loadingHistory => false;
  @override
  Listenable get pollUpdates => _updates;
  @override
  PollSnapshot? pollSnapshot(String roomId, String pollId) => snapshots[pollId];
  @override
  void ensurePollLoaded(String roomId, String pollId, {bool retry = false}) {}
  @override
  bool mayEndPoll(String roomId, String userId, String pollSenderId) =>
      userId == pollSenderId;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PollRelation _vote(String sender, List<String> answers, {int ts = 1}) =>
    PollRelation(
      eventId: '\$v$sender$ts',
      kind: PollRelationKind.response,
      sender: sender,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      answers: answers,
    );

ChatEntry _poll(String id, String sender, PollStart poll) => ChatEntry(
  id: id,
  sender: sender,
  senderName: sender == _me ? 'Sam' : 'Mia',
  body: poll.fallbackText,
  time: DateTime(2026, 11, 12, 9, 30),
  mine: sender == _me,
  kind: EntryKind.poll,
  eventType: pollStartType,
  content: poll.toStartContent(),
);

const _lunch = PollStart(
  question: 'Where should we go for Friday lunch?',
  answers: [
    PollAnswer(id: 'a', text: 'Thai on King St'),
    PollAnswer(id: 'b', text: 'Dumplings'),
    PollAnswer(id: 'c', text: 'Fish and chips by the beach'),
  ],
);

const _secret = PollStart(
  question: 'Should we move stand-up to 9:30?',
  answers: [
    PollAnswer(id: 'y', text: 'Yes'),
    PollAnswer(id: 'n', text: 'No'),
  ],
  disclosed: false,
);

_Backend _backend() {
  final backend = _Backend();
  backend.snapshots[r'$lunch'] = PollSnapshot(
    state: PollLoadState.ready,
    relations: [
      _vote('@a:x', ['a']),
      _vote('@b:x', ['a']),
      _vote('@c:x', ['b']),
      _vote(_me, ['a']),
    ],
  );
  backend.snapshots[r'$secret'] = PollSnapshot(
    state: PollLoadState.ready,
    relations: [
      _vote('@a:x', ['y']),
      _vote('@b:x', ['n']),
      _vote('@c:x', ['y']),
      PollRelation(
        eventId: r'$end',
        kind: PollRelationKind.end,
        sender: _me,
        timestamp: DateTime.fromMillisecondsSinceEpoch(5),
      ),
    ],
  );
  backend.snapshots[r'$mine'] = const PollSnapshot(state: PollLoadState.ready);
  backend.entries = [
    _poll(r'$lunch', '@mia:x', _lunch),
    _poll(r'$secret', _me, _secret),
    _poll(
      r'$mine',
      _me,
      const PollStart(
        question: 'Board games night?',
        answers: [
          PollAnswer(id: '1', text: 'Saturday'),
          PollAnswer(id: '2', text: 'Sunday'),
        ],
        maxSelections: 2,
      ),
    ),
    ChatEntry(
      id: r'$loc',
      sender: '@mia:x',
      senderName: 'Mia',
      body: 'Location',
      time: DateTime(2026, 11, 12, 10),
      mine: false,
      kind: EntryKind.location,
      msgtype: 'm.location',
      content: locationContent(
        point: const GeoPoint(-33.8568, 151.2153),
        asset: LocationAsset.self,
        now: DateTime(2026, 11, 12, 10),
      ),
    ),
    ChatEntry(
      id: r'$pin',
      sender: _me,
      senderName: 'Sam',
      body: 'Location',
      time: DateTime(2026, 11, 12, 10, 5),
      mine: true,
      kind: EntryKind.location,
      msgtype: 'm.location',
      content: locationContent(
        point: const GeoPoint(-33.86, 151.21),
        asset: LocationAsset.pin,
        now: DateTime(2026, 11, 12, 10, 5),
      ),
    ),
  ];
  return backend;
}

class _NoLocator implements DeviceLocator {
  @override
  Future<GeoPoint?> currentIfPermitted() async => null;
  @override
  Future<GeoPoint> locate() async => const GeoPoint(0, 0);
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR' : null;
  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });
  setUp(() => locationMapTilesEnabled = false);
  tearDown(() => locationMapTilesEnabled = true);

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);
    for (final (name, polls) in [('polls', true), ('location', false)]) {
      testWidgets('$name timeline ${style.name}', skip: skip != null, (
        tester,
      ) async {
        final backend = _backend();
        backend.entries = [
          for (final entry in backend.entries)
            if ((entry.kind == EntryKind.poll) == polls) entry,
        ];
        await _shoot(
          tester,
          '${name}_timeline_${style.name}',
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: Scaffold(
              body: GlowBackdrop(
                palette: p,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
                  children: [
                    for (final entry in backend.entries)
                      MessageBubble(
                        entry: entry,
                        backend: backend,
                        roomId: _room,
                        palette: p,
                        group: false,
                        onHeart: () {},
                        onAction: () {},
                        onReaction: (_) {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      });
    }

    testWidgets('create ${style.name}', skip: skip != null, (tester) async {
      await _shoot(
        tester,
        'polls_create_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: CreatePollScreen(
            palette: p,
            roomId: _room,
            features: _backend(),
            editing: (pollId: r'$lunch', poll: _lunch),
          ),
        ),
      );
    });

    testWidgets('share ${style.name}', skip: skip != null, (tester) async {
      await _shoot(
        tester,
        'polls_share_location_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: ShareLocationScreen(
            palette: p,
            roomId: _room,
            features: _backend(),
            locator: _NoLocator(),
          ),
        ),
      );
    });

    testWidgets('history ${style.name}', skip: skip != null, (tester) async {
      final backend = _backend();
      await _shoot(
        tester,
        'polls_history_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: PollHistoryScreen(
            backend: backend,
            features: backend,
            palette: p,
            roomId: _room,
          ),
        ),
      );
    });
  }
}
