import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/gallery_bubble.dart';
import 'package:parallax/reaction_summary.dart';
import 'package:parallax/timeline/bubble_column.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, room;
import 'widget_test.dart' show FakeBackend;

const _screen = Size(400, 800);
const _roomId = '!room:matrix.example';

/// The outer gallery bubble (the padded, rounded Container).
final _galleryBox = find.byWidgetPredicate(
  (widget) => widget is Container && widget.padding == const EdgeInsets.all(10),
);

ChatEntry _entry(
  String id, {
  required bool mine,
  bool isImage = false,
  String body = 'Hello',
}) => ChatEntry(
  id: id,
  sender: mine ? '@me:example.org' : '@bo:example.org',
  senderName: mine ? 'Me' : 'Bo',
  body: body,
  time: DateTime(2026, 11, 14, 16, 7),
  mine: mine,
  isImage: isImage,
);

void main() {
  group('gallery alignment', () {
    Future<void> pumpTimeline(
      WidgetTester tester,
      List<Widget> children,
    ) async {
      tester.view
        ..physicalSize = _screen
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(padding: EdgeInsets.zero, children: children),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('incoming gallery lines up with incoming text bubbles', (
      tester,
    ) async {
      final backend = FakeBackend()..currentUserId = '@me:example.org';
      final palette = paletteFor(VisualTheme.parallax);
      final text = _entry(r'$text', mine: false);
      final photos = [
        _entry(r'$a', mine: false, isImage: true, body: ''),
        _entry(r'$b', mine: false, isImage: true, body: ''),
      ];
      await pumpTimeline(tester, [
        MessageBubble(
          entry: text,
          backend: backend,
          roomId: _roomId,
          palette: palette,
          group: false,
          onHeart: () {},
          onAction: () {},
          onReaction: (_) {},
        ),
        GalleryBubble(
          entries: photos,
          backend: backend,
          roomId: _roomId,
          palette: palette,
          onHeart: (_) {},
          onAction: (_) {},
          onReaction: (_, _) {},
          showSender: true,
        ),
      ]);
      final textRect = tester.getRect(
        find
            .ancestor(
              of: find.byType(BubbleColumn),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final galleryRect = tester.getRect(_galleryBox);
      // Both reserve the same avatar column, so their left edges match.
      expect(galleryRect.left, closeTo(textRect.left, 0.01));
      expect(galleryRect.left, closeTo(senderAvatarSize + 8, 0.01));
    });

    testWidgets('outgoing gallery stays within the own-message width cap', (
      tester,
    ) async {
      final backend = FakeBackend()..currentUserId = '@me:example.org';
      final palette = paletteFor(VisualTheme.parallax);
      final photos = [
        _entry(r'$a', mine: true, isImage: true, body: ''),
        _entry(r'$b', mine: true, isImage: true, body: ''),
      ];
      await pumpTimeline(tester, [
        GalleryBubble(
          entries: photos,
          backend: backend,
          roomId: _roomId,
          palette: palette,
          onHeart: (_) {},
          onAction: (_) {},
          onReaction: (_, _) {},
        ),
      ]);
      final rect = tester.getRect(_galleryBox);
      final max = bubbleMaxWidth(_screen.width, mine: true, avatars: false);
      expect(rect.right, closeTo(_screen.width, 0.01));
      expect(rect.width, lessThanOrEqualTo(max));
    });
  });

  testWidgets('photo gallery lives in the composer + menu, not the timeline', (
    tester,
  ) async {
    final backend = FeaturesBackend();
    final drafts = Drafts();
    await tester.pumpWidget(room(backend, drafts));
    await tester.pumpAndSettle();
    expect(find.text('Send a photo gallery'), findsNothing);
    await tester.tap(find.byTooltip('Attach media'));
    await tester.pumpAndSettle();
    expect(find.text('Photo gallery'), findsOneWidget);
    expect(find.text('Photo or video'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  group('reactionEventsFor', () {
    matrix.Client client() {
      final c = matrix.Client(
        'reaction-events-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      c.homeserver = Uri.parse('https://matrix.example');
      c.accessToken = 'test-token';
      c.onLoginStateChanged.add(matrix.LoginState.loggedIn);
      return c;
    }

    matrix.Event event(
      matrix.Room room,
      String id, {
      String type = matrix.EventTypes.Message,
      Map<String, Object?> content = const {'msgtype': 'm.text', 'body': 'hi'},
      String sender = '@me:matrix.example',
    }) => matrix.Event(
      room: room,
      eventId: id,
      senderId: sender,
      type: type,
      content: content,
      originServerTs: DateTime(2026, 11, 14, 16, 7),
    );

    test('finds an own reaction that the aggregation has not indexed yet', () {
      final c = client();
      addTearDown(c.dispose);
      final room = matrix.Room(
        id: _roomId,
        client: c,
        membership: matrix.Membership.join,
      );
      final target = event(room, r'$target');
      final reaction = event(
        room,
        r'$reaction',
        type: matrix.EventTypes.Reaction,
        content: {
          'm.relates_to': {
            'rel_type': matrix.RelationshipTypes.reaction,
            'event_id': r'$target',
            'key': '👍',
          },
        },
      );
      final timeline = matrix.Timeline(
        room: room,
        chunk: TimelineChunk(events: [target]),
      );
      addTearDown(timeline.cancelSubscriptions);
      // Simulate a just-sent reaction present in the timeline but not yet
      // aggregated (fragmented timeline / sync lag).
      timeline.events.add(reaction);
      expect(timeline.aggregatedEvents[r'$target'], isNull);
      final found = reactionEventsFor(timeline, r'$target').toList();
      expect(found, contains(reaction));
    });

    test('deduplicates aggregation and timeline copies of one reaction', () {
      final c = client();
      addTearDown(c.dispose);
      final room = matrix.Room(
        id: _roomId,
        client: c,
        membership: matrix.Membership.join,
      );
      final target = event(room, r'$target');
      final reaction = event(
        room,
        r'$reaction',
        type: matrix.EventTypes.Reaction,
        content: {
          'm.relates_to': {
            'rel_type': matrix.RelationshipTypes.reaction,
            'event_id': r'$target',
            'key': '👍',
          },
        },
      );
      final timeline = matrix.Timeline(
        room: room,
        chunk: TimelineChunk(events: [target, reaction]),
      );
      addTearDown(timeline.cancelSubscriptions);
      // The constructor aggregates the reaction; it is also in events.
      expect(
        timeline.aggregatedEvents[r'$target']?[matrix
            .RelationshipTypes
            .reaction],
        isNotNull,
      );
      final found = reactionEventsFor(timeline, r'$target').toList();
      expect(found, hasLength(1));
      expect(found.single, reaction);
    });
  });
}

class _Database extends Fake implements matrix.DatabaseApi {
  @override
  Future<void> close() async {}
}
