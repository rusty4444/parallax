import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show LocationPermission;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/polls/create_poll_screen.dart';
import 'package:parallax/features/polls/location_map.dart';
import 'package:parallax/features/polls/location_model.dart';
import 'package:parallax/features/polls/location_view.dart';
import 'package:parallax/features/polls/poll_features.dart';
import 'package:parallax/features/polls/poll_history_screen.dart';
import 'package:parallax/features/polls/poll_hooks.dart';
import 'package:parallax/features/polls/poll_model.dart';
import 'package:parallax/features/polls/poll_view.dart';
import 'package:parallax/features/polls/share_location_screen.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/widgets.dart';

const _me = '@me:example.org';
const _roomId = '!room:example.org';
final _palette = paletteFor(VisualTheme.parallax);

const _poll = PollStart(
  question: 'Where should we eat?',
  answers: [
    PollAnswer(id: 'a', text: 'Pizza'),
    PollAnswer(id: 'b', text: 'Sushi'),
  ],
);

const _hiddenPoll = PollStart(
  question: 'Secret ballot',
  answers: [
    PollAnswer(id: 'a', text: 'Yes'),
    PollAnswer(id: 'b', text: 'No'),
  ],
  disclosed: false,
);

PollRelation _vote(String sender, String answer, {int ts = 1}) => PollRelation(
  eventId: '\$vote-$sender-$ts',
  kind: PollRelationKind.response,
  sender: sender,
  timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
  answers: [answer],
);

PollRelation _end(String sender, {int ts = 10}) => PollRelation(
  eventId: '\$end-$sender',
  kind: PollRelationKind.end,
  sender: sender,
  timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
);

ChatEntry _pollEntry({
  String id = r'$poll',
  String sender = '@alice:example.org',
  PollStart poll = _poll,
  DateTime? time,
}) => ChatEntry(
  id: id,
  sender: sender,
  body: poll.fallbackText,
  time: time ?? DateTime(2026, 11, 10, 9),
  mine: sender == _me,
  kind: EntryKind.poll,
  eventType: pollStartType,
  content: poll.toStartContent(),
);

class _Backend extends ChatBackend implements PollFeatures, LocationFeatures {
  final pollNotifier = ValueNotifier<int>(0);
  final snapshots = <String, PollSnapshot>{};
  final loads = <String>[];
  final moderators = <String>{};
  final created = <PollStart>[];
  final edits = <({String pollId, PollStart poll})>[];
  final votes = <({String pollId, List<String> answers})>[];
  final ends = <String>[];
  final deletes = <String>[];
  final locations = <({GeoPoint point, LocationAsset asset})>[];
  Completer<void>? voteGate;
  List<ChatEntry> entries = const [];
  bool olderAvailable = false;
  int olderLoads = 0;
  String? active = _roomId;

  void setRelations(String pollId, List<PollRelation> relations) {
    snapshots[pollId] = PollSnapshot(
      state: PollLoadState.ready,
      relations: relations,
    );
    pollNotifier.value++;
  }

  @override
  String? get userId => _me;
  @override
  String? get activeRoomId => active;
  @override
  List<ChatEntry> get messages => entries;
  @override
  List<ChatRoom> get rooms => const [];
  @override
  bool get canLoadOlder => olderAvailable;
  @override
  bool get loadingHistory => false;
  @override
  Future<void> loadOlder(String roomId) async => olderLoads++;

  @override
  Listenable get pollUpdates => pollNotifier;
  @override
  PollSnapshot? pollSnapshot(String roomId, String pollId) => snapshots[pollId];
  @override
  void ensurePollLoaded(String roomId, String pollId, {bool retry = false}) =>
      loads.add(pollId);
  @override
  bool mayEndPoll(String roomId, String userId, String pollSenderId) =>
      userId == pollSenderId || moderators.contains(userId);
  @override
  Future<String> createPoll(String roomId, PollStart poll) async {
    created.add(poll);
    return r'$new';
  }

  @override
  Future<String> editPoll(String roomId, String pollId, PollStart poll) async {
    edits.add((pollId: pollId, poll: poll));
    return r'$edit';
  }

  @override
  Future<String> respondToPoll(
    String roomId,
    String pollId,
    List<String> answerIds,
  ) async {
    votes.add((pollId: pollId, answers: answerIds));
    await voteGate?.future;
    return r'$vote';
  }

