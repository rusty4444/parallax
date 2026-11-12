import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/live_location/live_location_features.dart';
import 'package:parallax/features/live_location/live_location_format.dart';
import 'package:parallax/features/live_location/live_location_hooks.dart';
import 'package:parallax/features/live_location/live_location_model.dart';
import 'package:parallax/features/live_location/live_location_sharer.dart';
import 'package:parallax/features/live_location/live_location_view.dart';
import 'package:parallax/features/live_location/position_source.dart';
import 'package:parallax/features/polls/location_map.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/hooks/hook_types.dart';

import 'live_location_fakes.dart';

const _me = '@me:example.org';
const _alice = '@alice:example.org';
const _bob = '@bob:example.org';
const _roomId = '!room:example.org';
final _palette = paletteFor(VisualTheme.parallax);

BeaconInfo _info(
  String id,
  String sender, {
  Duration ago = const Duration(minutes: 5),
  Duration timeout = const Duration(hours: 1),
  bool live = true,
}) {
  final start = DateTime.now().toUtc().subtract(ago);
  return BeaconInfo(
    eventId: id,
    type: beaconInfoUnstableType,
    stateKey: sender,
    sender: sender,
    live: live,
    start: start,
    timeout: timeout,
    sentAt: start,
  );
}

LiveShareSnapshot _snapshot(
  BeaconInfo info, {
  String? name,
  bool? live,
  bool located = true,
}) => LiveShareSnapshot(
  info: info,
  live: live ?? info.isLiveAt(DateTime.now()),
  displayName: name ?? info.sender,
  mine: info.sender == _me,
  latest: located
      ? BeaconLocation(
          eventId: '\$beacon-${info.eventId}',
          sender: info.sender,
          beaconInfoId: info.eventId,
          point: const GeoPoint(-33.8688, 151.2093),
          timestamp: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
        )
      : null,
);

