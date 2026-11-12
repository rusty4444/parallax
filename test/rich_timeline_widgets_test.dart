import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rich_timeline/mention_suggestions.dart';
import 'package:parallax/features/rich_timeline/message_actions.dart';
import 'package:parallax/features/rich_timeline/rich_text_view.dart';
import 'package:parallax/features/rich_timeline/rich_timeline_features.dart';
import 'package:parallax/features/rich_timeline/rich_timeline_hooks.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:parallax/timeline/timeline_view.dart';

const me = '@me:example.org';
final palette = paletteFor(defaultVisualTheme);

class _Backend extends ChatBackend implements RichTimelineFeatures {
  final members = <String, MemberProfile>{
    '@alice:example.org': const MemberProfile(
      userId: '@alice:example.org',
      displayName: 'Alice',
    ),
    '@bob:example.org': const MemberProfile(
      userId: '@bob:example.org',
      displayName: 'Bob',
    ),
  };
  Map<String, List<ReceiptReader>> receipts = {};

  @override
  String? get userId => me;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingHistory => false;
  @override
  List<ChatRoom> get rooms => const [];
  @override
  Future<Uint8List?> loadAvatar(Uri url) async => null;

  @override
  Map<String, List<ReceiptReader>> latestReceipts(
    String roomId, {
    Set<String>? eventIds,
  }) => receipts;
  @override
  MemberProfile? member(String roomId, String userId) => members[userId];
  @override
  List<MemberProfile> searchMembers(
    String roomId,
    String query, {
    int limit = 8,
  }) => rankMembers(members.values, query, limit: limit);
  @override
  bool canMentionRoom(String roomId) => true;
  @override
  List<String> viaServers(String roomId) => const ['example.org'];
  @override
  PreviousState? cachedPreviousState(String roomId, String eventId) => null;
  @override
  Future<PreviousState?> previousState(String roomId, String eventId) async =>
      const PreviousState({'membership': 'join'});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatEntry message(
  String id, {
  String sender = '@alice:example.org',
  String body = 'hello',
  String? formatted,
  DateTime? time,
  EntryKind kind = EntryKind.text,
  bool redacted = false,
  bool highlight = false,
  bool edited = false,
  String eventType = 'm.room.message',
  Map<String, Object?> content = const {},
  String? stateKey,
}) => ChatEntry(
  id: id,
  sender: sender,
  body: body,
  formattedBody: formatted,
  time: time ?? DateTime.now(),
  mine: sender == me,
  kind: kind,
  redacted: redacted,
  highlight: highlight,
  edited: edited,
  eventType: eventType,
  content: content,
  stateKey: stateKey,
  senderName: sender == '@alice:example.org' ? 'Alice' : null,
);

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: child),
);

/// Taps the text span containing [text] inside [finder]'s RichText.
bool tapSpan(WidgetTester tester, String text) {
  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    var tapped = false;
    rich.text.visitChildren((span) {
      if (span is TextSpan &&
          span.text == text &&
          span.recognizer is TapGestureRecognizer) {
        (span.recognizer! as TapGestureRecognizer).onTap!();
        tapped = true;
        return false;
      }
      return true;
    });
    if (tapped) return true;
  }
  return false;
}

bool hasLinkSpan(String text) {
  var found = false;
  for (final element in find.byType(RichText).evaluate()) {
    (element.widget as RichText).text.visitChildren((span) {
      if (span is TextSpan && span.text == text && span.recognizer != null) {
        found = true;
      }
      return !found;
    });
  }
  return found;
}