  @override
  Future<String> endPoll(String roomId, String pollId) async {
    ends.add(pollId);
    return r'$end';
  }

  @override
  Future<void> deletePoll(String roomId, String pollId) async =>
      deletes.add(pollId);

  @override
  Future<String> shareLocation(
    String roomId,
    GeoPoint point, {
    required LocationAsset asset,
    String? description,
  }) async {
    locations.add((point: point, asset: asset));
    return r'$loc';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Locator implements DeviceLocator {
  GeoPoint? permitted;
  Object? result = const GeoPoint(-33.8568, 151.2153, uncertainty: 8);
  int locates = 0;
  int appSettings = 0;
  int locationSettings = 0;

  @override
  Future<GeoPoint?> currentIfPermitted() async => permitted;

  @override
  Future<GeoPoint> locate() async {
    locates++;
    final value = result;
    if (value is GeoPoint) return value;
    throw value!;
  }

  @override
  Future<void> openAppSettings() async => appSettings++;
  @override
  Future<void> openLocationSettings() async => locationSettings++;
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

PollBody _body(_Backend backend, {ChatEntry? entry}) {
  final e = entry ?? _pollEntry();
  return PollBody(
    features: backend,
    palette: _palette,
    roomId: _roomId,
    pollId: e.id,
    pollSender: e.sender,
    content: e.content,
    myUserId: _me,
    foreground: _palette.foreground,
  );
}

EntryHookContext _entryCtx(_Backend backend, ChatEntry entry) =>
    EntryHookContext(
      backend: backend,
      roomId: _roomId,
      palette: _palette,
      entry: entry,
    );

void main() {
  setUp(() => locationMapTilesEnabled = false);
  tearDown(() {
    locationMapTilesEnabled = true;
    debugLocationUrlOpener = null;
  });

  group('PollBody', () {
    testWidgets('disclosed poll shows live tallies and sends a vote', (
      tester,
    ) async {
      final backend = _Backend()
        ..setRelations(r'$poll', [_vote('@a:x', 'a'), _vote('@b:x', 'a')]);
      await tester.pumpWidget(_app(_body(backend)));

      expect(backend.loads, contains(r'$poll'));
      expect(find.text('Where should we eat?'), findsOneWidget);
      expect(find.text('2 votes'), findsOneWidget);
      expect(find.text('0 votes'), findsOneWidget);
      expect(find.text('Total votes: 2'), findsOneWidget);
      expect(find.text('Edit poll'), findsNothing, reason: 'not the creator');

      backend.voteGate = Completer<void>();
      await tester.tap(find.text('Sushi'));
      await tester.pump();
      expect(backend.votes.single.answers, ['b']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.byIcon(Icons.radio_button_checked_rounded),
        findsOneWidget,
        reason: 'optimistic selection while sending',
      );
      backend.voteGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('undisclosed results appear only after the poll ends', (
      tester,
    ) async {
      final backend = _Backend()
        ..setRelations(r'$poll', [_vote('@a:x', 'a'), _vote(_me, 'b')]);
      await tester.pumpWidget(
        _app(_body(backend, entry: _pollEntry(poll: _hiddenPoll))),
      );
      expect(
        find.text('Results will show after the poll has ended'),
        findsOneWidget,
      );
      expect(find.textContaining('vote'), findsNothing);
      expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);

      backend.setRelations(r'$poll', [
        _vote('@a:x', 'a'),
        _vote('@c:x', 'a'),
        _vote(_me, 'b'),
        _end('@alice:example.org'),
      ]);
      await tester.pump();
      expect(find.text('Final results based on 3 votes'), findsOneWidget);
      expect(find.byIcon(Icons.emoji_events_rounded), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('This is the winning answer')),
        findsOneWidget,
      );

      await tester.tap(find.text('No'));
      await tester.pump();
      expect(backend.votes, isEmpty, reason: 'ended polls are read-only');
    });

    testWidgets('multi-select toggles within max selections', (tester) async {
      const poll = PollStart(
        question: 'Pick',
        answers: [
          PollAnswer(id: 'a', text: 'A'),
          PollAnswer(id: 'b', text: 'B'),
          PollAnswer(id: 'c', text: 'C'),
        ],
        maxSelections: 2,
      );
      final backend = _Backend()
        ..setRelations(r'$poll', [
          PollRelation(
            eventId: r'$mine',
            kind: PollRelationKind.response,
            sender: _me,
            timestamp: DateTime(2026),
            answers: const ['a', 'b'],
          ),
        ]);
      await tester.pumpWidget(
        _app(_body(backend, entry: _pollEntry(poll: poll))),
      );
      expect(find.text('Choose up to 2 options'), findsOneWidget);
      await tester.tap(find.text('C'));
      await tester.pump();
      expect(backend.votes, isEmpty, reason: 'would exceed max selections');
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(backend.votes.single.answers, ['b']);
    });

    testWidgets('creator can edit before votes and end afterwards', (
      tester,
    ) async {
      final backend = _Backend()..setRelations(r'$poll', const []);
      final entry = _pollEntry(sender: _me);
      await tester.pumpWidget(_app(_body(backend, entry: entry)));
      expect(find.text('Edit poll'), findsOneWidget);
      await tester.tap(find.text('Edit poll'));
      await tester.pumpAndSettle();
      expect(find.byType(CreatePollScreen), findsOneWidget);
      expect(find.text('Where should we eat?'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      backend.setRelations(r'$poll', [_vote('@a:x', 'a')]);
      await tester.pump();
      expect(find.text('Edit poll'), findsNothing);
      await tester.tap(find.text('End poll'));
      await tester.pumpAndSettle();
      expect(
        find.text('Are you sure you want to end this poll?'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'End poll'));
      await tester.pumpAndSettle();
      expect(backend.ends, [r'$poll']);
    });

    testWidgets('local echoes cannot be voted on', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(
        _app(_body(backend, entry: _pollEntry(id: 'txn-local'))),
      );
      await tester.tap(find.text('Pizza'));
      await tester.pump();
      expect(backend.votes, isEmpty);
    });
  });

  group('hooks', () {
    testWidgets('bodies claim poll and location entries only', (tester) async {
      final backend = _Backend();
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        pollEntryBody(context, _entryCtx(backend, _pollEntry())),
        isA<PollBody>(),
      );
      final text = ChatEntry(
        id: r'$t',
        sender: '@a:x',
        body: 'hi',
        time: DateTime(2026),
        mine: false,
      );
      expect(pollEntryBody(context, _entryCtx(backend, text)), isNull);
      expect(locationEntryBody(context, _entryCtx(backend, text)), isNull);
      final location = ChatEntry(
        id: r'$l',
        sender: '@a:x',
        body: 'Location',
        time: DateTime(2026),
        mine: false,
        kind: EntryKind.location,
        msgtype: 'm.location',
        content: locationContent(
          point: const GeoPoint(1, 2),
          asset: LocationAsset.pin,
          now: DateTime(2026),
        ),
      );
      expect(
        locationEntryBody(context, _entryCtx(backend, location)),
        isA<LocationBody>(),
      );
      final broken = ChatEntry(
        id: r'$b',
        sender: '@a:x',
        body: 'Location',
        time: DateTime(2026),
        mine: false,
        kind: EntryKind.location,
        content: const {'geo_uri': 'geo:999,999'},
      );
      expect(locationEntryBody(context, _entryCtx(backend, broken)), isNull);

      final attachments = pollComposerAttachments(
        context,
        RoomHookContext(backend: backend, roomId: _roomId, palette: _palette),
      );
      expect(attachments.map((a) => a.label), ['Poll', 'Share location']);
      expect(
        pollRoomDetailsSections(
          context,
          RoomHookContext(backend: backend, roomId: _roomId, palette: _palette),
        ),
        hasLength(1),
      );
    });

    testWidgets('message actions follow Element X permissions', (tester) async {
      final backend = _Backend()..setRelations(r'$poll', const []);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      List<String> ids(ChatEntry entry) => pollMessageActions(
        context,
        _entryCtx(backend, entry),
      ).map((a) => a.id).toList();

      expect(ids(_pollEntry(sender: _me)), ['poll-edit', 'poll-end']);
      backend.snapshots[r'$poll'] = const PollSnapshot(
        state: PollLoadState.loading,
      );
      expect(
        ids(_pollEntry(sender: _me)),
        ['poll-end'],
        reason: 'no editing until existing votes are known',
      );
      backend.setRelations(r'$poll', const []);
      expect(ids(_pollEntry()), isEmpty);
      backend.moderators.add(_me);
      expect(ids(_pollEntry()), ['poll-end']);
      backend.setRelations(r'$poll', [_vote('@a:x', 'a')]);
      expect(ids(_pollEntry(sender: _me)), ['poll-end']);
      backend.setRelations(r'$poll', [_end('@alice:example.org')]);
      expect(ids(_pollEntry()), isEmpty);
      expect(ids(_pollEntry(id: 'txn')), isEmpty);
    });
  });

  group('CreatePollScreen', () {
    void tallScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('creates a poll with options and settings', (tester) async {
      tallScreen(tester);
      final backend = _Backend();
      await tester.pumpWidget(
        MaterialApp(
          home: CreatePollScreen(
            palette: _palette,
            roomId: _roomId,
            features: backend,
          ),
        ),
      );
      expect(
        tester.widget<AccentButton>(find.byType(AccentButton)).onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const ValueKey('poll-question')),
        'Team lunch?',
      );
      await tester.enterText(
        find.byKey(const ValueKey('poll-answer-0')),
        'Thai',
      );
      await tester.enterText(
        find.byKey(const ValueKey('poll-answer-1')),
        'Pho',
      );
      await tester.tap(find.text('Add option'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('poll-answer-2')),
        'Burgers',
      );
      await tester.tap(find.byTooltip('Increase votes allowed per person'));
      await tester.pump();
      await tester.tap(find.text('Hide votes'));
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final poll = backend.created.single;
      expect(poll.question, 'Team lunch?');
      expect(poll.answers.map((a) => a.text), ['Thai', 'Pho', 'Burgers']);
      expect(poll.maxSelections, 2);
      expect(poll.disclosed, isFalse);
      expect(poll.answerIds, hasLength(3));
    });

    testWidgets('editing keeps answer IDs and confirms discarding', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = _Backend();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => openEditPoll(
                context,
                palette: _palette,
                roomId: _roomId,
                pollId: r'$poll',
                poll: _poll,
                features: backend,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Edit poll'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('poll-answer-1')),
        'Ramen',
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Your changes have not been saved. Are you sure you want to go back?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final edit = backend.edits.single;
      expect(edit.pollId, r'$poll');
      expect(edit.poll.answers.map((a) => a.id), ['a', 'b']);
      expect(edit.poll.answers.last.text, 'Ramen');
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('delete asks for confirmation then redacts', (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(
        MaterialApp(
          home: CreatePollScreen(
            palette: _palette,
            roomId: _roomId,
            features: backend,
            editing: (pollId: r'$poll', poll: _poll),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Delete Poll'));
      await tester.pumpAndSettle();
      expect(
        find.text('Are you sure you want to delete this poll?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(backend.deletes, [r'$poll']);
    });
  });

  group('location', () {
    testWidgets('pin is shared without asking for permission', (tester) async {
      final backend = _Backend();
      final locator = _Locator();
      await tester.pumpWidget(
        MaterialApp(
          home: ShareLocationScreen(
            palette: _palette,
            roomId: _roomId,
            features: backend,
            locator: locator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(find.text('Share selected location'), findsOneWidget);
      await tester.tap(find.text('Share selected location'));
      await tester.pumpAndSettle();
      expect(locator.locates, 0);
      expect(backend.locations.single.asset, LocationAsset.pin);
    });

    testWidgets('tapping my location requests access then shares it', (
      tester,
    ) async {
      final backend = _Backend();
      final locator = _Locator();
      await tester.pumpWidget(
        MaterialApp(
          home: ShareLocationScreen(
            palette: _palette,
            roomId: _roomId,
            features: backend,
            locator: locator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move the map to my location'));
      await tester.pumpAndSettle();
      expect(locator.locates, 1);
      await tester.tap(find.text('Share my location'));
      await tester.pumpAndSettle();
      final shared = backend.locations.single;
      expect(shared.asset, LocationAsset.self);
      expect(shared.point, locator.result);
    });

    testWidgets('denied permission offers settings; disabled GPS too', (
      tester,
    ) async {
      final backend = _Backend();
      final locator = _Locator()
        ..result = const LocatorException(LocatorFailure.deniedForever);
      await tester.pumpWidget(
        MaterialApp(
          home: ShareLocationScreen(
            palette: _palette,
            roomId: _roomId,
            features: backend,
            locator: locator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Move the map to my location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('does not have permission'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(locator.appSettings, 1);

      locator.result = const LocatorException(LocatorFailure.serviceDisabled);
      await tester.tap(find.byTooltip('Move the map to my location'));
      await tester.pumpAndSettle();
      expect(
        find.text('Please enable your GPS to access location-based features.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(locator.locationSettings, 1);

      locator.result = const LocatorException(LocatorFailure.denied);
      await tester.tap(find.byTooltip('Move the map to my location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('drop a pin'), findsOneWidget);
      expect(find.text('Share selected location'), findsOneWidget);
    });

    testWidgets('already-granted location centres without prompting', (
      tester,
    ) async {
      final locator = _Locator()..permitted = const GeoPoint(1, 2);
      await tester.pumpWidget(
        MaterialApp(
          home: ShareLocationScreen(
            palette: _palette,
            roomId: _roomId,
            features: _Backend(),
            locator: locator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(locator.locates, 0);
      expect(find.text('Share my location'), findsOneWidget);
    });

    testWidgets('timeline body opens maps and the full-screen view', (
      tester,
    ) async {
      final opened = <Uri>[];
      debugLocationUrlOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      final location = SharedLocation.fromContent(
        locationContent(
          point: const GeoPoint(-33.8568, 151.2153),
          asset: LocationAsset.self,
          now: DateTime(2026),
        ),
      )!;
      await tester.pumpWidget(
        _app(
          LocationBody(
            palette: _palette,
            location: location,
            foreground: _palette.foreground,
            senderName: 'Alice',
            sentAt: DateTime(2026, 11, 12, 10),
          ),
        ),
      );
      expect(find.text('Alice’s location'), findsOneWidget);
      await tester.tap(find.text('Open in maps'));
      await tester.pumpAndSettle();
      expect(opened.single.scheme, 'geo');
      expect(opened.single.toString(), contains('-33.856800,151.215300'));

      await tester.tap(
        find.bySemanticsLabel(RegExp('Show location on the map')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LocationViewerScreen), findsOneWidget);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    });

    testWidgets('falls back to OpenStreetMap when no maps app opens', (
      tester,
    ) async {
      final opened = <Uri>[];
      debugLocationUrlOpener = (uri) async {
        opened.add(uri);
        return uri.scheme == 'https';
      };
      expect(await openInMaps(const GeoPoint(1, 2), label: 'X'), isTrue);
      expect(opened.map((u) => u.scheme), ['geo', 'https']);
      expect(
        await openExternalLocationUrl(Uri.parse('javascript:alert(1)')),
        isFalse,
      );
    });

    test('geolocator permission enum is the one the locator maps', () {
      // Guard against plugin enum changes silently breaking the mapping.
      expect(
        LocationPermission.values,
        contains(LocationPermission.deniedForever),
      );
    });
  });

  group('PollHistoryScreen', () {
    testWidgets('filters ongoing and past polls and loads more', (
      tester,
    ) async {
      final backend = _Backend()
        ..entries = [
          _pollEntry(id: r'$old', time: DateTime(2026, 11, 1)),
          ChatEntry(
            id: r'$text',
            sender: '@a:x',
            body: 'hello',
            time: DateTime(2026, 11, 2),
            mine: false,
          ),
          _pollEntry(
            id: r'$new',
            poll: _hiddenPoll,
            time: DateTime(2026, 11, 3),
          ),
        ]
        ..olderAvailable = true
        ..setRelations(r'$old', [_end('@alice:example.org')]);
      await tester.pumpWidget(
        MaterialApp(
          home: PollHistoryScreen(
            backend: backend,
            features: backend,
            palette: _palette,
            roomId: _roomId,
          ),
        ),
      );
      expect(find.text('Secret ballot'), findsOneWidget);
      expect(find.text('Where should we eat?'), findsNothing);
      expect(backend.loads, containsAll([r'$old', r'$new']));

      await tester.tap(find.text('Past'));
      await tester.pumpAndSettle();
      expect(find.text('Where should we eat?'), findsOneWidget);
      expect(find.text('Secret ballot'), findsNothing);

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(backend.olderLoads, 1);

      backend.entries = const [];
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Can’t find any past polls.'), findsOneWidget);

      backend.active = '!other:example.org';
      backend.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Open this room to browse its polls.'), findsOneWidget);
    });
  });
}
