// Visual QA for the live location module. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/live_location_visual_test.dart
// Map tiles are replaced by a placeholder (no network in tests).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/live_location/live_location_features.dart';
import 'package:parallax/features/live_location/live_location_hooks.dart';
import 'package:parallax/features/live_location/live_location_model.dart';
import 'package:parallax/features/live_location/live_location_sharer.dart';
import 'package:parallax/features/live_location/live_location_view.dart';
import 'package:parallax/features/live_location/position_source.dart';
import 'package:parallax/features/live_location/start_live_location.dart';
import 'package:parallax/features/polls/location_map.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'live_location_fakes.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
const _me = '@sam:example.org';
const _alice = '@alice:example.org';
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

BeaconInfo _info(String id, String sender, Duration ago, {bool live = true}) {
  final start = DateTime.now().toUtc().subtract(ago);
  return BeaconInfo(
    eventId: id,
    type: beaconInfoUnstableType,
    stateKey: sender,
    sender: sender,
    live: live,
    start: start,
    timeout: const Duration(hours: 1),
    sentAt: start,
  );
}

LiveShareSnapshot _snap(BeaconInfo info, String name, {bool located = true}) =>
    LiveShareSnapshot(
      info: info,
      live: info.isLiveAt(DateTime.now()),
      displayName: name,
      mine: info.sender == _me,
      latest: located
          ? BeaconLocation(
              eventId: '\$b${info.eventId}',
              sender: info.sender,
              beaconInfoId: info.eventId,
              point: const GeoPoint(-33.8688, 151.2093),
              timestamp: DateTime.now().toUtc().subtract(
                const Duration(minutes: 1),
              ),
            )
          : null,
    );

class _Backend extends ChatBackend implements LiveLocationFeatures {
  final _updates = ValueNotifier<int>(0);
  final snapshots = <String, LiveShareSnapshot>{};
  List<LiveShareSnapshot> live = const [];
  OwnShare? device;

  @override
  String? get userId => _me;
  @override
  List<ChatEntry> get messages => const [];
  @override
  List<ChatRoom> get rooms => const [];
  @override
  Listenable get updates => _updates;
  @override
  String? get myUserId => _me;
  @override
  LivePositionSource get positions => FakePositions();
  @override
  List<LiveShareSnapshot> liveShares(String roomId) => live;
  @override
  LiveShareSnapshot shareSnapshot(String roomId, BeaconInfo info) =>
      snapshots[info.eventId]!;
  @override
  void ensureBeaconsLoaded(String roomId, BeaconInfo info) {}
  @override
  OwnShare? deviceShare(String roomId) => device;
  @override
  bool canShareIn(String roomId) => true;
  @override
  Future<void> startSharing(String roomId, Duration duration) async {}
  @override
  Future<void> stopSharing(String roomId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry _entry(BeaconInfo info) => ChatEntry(
  id: info.eventId,
  sender: info.sender,
  body: 'Live location',
  time: info.start,
  mine: info.sender == _me,
  kind: EntryKind.liveLocation,
  eventType: info.type,
  stateKey: info.stateKey,
  senderName: info.sender == _me ? 'Sam' : 'Alice',
  content: {
    ...beaconInfoStartContent(timeout: info.timeout, now: info.start),
    'live': info.live,
  },
);

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

    _Backend backend() {
      final b = _Backend();
      final mine = _info(r'$mine', _me, const Duration(minutes: 5));
      final alice = _info(r'$alice', _alice, const Duration(minutes: 20));
      final waiting = _info(r'$wait', _alice, const Duration(minutes: 1));
      final ended = _info(r'$ended', _alice, const Duration(hours: 3));
      b.snapshots
        ..[mine.eventId] = _snap(mine, 'Sam')
        ..[alice.eventId] = _snap(alice, 'Alice')
        ..[waiting.eventId] = _snap(waiting, 'Alice', located: false)
        ..[ended.eventId] = _snap(ended, 'Alice');
      b.live = [b.snapshots[mine.eventId]!, b.snapshots[alice.eventId]!];
      b.device = OwnShare(
        roomId: _room,
        status: OwnShareStatus.active,
        beaconInfoId: mine.eventId,
        start: mine.start,
        expiresAt: mine.expiresAt,
      );
      return b;
    }

    testWidgets('timeline ${style.name}', skip: skip != null, (tester) async {
      final b = backend();
      final entries = [
        _entry(b.snapshots[r'$ended']!.info),
        _entry(_info(r'$stop', _alice, const Duration(hours: 2), live: false)),
        _entry(b.snapshots[r'$mine']!.info),
        _entry(b.snapshots[r'$wait']!.info),
      ];
      await _shoot(
        tester,
        'live_location_timeline_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: Builder(
                builder: (context) => ListView(
                  padding: const EdgeInsets.fromLTRB(0, 40, 0, 12),
                  children: [
                    ...liveLocationRoomBanners(
                      context,
                      RoomHookContext(backend: b, roomId: _room, palette: p),
                    ),
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: MessageBubble(
                          entry: entry,
                          backend: b,
                          roomId: _room,
                          palette: p,
                          group: false,
                          onHeart: () {},
                          onAction: () {},
                          onReaction: (_) {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });

    testWidgets('map ${style.name}', skip: skip != null, (tester) async {
      final b = backend();
      await _shoot(
        tester,
        'live_location_map_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: LiveLocationMapScreen(
            features: b,
            backend: b,
            palette: p,
            roomId: _room,
          ),
        ),
      );
    });

    testWidgets('duration ${style.name}', skip: skip != null, (tester) async {
      await _shoot(
        tester,
        'live_location_duration_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showLiveLocationDurationSheet(context, p),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            tester.renderObject(find.byType(RepaintBoundary).first)
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$_dir/live_location_duration_${style.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      });
    });
  }
}