void main() {
  group('MessageContentView', () {
    Widget view(
      ChatEntry entry, {
      List<Uri>? links,
      List<String>? permalinks,
    }) => host(
      MessageContentView(
        entry: entry,
        style: const TextStyle(fontSize: 15),
        palette: palette,
        ownUserId: me,
        resolveName: (id) => id == '@bob:example.org' ? 'Bob' : null,
        onLink: (uri, _) => links?.add(uri),
        onPermalink: (link) => permalinks?.add(link.identifier),
      ),
    );

    testWidgets('renders sanitised HTML with safe links and pills', (
      tester,
    ) async {
      final links = <Uri>[];
      final permalinks = <String>[];
      await tester.pumpWidget(
        view(
          message(
            r'$1',
            body: 'fallback',
            formatted:
                '<mx-reply><blockquote>old quoted reply</blockquote></mx-reply>'
                '<p><strong>Bold</strong> <a href="https://example.org">site</a> '
                '<a href="javascript:alert(1)">bad</a> '
                '<a href="https://matrix.to/#/@bob:example.org">Bob link</a> '
                '<a href="https://matrix.to/#/@me:example.org">me</a></p>'
                '<script>alert(2)</script><style>p{}</style>'
                '<ul><li>one</li><li>two</li></ul>'
                '<ol start="3"><li>three</li></ol>'
                '<pre><code>final x = 1;</code></pre>'
                '<blockquote>quoted</blockquote>'
                '<font data-mx-color="#ff0000">red</font>',
            content: const {},
          ),
          links: links,
          permalinks: permalinks,
        ),
      );
      expect(find.textContaining('old quoted reply'), findsNothing);
      expect(find.textContaining('alert'), findsNothing);
      expect(find.textContaining('Bold', findRichText: true), findsOneWidget);
      expect(find.text('@Bob'), findsOneWidget);
      expect(find.text('@me'), findsOneWidget);
      expect(find.text('•'), findsNWidgets(2));
      expect(find.text('3.'), findsOneWidget);
      expect(find.text('final x = 1;'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('final x = 1;'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      expect(hasLinkSpan('bad'), isFalse);
      expect(tapSpan(tester, 'site'), isTrue);
      expect(links, [Uri.parse('https://example.org')]);
      await tester.tap(find.text('@Bob'));
      expect(permalinks, ['@bob:example.org']);
    });

    testWidgets('linkifies plain bodies and pills @room', (tester) async {
      final links = <Uri>[];
      await tester.pumpWidget(
        view(
          message(r'$2', body: 'Read https://example.org/x. @room'),
          links: links,
        ),
      );
      expect(tapSpan(tester, 'https://example.org/x'), isTrue);
      expect(links.single.toString(), 'https://example.org/x');
      expect(find.text('@room'), findsOneWidget);
    });

    testWidgets('emotes, notices, undecryptable and removed messages', (
      tester,
    ) async {
      await tester.pumpWidget(
        view(message(r'$3', body: 'waves', kind: EntryKind.emote)),
      );
      expect(
        find.textContaining('* Alice waves', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpWidget(
        view(message(r'$4', body: '🔒 Unable', kind: EntryKind.undecryptable)),
      );
      expect(find.text('Waiting for this message'), findsOneWidget);
      expect(find.textContaining('Unable to decrypt'), findsOneWidget);
      await tester.pumpWidget(
        view(message(r'$5', body: 'Message removed', redacted: true)),
      );
      expect(find.text('Message removed'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
      await tester.pumpWidget(view(message(r'$6', body: '🎉🎉')));
      final big = tester.widget<Text>(find.text('🎉🎉'));
      expect(big.style!.fontSize, greaterThan(30));
    });

    testWidgets('spoilers reveal on tap', (tester) async {
      await tester.pumpWidget(
        view(
          message(
            r'$7',
            body: 'secret',
            formatted: 'A <span data-mx-spoiler>secret</span>',
          ),
        ),
      );
      TextSpan? spoiler() {
        TextSpan? found;
        for (final element in find.byType(RichText).evaluate()) {
          (element.widget as RichText).text.visitChildren((span) {
            if (span is TextSpan && span.text == 'secret') found = span;
            return found == null;
          });
        }
        return found;
      }

      expect(spoiler()!.style!.backgroundColor, isNotNull);
      expect(tapSpan(tester, 'secret'), isTrue);
      await tester.pump();
      expect(spoiler()!.style!.backgroundColor, isNull);
    });
  });

  testWidgets('misleading link text asks for confirmation', (tester) async {
    final opened = <Uri>[];
    final previous = richTimelineLaunchUrl;
    richTimelineLaunchUrl = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => richTimelineLaunchUrl = previous);
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => openTimelineLink(
              context,
              Uri.parse('https://evil.example'),
              text: 'https://bank.example',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Double-check this link'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://evil.example')]);
  });

  group('TimelineView', () {
    Widget timeline(
      _Backend backend,
      List<ChatEntry> entries, {
      ChatRoom? room,
    }) => host(
      TimelineView(
        backend: backend,
        roomId: '!room:example.org',
        palette: palette,
        entries: entries,
        compact: false,
        room: room,
        onHeart: (_) {},
        onAction: (_) {},
        onReaction: (_, _) {},
        onLoadOlder: () {},
      ),
    );

    testWidgets('a new message keeps the existing bubbles (no rebuild)', (
      tester,
    ) async {
      final backend = _Backend();
      final now = DateTime.now();
      final first = [
        message(r'$a', body: 'first', time: now),
        message(r'$b', body: 'second', time: now.add(const Duration(hours: 1))),
      ];
      await tester.pumpWidget(timeline(backend, first));
      final before = tester.element(find.byKey(const ValueKey(r'$b')));
      await tester.pumpWidget(
        timeline(backend, [
          ...first,
          message(
            r'$c',
            body: 'third',
            time: now.add(const Duration(hours: 2)),
          ),
        ]),
      );
      expect(find.text('third'), findsOneWidget);
      // Every index shifted by one; the bubble moved instead of being
      // thrown away and built again.
      expect(
        identical(tester.element(find.byKey(const ValueKey(r'$b'))), before),
        isTrue,
      );
    });

    testWidgets('a day shown twice (times going backwards) still updates', (
      tester,
    ) async {
      final backend = _Backend();
      final now = DateTime.now();
      final earlier = now.subtract(const Duration(days: 2));
      final entries = [
        message(r'$a', body: 'one', time: earlier),
        message(r'$b', body: 'two', time: now),
        message(r'$c', body: 'three', time: earlier),
      ];
      await tester.pumpWidget(timeline(backend, entries));
      await tester.pumpWidget(
        timeline(backend, [
          ...entries,
          message(r'$d', body: 'four', time: now),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('four'), findsOneWidget);
      await tester.pumpWidget(timeline(backend, entries.sublist(1)));
      expect(tester.takeException(), isNull);
      expect(find.text('one'), findsNothing);
    });

    testWidgets('day separators, sender grouping, edited and highlight', (
      tester,
    ) async {
      final backend = _Backend();
      final now = DateTime.now();
      await tester.pumpWidget(
        timeline(backend, [
          message(r'$y', time: now.subtract(const Duration(days: 1))),
          message(r'$a', body: 'first', time: now),
          message(
            r'$b',
            body: 'second',
            time: now.add(const Duration(minutes: 1)),
            edited: true,
            highlight: true,
          ),
          message(
            r'$c',
            sender: me,
            body: 'mine',
            time: now.add(const Duration(minutes: 2)),
          ),
        ]),
      );
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      // Name shown once per group (yesterday's message and today's first).
      expect(find.text('Alice'), findsNWidgets(2));
      expect(find.textContaining('(edited)'), findsOneWidget);
      // Own latest message without receipts gets the Sent tick.
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
    });

    testWidgets('direct chats hide sender names', (tester) async {
      await tester.pumpWidget(
        timeline(
          _Backend(),
          [message(r'$a')],
          room: const ChatRoom(
            id: '!room:example.org',
            name: 'Alice',
            preview: '',
            lastActivity: null,
            isDirect: true,
          ),
        ),
      );
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('room changes collapse and expand', (tester) async {
      ChatEntry change(String id, String target) => message(
        id,
        sender: target,
        body: '$target fallback',
        kind: EntryKind.state,
        eventType: 'm.room.member',
        stateKey: target,
        content: const {'membership': 'invite'},
      );
      await tester.pumpWidget(
        timeline(_Backend(), [
          change(r'$s1', '@alice:example.org'),
          change(r'$s2', '@bob:example.org'),
          message(r'$m', body: 'after'),
        ]),
      );
      expect(find.text('2 room changes'), findsOneWidget);
      expect(find.textContaining('invited'), findsNothing);
      await tester.tap(find.text('2 room changes'));
      await tester.pumpAndSettle();
      expect(find.text('Alice invited Alice'), findsOneWidget);
      expect(find.text('@bob:example.org invited Bob'), findsOneWidget);
    });

    testWidgets('read receipts row opens the receipts sheet', (tester) async {
      final backend = _Backend()
        ..receipts = {
          r'$a': const [
            ReceiptReader(userId: '@bob:example.org', name: 'Bob'),
            ReceiptReader(userId: '@carol:example.org', name: 'Carol'),
            ReceiptReader(userId: '@dan:example.org', name: 'Dan'),
            ReceiptReader(userId: '@eve:example.org', name: 'Eve'),
          ],
        };
      await tester.pumpWidget(timeline(backend, [message(r'$a')]));
      expect(find.text('+1'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Read by Bob, Carol and 2 others')),
        findsOneWidget,
      );
      await tester.tap(find.text('+1'));
      await tester.pumpAndSettle();
      expect(find.text('Read receipts'), findsOneWidget);
    });

    testWidgets('jump to bottom appears when scrolled up', (tester) async {
      final now = DateTime.now();
      final entries = [
        for (var i = 0; i < 40; i++)
          message(
            '\$m$i',
            body: 'message $i',
            time: now.add(Duration(minutes: i * 10)),
          ),
      ];
      await tester.pumpWidget(timeline(_Backend(), entries));
      expect(find.byTooltip('Jump to latest messages'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 900));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Jump to latest messages'), findsOneWidget);
      await tester.tap(find.byTooltip('Jump to latest messages'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Jump to latest messages'), findsNothing);
    });
  });

  group('message actions', () {
    testWidgets('copy text, copy link and view source', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final backend = _Backend();
      late BuildContext captured;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      final ctx = EntryHookContext(
        backend: backend,
        roomId: '!room:example.org',
        palette: palette,
        entry: message(
          r'$event',
          body: 'copy me',
          content: const {'body': 'copy me'},
        ),
      );
      final actions = richTimelineMessageActions(captured, ctx);
      expect(actions.map((a) => a.label), [
        'Copy text',
        'Copy link to message',
        'View source',
      ]);
      await actions[0].onSelected(captured);
      await actions[1].onSelected(captured);
      expect(clipboard, [
        'copy me',
        r'https://matrix.to/#/!room:example.org/$event?via=example.org',
      ]);
      await tester.pump();
      actions[2].onSelected(captured);
      await tester.pumpAndSettle();
      expect(find.text('View source'), findsOneWidget);
      expect(find.textContaining('"event_id": "\$event"'), findsOneWidget);
      expect(
        richTimelineMessageActions(
          captured,
          EntryHookContext(
            backend: backend,
            roomId: '!room:example.org',
            palette: palette,
            entry: message(r'$gone', redacted: true),
          ),
        ),
        isEmpty,
      );
    });
  });

  testWidgets('composer finds the room through the timeline on its route', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        Column(
          children: [
            Expanded(
              child: TimelineView(
                backend: _Backend(),
                roomId: '!room:example.org',
                palette: palette,
                entries: [message(r'$a', sender: me)],
                compact: false,
                onHeart: (_) {},
                onAction: (_) {},
                onReaction: (_, _) {},
                onLoadOlder: () {},
              ),
            ),
            RichMessageComposer(
              controller: controller,
              sending: false,
              onSend: (_, _) async {},
            ),
          ],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '@bo');
    await tester.pump();
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('composer offers @-mentions and inserts the user ID', (
    tester,
  ) async {
    final backend = _Backend();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        Align(
          alignment: Alignment.bottomCenter,
          child: RichMessageComposer(
            controller: controller,
            sending: false,
            onSend: (_, _) async {},
            mentionSource: roomMentionSource(
              backend: backend,
              roomId: '!room:example.org',
              palette: palette,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'hi @al');
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
    await tester.tap(find.text('Alice'));
    await tester.pump();
    expect(controller.text, 'hi @alice:example.org ');
    expect(find.text('Alice'), findsNothing);
    await tester.enterText(find.byType(TextField), '@ro');
    await tester.pump();
    expect(find.text('Everyone'), findsOneWidget);
  });
}