class _Backend extends ChatBackend
    implements LiveLocationFeatures, LiveLocationLifecycle {
  final notifier = ValueNotifier<int>(0);
  final snapshots = <String, LiveShareSnapshot>{};
  List<LiveShareSnapshot> live = const [];
  OwnShare? device;
  bool canShare = true;
  final fakePositions = FakePositions();
  final starts = <({String roomId, Duration duration})>[];
  final stops = <String>[];
  final loads = <String>[];
  int resumes = 0;
  int stopAlls = 0;
  SessionStatus status = SessionStatus.ready;
  String? user = _me;

  void changed() => notifier.value++;

  @override
  SessionStatus get connection => status;
  @override
  String? get userId => user;

  @override
  Listenable get updates => notifier;
  @override
  String? get myUserId => user;
  @override
  LivePositionSource get positions => fakePositions;
  @override
  List<LiveShareSnapshot> liveShares(String roomId) => live;
  @override
  LiveShareSnapshot shareSnapshot(String roomId, BeaconInfo info) =>
      snapshots[info.eventId] ??
      LiveShareSnapshot(
        info: info,
        live: info.isLiveAt(DateTime.now()),
        displayName: info.sender,
        mine: info.sender == _me,
      );
  @override
  void ensureBeaconsLoaded(String roomId, BeaconInfo info) =>
      loads.add(info.eventId);
  @override
  OwnShare? deviceShare(String roomId) => device;
  @override
  bool canShareIn(String roomId) => canShare;
  @override
  Future<void> startSharing(String roomId, Duration duration) async =>
      starts.add((roomId: roomId, duration: duration));
  @override
  Future<void> stopSharing(String roomId) async => stops.add(roomId);
  @override
  Future<void> resumeShares() async => resumes++;
  @override
  Future<void> stopAllShares() async => stopAlls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry _entry(BeaconInfo info, {Map<String, Object?>? content}) => ChatEntry(
  id: info.eventId,
  sender: info.sender,
  body: 'Live location',
  time: info.start,
  mine: info.sender == _me,
  kind: EntryKind.liveLocation,
  eventType: info.type,
  stateKey: info.stateKey,
  content:
      content ??
      {
        ...beaconInfoStartContent(timeout: info.timeout, now: info.start),
        'live': info.live,
      },
);

EntryHookContext _hook(_Backend backend, ChatEntry entry) => EntryHookContext(
  backend: backend,
  roomId: _roomId,
  palette: _palette,
  entry: entry,
);

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUp(() => locationMapTilesEnabled = false);
  tearDown(() => locationMapTilesEnabled = true);

  group('timeline body', () {
    testWidgets('own live share: map preview, end time, Stop', (tester) async {
      final backend = _Backend();
      final info = _info(r'$mine', _me);
      backend.snapshots[info.eventId] = _snapshot(info, name: 'Me');
      final entry = _entry(info);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                liveLocationEntryBody(context, _hook(backend, entry))!,
          ),
        ),
      );
      final ends = formatEndTime(info.expiresAt, DateTime.now());
      expect(find.text('Live location · ends $ends'), findsOneWidget);
      expect(find.text('Updated 2 min ago'), findsOneWidget);
      expect(find.byType(LiveSharerMarker), findsOneWidget);
      expect(find.text(osmAttribution), findsOneWidget);
      expect(backend.loads, [r'$mine']);

      await tester.tap(find.byTooltip('Stop sharing'));
      await tester.pump();
      expect(backend.stops, [_roomId]);
    });

    testWidgets('someone else’s ended share: no Stop', (tester) async {
      final backend = _Backend();
      final info = _info(
        r'$alice',
        _alice,
        ago: const Duration(hours: 2),
        timeout: const Duration(hours: 1),
      );
      backend.snapshots[info.eventId] = _snapshot(info, name: 'Alice');
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                liveLocationEntryBody(context, _hook(backend, _entry(info)))!,
          ),
        ),
      );
      expect(find.text('Live location ended'), findsOneWidget);
      expect(find.byTooltip('Stop sharing'), findsNothing);
    });

    testWidgets('live without a beacon yet waits', (tester) async {
      final backend = _Backend();
      final info = _info(r'$bob', _bob);
      backend.snapshots[info.eventId] = _snapshot(info, located: false);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                liveLocationEntryBody(context, _hook(backend, _entry(info)))!,
          ),
        ),
      );
      expect(find.text('Waiting for live location…'), findsOneWidget);
      expect(find.byType(LiveSharerMarker), findsNothing);
    });

    testWidgets('the event that stopped a share is a compact line', (
      tester,
    ) async {
      final backend = _Backend();
      final info = _info(r'$stop', _alice, live: false);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                liveLocationEntryBody(context, _hook(backend, _entry(info)))!,
          ),
        ),
      );
      expect(find.byType(LiveLocationEndedLine), findsOneWidget);
      expect(find.text('Live location ended'), findsOneWidget);
      expect(backend.loads, isEmpty);
    });

    testWidgets('other kinds and malformed beacon_info get no body', (
      tester,
    ) async {
      final backend = _Backend();
      final info = _info(r'$x', _alice);
      late BuildContext ctx;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      final text = ChatEntry(
        id: r'$t',
        sender: _alice,
        body: 'hi',
        time: DateTime(2026),
        mine: false,
      );
      expect(liveLocationEntryBody(ctx, _hook(backend, text)), isNull);
      final malformed = _entry(info, content: {'live': true});
      expect(liveLocationEntryBody(ctx, _hook(backend, malformed)), isNull);
      final spoofed = ChatEntry(
        id: r'$s',
        sender: _bob,
        body: '',
        time: DateTime(2026),
        mine: false,
        kind: EntryKind.liveLocation,
        eventType: beaconInfoUnstableType,
        stateKey: _alice,
        content: beaconInfoStartContent(
          timeout: const Duration(hours: 1),
          now: DateTime.now(),
        ),
      );
      expect(liveLocationEntryBody(ctx, _hook(backend, spoofed)), isNull);
    });

    testWidgets('tapping the preview opens the live map', (tester) async {
      final backend = _Backend();
      final info = _info(r'$alice', _alice);
      final snapshot = _snapshot(info, name: 'Alice');
      backend.snapshots[info.eventId] = snapshot;
      backend.live = [snapshot];
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                liveLocationEntryBody(context, _hook(backend, _entry(info)))!,
          ),
        ),
      );
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.byType(LiveLocationMapScreen), findsOneWidget);
      expect(find.text('On the map'.toUpperCase()), findsOneWidget);
      expect(find.text('1 person'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.byTooltip('Open in maps'), findsOneWidget);
    });
  });

  group('room banner', () {
    Widget banner(_Backend backend) => _app(
      Builder(
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: liveLocationRoomBanners(
            context,
            RoomHookContext(
              backend: backend,
              roomId: _roomId,
              palette: _palette,
            ),
          ),
        ),
      ),
    );

    testWidgets('own share: “You’re sharing your live location” · Stop', (
      tester,
    ) async {
      final backend = _Backend();
      final info = _info(r'$mine', _me);
      backend.live = [
        _snapshot(info, name: 'Me'),
        _snapshot(_info(r'$alice', _alice), name: 'Alice'),
      ];
      backend.device = OwnShare(
        roomId: _roomId,
        status: OwnShareStatus.active,
        beaconInfoId: info.eventId,
        start: info.start,
        expiresAt: info.expiresAt,
      );
      await tester.pumpWidget(banner(backend));
      expect(find.text('You’re sharing your live location'), findsOneWidget);
      final ends = formatEndTime(info.expiresAt, DateTime.now());
      expect(find.text('Ends $ends · 1 other person sharing'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pump();
      expect(backend.stops, [_roomId]);
    });

    testWidgets('a share from another device can be stopped here', (
      tester,
    ) async {
      final backend = _Backend();
      backend.live = [_snapshot(_info(r'$mine', _me), name: 'Me')];
      await tester.pumpWidget(banner(backend));
      expect(find.text('Shared from another device'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('starting and retrying states', (tester) async {
      final backend = _Backend();
      final now = DateTime.now();
      backend.device = OwnShare(
        roomId: _roomId,
        status: OwnShareStatus.starting,
        start: now,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      await tester.pumpWidget(banner(backend));
      expect(find.text('Starting live location…'), findsOneWidget);
      backend.device = OwnShare(
        roomId: _roomId,
        status: OwnShareStatus.active,
        beaconInfoId: r'$x',
        start: now,
        expiresAt: now.add(const Duration(hours: 1)),
        retrying: true,
      );
      backend.changed();
      await tester.pump();
      expect(
        find.text('Couldn’t send your location. Retrying…'),
        findsOneWidget,
      );
    });

    testWidgets('others only: “2 people are sharing live location” → map', (
      tester,
    ) async {
      final backend = _Backend();
      backend.live = [
        _snapshot(_info(r'$alice', _alice), name: 'Alice'),
        _snapshot(_info(r'$bob', _bob), name: 'Bob'),
      ];
      await tester.pumpWidget(banner(backend));
      expect(find.text('2 people are sharing live location'), findsOneWidget);
      expect(find.text('Alice and Bob'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      await tester.tap(find.text('2 people are sharing live location'));
      await tester.pumpAndSettle();
      expect(find.text('2 people'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
    });

    testWidgets('nobody sharing: no banner', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(banner(backend));
      expect(find.byKey(const ValueKey('live-location-banner')), findsNothing);
    });

    testWidgets('the banner updates when shares change', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(banner(backend));
      backend.live = [_snapshot(_info(r'$alice', _alice), name: 'Alice')];
      backend.changed();
      await tester.pump();
      expect(find.text('1 person is sharing live location'), findsOneWidget);
    });
  });

  group('live map screen', () {
    testWidgets('lists sharers with Stop for own share; empty state', (
      tester,
    ) async {
      final backend = _Backend();
      backend.live = [
        _snapshot(_info(r'$mine', _me), name: 'Me'),
        _snapshot(_info(r'$alice', _alice), name: 'Alice', located: false),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: LiveLocationMapScreen(
            features: backend,
            backend: backend,
            palette: _palette,
            roomId: _roomId,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Me (you)'), findsOneWidget);
      expect(find.text('Waiting for live location…'), findsOneWidget);
      expect(find.byType(LiveSharerMarker), findsOneWidget);
      expect(find.byTooltip('Open in maps'), findsOneWidget);
      await tester.tap(find.byTooltip('Stop sharing'));
      await tester.pump();
      expect(backend.stops, [_roomId]);

      backend.live = const [];
      backend.changed();
      await tester.pump();
      expect(find.text('Nobody is sharing their location'), findsOneWidget);
    });

    testWidgets('a focused share that ended is still shown', (tester) async {
      final backend = _Backend();
      final ended = _info(
        r'$old',
        _alice,
        ago: const Duration(hours: 3),
        timeout: const Duration(hours: 1),
      );
      backend.snapshots[ended.eventId] = _snapshot(ended, name: 'Alice');
      await tester.pumpWidget(
        MaterialApp(
          home: LiveLocationMapScreen(
            features: backend,
            backend: backend,
            palette: _palette,
            roomId: _roomId,
            focus: ended,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Live location ended'), findsOneWidget);
      expect(find.text('Nobody is sharing their location'), findsOneWidget);
    });
  });

  group('start flow (composer attachment)', () {
    Future<void> openAttachment(WidgetTester tester, _Backend backend) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final actions = liveLocationComposerAttachments(
                  context,
                  RoomHookContext(
                    backend: backend,
                    roomId: _roomId,
                    palette: _palette,
                  ),
                );
                return TextButton(
                  onPressed: () =>
                      unawaited(actions.single.onSelected(context)),
                  child: Text(actions.single.label),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Share live location'));
      await tester.pumpAndSettle();
    }

    Future<void> chooseDuration(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Share live location'),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers the duration, then asks for permission, then starts', (
      tester,
    ) async {
      final backend = _Backend();
      await openAttachment(tester, backend);
      expect(backend.fakePositions.requests, 0, reason: 'not before choosing');
      expect(
        find.text('Choose how long to share your live location.'),
        findsOneWidget,
      );
      expect(find.text('15 minutes'), findsOneWidget);
      expect(find.text('8 hours'), findsOneWidget);
      expect(
        find.textContaining('visible to members after the session ends'),
        findsOneWidget,
      );
      await chooseDuration(tester, '1 hour');
      expect(backend.fakePositions.requests, 1);
      expect(backend.starts.single.duration, const Duration(hours: 1));
      expect(backend.starts.single.roomId, _roomId);
    });

    testWidgets('explains a permanently denied permission', (tester) async {
      final backend = _Backend();
      backend.fakePositions.access = LocationAccess.deniedForever;
      await openAttachment(tester, backend);
      await chooseDuration(tester, '15 minutes');
      expect(
        find.textContaining('does not have permission to access your location'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(backend.fakePositions.settingsOpened, 1);
      expect(backend.starts, isEmpty);
    });

    testWidgets('explains disabled location services', (tester) async {
      final backend = _Backend();
      backend.fakePositions.access = LocationAccess.serviceDisabled;
      await openAttachment(tester, backend);
      await chooseDuration(tester, '8 hours');
      expect(find.textContaining('Please enable your GPS'), findsOneWidget);
      expect(backend.starts, isEmpty);
    });

    testWidgets('rooms without permission say so before prompting', (
      tester,
    ) async {
      final backend = _Backend()..canShare = false;
      await openAttachment(tester, backend);
      expect(
        find.text(
          'You do not have permissions to share your live location in this '
          'room',
        ),
        findsOneWidget,
      );
      expect(backend.fakePositions.requests, 0);
      expect(find.text('15 minutes'), findsNothing);
    });

    testWidgets('dismissing the duration sheet starts nothing', (tester) async {
      final backend = _Backend();
      await openAttachment(tester, backend);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('15 minutes'), findsNothing);
      expect(backend.fakePositions.requests, 0);
      expect(backend.starts, isEmpty);
    });

    testWidgets('no attachment in invited rooms', (tester) async {
      final backend = _Backend();
      late List<ComposerAttachmentAction> actions;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              actions = liveLocationComposerAttachments(
                context,
                RoomHookContext(
                  backend: backend,
                  roomId: _roomId,
                  palette: _palette,
                  room: ChatRoom(
                    id: _roomId,
                    name: 'Room',
                    preview: '',
                    lastActivity: null,
                    invited: true,
                  ),
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(actions, isEmpty);
    });
  });

  group('signed-in wrapper', () {
    testWidgets('resumes once per session and stops on sign-out', (
      tester,
    ) async {
      final backend = _Backend();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => wrapWithLiveLocation(
              context,
              AppHookContext(
                backend: backend,
                palette: _palette,
                navigatorKey: navigatorKey,
              ),
              const Text('app'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('app'), findsOneWidget);
      expect(backend.resumes, 1);
      backend.notifyListeners();
      await tester.pump();
      expect(backend.resumes, 1);

      backend.status = SessionStatus.signedOut;
      backend.notifyListeners();
      await tester.pump();
      expect(backend.stopAlls, 1);

      backend.status = SessionStatus.ready;
      backend.user = '@other:example.org';
      backend.notifyListeners();
      await tester.pump();
      expect(backend.resumes, 2);
    });

    test('liveLocationBeforeLogout ends every share', () async {
      final backend = _Backend();
      await liveLocationBeforeLogout(backend);
      expect(backend.stopAlls, 1);
    });
  });
}
