import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/message_action_features.dart';
import 'package:parallax/features/reactions/reaction_hooks.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reactions_fakes.dart';
import 'package:parallax/room_avatar.dart';

const _roomId = fakeRoomId;
final _palette = paletteFor(defaultVisualTheme);

ChatEntry _entry(
  String id, {
  String sender = '@alice:matrix.example',
  String? senderName = 'Alice',
  String body = 'Hello there',
  bool mine = false,
  List<ChatReaction> reactions = const [],
  bool pinned = false,
  EntryKind? kind,
  int minute = 0,
}) => ChatEntry(
  id: id,
  sender: sender,
  senderName: senderName,
  body: body,
  time: DateTime(2026, 11, 12, 9, minute),
  mine: mine,
  reactions: reactions,
  pinned: pinned,
  kind: kind,
  content: {'msgtype': 'm.text', 'body': body},
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
  });

  group('emoji picker', () {
    testWidgets('quick row picks, persists recents and themes the sheet', (
      tester,
    ) async {
      _phone(tester);
      final picked = <String?>[];
      await tester.pumpWidget(_PickerHost(onPicked: picked.add));
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.text('ADD A REACTION'), findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-👍')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('emoji-🎉')));
      await tester.pumpAndSettle();
      expect(picked, ['🎉']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(EmojiRecents.storageKey), '["🎉"]');

      // A fresh store reads the persisted order back: 🎉 now leads.
      EmojiRecents.instance = EmojiRecents();
      expect(quickEmojis(await EmojiRecents.instance.load()).first, '🎉');
    });

    testWidgets('the full grid returns any emoji', (tester) async {
      _phone(tester);
      final picked = <String?>[];
      await tester.pumpWidget(_PickerHost(onPicked: picked.add));
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      final grinning = find.text('😀');
      expect(grinning, findsWidgets);
      await tester.tap(grinning.first);
      await tester.pumpAndSettle();
      expect(picked, ['😀']);
    });

    testWidgets('dismissing returns null', (tester) async {
      _phone(tester);
      final picked = <String?>[];
      await tester.pumpWidget(_PickerHost(onPicked: picked.add));
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(picked, [null]);
    });

    test('quickEmojis puts recents first and tops up with defaults', () {
      expect(quickEmojis(['🦘', '👍']), [
        '🦘',
        '👍',
        '❤️',
        '😂',
        '😮',
        '😢',
        '🎉',
        '🙏',
      ]);
    });
  });

  group('hooks', () {
    test('reactions are allowed in encrypted rooms unless power levels '
        'deny them', () {
      final backend = FakeReactionsBackend();
      final ctx = RoomHookContext(
        backend: backend,
        roomId: _roomId,
        palette: _palette,
        room: const ChatRoom(
          id: _roomId,
          name: 'Secret',
          preview: '',
          lastActivity: null,
          encrypted: true,
        ),
      );
      expect(emojiPickerAvailable, isTrue);
      expect(reactionsAllowed(ctx), isTrue);
      backend.perms = const MessageActionPermissions(canSendMessages: true);
      expect(reactionsAllowed(ctx), isFalse);
      // Unknown (offline) permissions leave the decision to the backend.
      backend.perms = MessageActionPermissions.none;
      expect(reactionsAllowed(ctx), isTrue);
      expect(reactionsAllowed(_ctxFor(PlainBackend())), isTrue);
    });

    testWidgets('message actions follow ownership, pins and permissions', (
      tester,
    ) async {
      _phone(tester);
      final backend = FakeReactionsBackend();
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
      List<String> labels(ChatEntry entry) => [
        for (final item in reactionMessageActions(
          context,
          EntryHookContext(
            backend: backend,
            roomId: _roomId,
            palette: _palette,
            entry: entry,
          ),
        ))
          item.label,
      ];

      final reacted = _entry(
        r'$a',
        reactions: const [ChatReaction(emoji: '👍', count: 1, mine: false)],
      );
      expect(labels(reacted), [
        'Reactions',
        'Forward',
        'Pin',
        'Report content',
        'Remove',
      ]);
      expect(labels(_entry(r'$b', mine: true, pinned: true)), [
        'Forward',
        'Unpin',
      ]);
      expect(labels(_entry('local-echo')), ['Forward']);
      expect(labels(_entry(r'$c', kind: EntryKind.state)), isEmpty);
      backend.perms = const MessageActionPermissions(
        canReact: true,
        canSendMessages: true,
      );
      expect(labels(_entry(r'$d')), ['Forward', 'Report content']);
      expect(
        reactionMessageActions(
          context,
          EntryHookContext(
            backend: PlainBackend(),
            roomId: _roomId,
            palette: _palette,
            entry: reacted,
          ),
        ),
        isEmpty,
      );
    });
  });

  testWidgets('reaction summary lists who reacted per emoji', (tester) async {
    _phone(tester);
    final backend = FakeReactionsBackend()
      ..senders = [
        ReactionSender(
          emoji: '👍',
          userId: '@alice:matrix.example',
          displayName: 'Alice',
          avatarUrl: Uri.parse('mxc://matrix.example/alicePhoto'),
        ),
        ReactionSender(emoji: '👍', userId: '@sam:matrix.example'),
        ReactionSender(
          emoji: '🎉',
          userId: '@bob:matrix.example',
          displayName: 'Bob',
        ),
      ];
    final entry = _entry(
      r'$a',
      reactions: const [
        ChatReaction(emoji: '👍', count: 2, mine: true),
        ChatReaction(emoji: '🎉', count: 1, mine: false),
      ],
    );
    await _runAction(tester, backend, entry, 'Reactions');
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('@sam:matrix.example (you)'), findsOneWidget);
    // Each person's photo, not just an initial.
    final alice = tester.widget<UserAvatar>(
      find.descendant(
        of: find.byKey(const ValueKey('reaction-sender-@alice:matrix.example')),
        matching: find.byType(UserAvatar),
      ),
    );
    expect(alice.url, Uri.parse('mxc://matrix.example/alicePhoto'));
    expect(alice.backend, same(backend));
    expect(find.text('Bob'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('reaction-tab-🎉')));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('chip long-press entry point preselects the pressed emoji', (
    tester,
  ) async {
    _phone(tester);
    final backend = FakeReactionsBackend()
      ..senders = const [
        ReactionSender(emoji: '👍', userId: '@alice:matrix.example'),
        ReactionSender(
          emoji: '🎉',
          userId: '@bob:matrix.example',
          displayName: 'Bob',
        ),
      ];
    final entry = _entry(
      r'$a',
      reactions: const [
        ChatReaction(emoji: '👍', count: 1, mine: false),
        ChatReaction(emoji: '🎉', count: 1, mine: false),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showReactionSummaryForEntry(
                context,
                EntryHookContext(
                  backend: backend,
                  roomId: _roomId,
                  palette: _palette,
                  entry: entry,
                ),
                emoji: '🎉',
              ),
              child: const Text('Long-press chip'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Long-press chip'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('@alice:matrix.example'), findsNothing);
  });

  testWidgets('reaction summary failure keeps counts and can retry', (
    tester,
  ) async {
    _phone(tester);
    final backend = FakeReactionsBackend()..failSenders = true;
    final entry = _entry(
      r'$a',
      reactions: const [ChatReaction(emoji: '👍', count: 2, mine: false)],
    );
    await _runAction(tester, backend, entry, 'Reactions');
    expect(find.textContaining('Couldn’t load who reacted'), findsOneWidget);
    expect(find.text('👍  2'), findsOneWidget);
    backend
      ..failSenders = false
      ..senders = const [
        ReactionSender(emoji: '👍', userId: '@bob:matrix.example'),
      ];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('@bob:matrix.example'), findsWidgets);
  });

  group('forward', () {
    testWidgets('suggests recent rooms, forwards and confirms', (tester) async {
      _phone(tester);
      final backend = FakeReactionsBackend()
        ..roomList = [
          for (var i = 0; i < 7; i++)
            ChatRoom(
              id: '!r$i:matrix.example',
              name: 'Room $i',
              preview: '',
              lastActivity: DateTime(2026, 11, 12 - i),
              encrypted: i.isEven,
            ),
        ];
      await _runAction(tester, backend, _entry(r'$a'), 'Forward');
      expect(find.text('Forward message'), findsOneWidget);
      expect(find.text('SUGGESTIONS'), findsOneWidget);
      expect(find.text('ALL ROOMS'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('forward-search')),
        'room 6',
      );
      await tester.pumpAndSettle();
      expect(find.text('Room 1'), findsNothing);
      await tester.tap(find.text('Room 6'));
      await tester.enterText(find.byKey(const ValueKey('forward-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Room 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forward to 2 rooms'));
      await tester.pumpAndSettle();
      expect(backend.forwarded.map((f) => f.roomId), [
        '!r6:matrix.example',
        '!r1:matrix.example',
      ]);
      expect(backend.forwarded.first.content['body'], 'Hello there');
      expect(find.text('1 message forwarded'), findsOneWidget);
    });

    testWidgets('a partial failure retries only the failed room', (
      tester,
    ) async {
      _phone(tester);
      final backend = FakeReactionsBackend()
        ..roomList = [_room('!ok:x', 'Works'), _room('!bad:x', 'Broken')]
        ..failRooms = {'!bad:x'};
      await _runAction(tester, backend, _entry(r'$a'), 'Forward');
      await tester.tap(find.text('Works'));
      await tester.tap(find.text('Broken'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forward to 2 rooms'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn’t forward to Broken'), findsOneWidget);
      expect(find.text('Forwarded'), findsOneWidget);
      backend.failRooms = {};
      await tester.tap(find.text('Forward to 1 room'));
      await tester.pumpAndSettle();
      expect(backend.forwarded.map((f) => f.roomId), ['!ok:x', '!bad:x']);
      expect(find.text('1 message forwarded'), findsOneWidget);
    });

    testWidgets('limits rooms and supports selecting more messages', (
      tester,
    ) async {
      _phone(tester);
      final backend = FakeReactionsBackend()
        ..roomList = [for (var i = 0; i < 11; i++) _room('!r$i:x', 'Room $i')];
      final older = _entry(r'$older', body: 'Earlier note', minute: 1);
      final initial = _entry(r'$a', minute: 5);
      await _runAction(
        tester,
        backend,
        initial,
        'Forward',
        entries: [older, initial],
      );
      for (var i = 0; i < 10; i++) {
        await tester.tap(find.text('Room $i'));
        await tester.pump();
      }
      await tester.scrollUntilVisible(
        find.text('Room 10'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Room 10'));
      await tester.pump();
      expect(
        find.text('You can forward to up to 10 rooms at once.'),
        findsOneWidget,
      );
      // Clear the limit snackbar so it does not cover the button.
      ScaffoldMessenger.of(
        tester.element(find.text('Select messages')),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(r'forward-select-$older')));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Forward 2 messages'), findsOneWidget);
      await tester.tap(find.text('Forward to 10 rooms'));
      await tester.pumpAndSettle();
      expect(backend.forwarded, hasLength(20));
      expect(backend.forwarded.take(2).map((f) => f.content['body']), [
        'Earlier note',
        'Hello there',
      ]);
      expect(find.text('2 messages forwarded'), findsOneWidget);
    });
  });

  group('pins', () {
    testWidgets('banner cycles pins, previews and opens the list', (
      tester,
    ) async {
      _phone(tester);
      final backend = FakeReactionsBackend()
        ..pins = [r'$p1', r'$p2']
        ..active = [
          _entry(r'$p1', body: 'First pin', pinned: true),
          _entry(
            r'$p2',
            body: 'Second pin',
            sender: '@bob:matrix.example',
            senderName: 'Bob',
            pinned: true,
          ),
        ];
      await tester.pumpWidget(_BannerHost(backend: backend));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message · 2 of 2'), findsOneWidget);
      expect(find.text('Bob: Second pin'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pinned-banner')));
      await tester.pumpAndSettle();
      expect(find.text('PINNED MESSAGE'), findsOneWidget);
      expect(find.text('Second pin'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message · 1 of 2'), findsOneWidget);
      expect(find.text('Alice: First pin'), findsOneWidget);

      await tester.tap(find.text('View all'));
      await tester.pumpAndSettle();
      expect(find.text('2 Pinned messages'), findsOneWidget);
      await tester.tap(find.byTooltip('Pinned message options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();
      expect(backend.pinCalls, [(r'$p2', false)]);
      expect(find.text('1 Pinned message'), findsOneWidget);
    });

    testWidgets('banner fetches pins outside the loaded timeline', (
      tester,
    ) async {
      _phone(tester);
      final load = Completer<ChatEntry?>();
      final backend = FakeReactionsBackend()
        ..pins = [r'$old']
        ..loader = (_) => load.future;
      await tester.pumpWidget(_BannerHost(backend: backend));
      await tester.pump();
      expect(find.text('Loading message…'), findsOneWidget);
      load.complete(_entry(r'$old', body: 'From last year'));
      await tester.pumpAndSettle();
      expect(find.text('Alice: From last year'), findsOneWidget);
      backend.pins = [];
      backend.notify();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pinned-banner')), findsNothing);
    });

    testWidgets('pin action and room details tile', (tester) async {
      _phone(tester);
      final backend = FakeReactionsBackend()..pins = [r'$x'];
      await _runAction(tester, backend, _entry(r'$a'), 'Pin');
      expect(backend.pinCalls, [(r'$a', true)]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: reactionRoomDetailsSections(
                  context,
                  RoomHookContext(
                    backend: backend,
                    roomId: _roomId,
                    palette: _palette,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Pinned messages'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('room-details-pinned')));
      await tester.pumpAndSettle();
      expect(find.text('2 Pinned messages'), findsOneWidget);
    });

    testWidgets('empty list explains how to pin', (tester) async {
      _phone(tester);
      final backend = FakeReactionsBackend();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: reactionRoomDetailsSections(
                  context,
                  RoomHookContext(
                    backend: backend,
                    roomId: _roomId,
                    palette: _palette,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('room-details-pinned')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Pin important messages so that they can be easily discovered',
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('report sends the reason and can block the sender', (
    tester,
  ) async {
    _phone(tester);
    final backend = FakeReactionsBackend();
    await _runAction(tester, backend, _entry(r'$bad'), 'Report content');
    expect(find.text('Report content'), findsOneWidget);
    final send = _filled('Send report');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('report-reason')), 'Spam');
    await tester.tap(find.byKey(const ValueKey('report-block-user')));
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(backend.reports, [(r'$bad', 'Spam')]);
    expect(backend.ignored, ['@alice:matrix.example']);
    expect(find.text('Report submitted. User blocked.'), findsOneWidget);
  });

  testWidgets('report failure stays on screen', (tester) async {
    _phone(tester);
    final backend = FakeReactionsBackend()..failReport = true;
    await _runAction(tester, backend, _entry(r'$bad'), 'Report content');
    await tester.enterText(find.byKey(const ValueKey('report-reason')), 'Spam');
    await tester.pump();
    await tester.tap(_filled('Send report'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t send this report. Try again.'), findsOneWidget);
    expect(backend.ignored, isEmpty);
  });

  testWidgets('moderator removal asks for an optional reason', (tester) async {
    _phone(tester);
    final backend = FakeReactionsBackend();
    await _runAction(tester, backend, _entry(r'$spam'), 'Remove');
    expect(find.text('Remove message?'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('removal-reason')),
      'Off topic',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(backend.removals, [(r'$spam', 'Off topic')]);

    await _runAction(tester, backend, _entry(r'$spam2'), 'Remove');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.removals, hasLength(1));
  });
}

Finder _filled(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is FilledButton),
);

/// A phone-sized logical viewport (540 × 1200).
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

RoomHookContext _ctxFor(ChatBackend backend) => RoomHookContext(
  backend: backend,
  roomId: _roomId,
  palette: _palette,
  room: const ChatRoom(
    id: _roomId,
    name: 'Secret',
    preview: '',
    lastActivity: null,
    encrypted: true,
  ),
);

ChatRoom _room(String id, String name) =>
    ChatRoom(id: id, name: name, preview: '', lastActivity: null);

/// Mounts a host, runs the hook action [label] like the room screen does.
Future<void> _runAction(
  WidgetTester tester,
  FakeReactionsBackend backend,
  ChatEntry entry,
  String label, {
  List<ChatEntry> entries = const [],
}) async {
  _phone(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(defaultVisualTheme),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                final item = reactionMessageActions(
                  context,
                  EntryHookContext(
                    backend: backend,
                    roomId: _roomId,
                    palette: _palette,
                    entry: entry,
                    entries: entries,
                  ),
                ).firstWhere((action) => action.label == label);
                item.onSelected(context);
              },
              child: const Text('Run action'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Run action'));
  await tester.pumpAndSettle();
}

class _PickerHost extends StatelessWidget {
  const _PickerHost({required this.onPicked});
  final ValueChanged<String?> onPicked;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: themeFor(defaultVisualTheme),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              onPicked(await pickEmoji(context, forReaction: true)),
          child: const Text('Pick'),
        ),
      ),
    ),
  );
}

class _BannerHost extends StatelessWidget {
  const _BannerHost({required this.backend});
  final FakeReactionsBackend backend;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: themeFor(defaultVisualTheme),
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            ...reactionRoomBanners(
              context,
              RoomHookContext(
                backend: backend,
                roomId: _roomId,
                palette: _palette,
              ),
            ),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    ),
  );
}
