import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/home/app_lock/app_lock_controller.dart';
import 'package:parallax/features/home/app_lock/app_lock_gate.dart';
import 'package:parallax/features/home/app_lock/pin_hash.dart';
import 'package:parallax/features/platform/matrix_link_opener.dart';
import 'package:parallax/features/platform/platform_intents.dart';
import 'package:parallax/features/platform/platform_intents_host.dart';
import 'package:parallax/features/platform/share_screen.dart';
import 'package:parallax/features/platform/share_shortcuts.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_pictures.dart';
import 'package:parallax/secure_store.dart';

import 'platform_fakes.dart';

final _noon = DateTime(2026, 11, 17, 12);

ChatRoom _chat(
  String id,
  String name, {
  int minutesAgo = 0,
  bool direct = false,
  bool invited = false,
  bool space = false,
  bool lowPriority = false,
  Uri? avatar,
  List<ChatAvatar> heroes = const [],
}) => ChatRoom(
  id: id,
  name: name,
  preview: '',
  lastActivity: _noon.subtract(Duration(minutes: minutesAgo)),
  isDirect: direct,
  invited: invited,
  isSpace: space,
  lowPriority: lowPriority,
  avatarUrl: avatar,
  heroes: heroes,
);

class _Backend extends PlatformBackend {
  final avatars = <Uri, Uint8List>{};
  final cached = <Uri, Uint8List>{};
  final requested = <Uri>[];

  void setRooms(List<ChatRoom> rooms) {
    roomList = rooms;
    notifyListeners();
  }

  @override
  Uint8List? cachedAvatar(Uri url) => cached[url];

  @override
  Future<Uint8List?> loadAvatar(Uri url) async {
    requested.add(url);
    return avatars[url];
  }
}

class _Sink implements ShareShortcutSink {
  /// Each publish (a list) or clear (`'clear'`), in order.
  final calls = <Object>[];
  bool accept = true;
  Completer<void>? gate;

  List<List<ShareShortcut>> get published => [
    for (final call in calls)
      if (call is List<ShareShortcut>) call,
  ];
  int get clears => calls.where((call) => call == 'clear').length;

  @override
  Future<bool> publish(List<ShareShortcut> shortcuts) async {
    calls.add(shortcuts);
    await gate?.future;
    return accept;
  }

  @override
  Future<void> clear() async => calls.add('clear');
}

class _MemoryStorage implements RoomPictureStorage {
  final files = <String, Uint8List>{};

  @override
  Future<Map<String, Uint8List>> readAll() async => {...files};

  @override
  Future<void> write(String key, Uint8List bytes) async => files[key] = bytes;

  @override
  Future<void> delete(String key) async => files.remove(key);
}

class _Store implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _NoBiometrics implements BiometricUnlock {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

Uint8List _bytes(int seed, [int length = 16]) =>
    Uint8List.fromList(List.generate(length, (i) => (seed + i) & 0xff));

List<String> _ids(List<ShareShortcut> shortcuts) => [
  for (final shortcut in shortcuts) shortcut.roomId,
];

void main() {
  final palette = paletteFor(VisualTheme.parallax);
  const delay = Duration(seconds: 2);
  final aliceUrl = Uri.parse('mxc://example.org/alice');
  final teamUrl = Uri.parse('mxc://example.org/team');

  group('shareShortcutRooms', () {
    test('lists joined chats by recent activity', () {
      final rooms = shareShortcutRooms([
        _chat('!old:example.org', 'Old', minutesAgo: 90),
        _chat('!invite:example.org', 'Invite', invited: true),
        _chat('!new:example.org', 'New'),
        _chat('!space:example.org', 'Space', space: true),
        _chat('!low:example.org', 'Low', lowPriority: true),
        _chat('!blank:example.org', ' \n '),
        _chat('!mid:example.org', 'Mid', minutesAgo: 5),
      ]);
      expect(
        [for (final room in rooms) room.id],
        ['!new:example.org', '!mid:example.org', '!old:example.org'],
      );
    });

    test('keeps only the most recent ones', () {
      final rooms = shareShortcutRooms([
        for (var i = 0; i < 20; i++)
          _chat('!r$i:example.org', 'Room $i', minutesAgo: 20 - i),
      ]);
      expect(rooms, hasLength(maxShareShortcuts));
      expect(rooms.first.id, '!r19:example.org');
      expect(rooms.last.id, '!r12:example.org');
    });
  });

  test('shareShortcutLabel is one bounded line', () {
    expect(shareShortcutLabel('  Family\nchat\u0000 '), 'Family chat');
    expect(shareShortcutLabel(' \t\n'), isNull);
    final long = shareShortcutLabel('x' * 200)!;
    expect(long.length, maxShareShortcutLabel);
    expect(long.endsWith('…'), isTrue);
  });

  group('parsePlatformIntent', () {
    test('a share aimed at a suggested chat carries its room', () {
      final intent = parsePlatformIntent({
        'kind': 'share',
        'text': 'https://example.org',
        'roomId': '!chat:example.org',
      });
      expect((intent as ShareIntent).targetRoomId, '!chat:example.org');
    });

    test('a malformed room is dropped but the share is kept', () {
      for (final roomId in <Object?>[
        '#alias:example.org',
        '!',
        '!bad room:example.org',
        '!${'x' * 300}',
        42,
        null,
      ]) {
        final intent = parsePlatformIntent({
          'kind': 'share',
          'text': 'Hello',
          'roomId': roomId,
        });
        expect((intent as ShareIntent).targetRoomId, isNull, reason: '$roomId');
        expect(intent.text, 'Hello');
      }
    });

    test('a chat shortcut opens its room', () {
      final intent = parsePlatformIntent({
        'kind': 'room',
        'roomId': '!opaqueV12RoomId',
      });
      expect((intent as OpenRoomIntent).roomId, '!opaqueV12RoomId');
      expect(
        parsePlatformIntent({'kind': 'room', 'roomId': '@user:x'}),
        isNull,
      );
      expect(parsePlatformIntent({'kind': 'room'}), isNull);
    });
  });

  group('ShareShortcutPublisher', () {
    late _Backend backend;
    late _Sink sink;
    late RoomPictures pictures;
    late DateTime now;

    setUp(() {
      backend = _Backend();
      sink = _Sink();
      pictures = RoomPictures(
        storage: _MemoryStorage(),
        prepare: (source) async => source,
      );
      now = _noon;
    });

    ShareShortcutPublisher publisher({bool? hidden = false}) {
      final publisher = ShareShortcutPublisher(
        backend: backend,
        palette: palette,
        sink: sink,
        pictures: pictures,
        delay: delay,
        clock: () => now,
      );
      addTearDown(publisher.dispose);
      publisher.configure(palette: palette, hidden: hidden);
      return publisher;
    }

    testWidgets('publishes the recent chats with their pictures', (
      tester,
    ) async {
      backend
        ..cached[teamUrl] = _bytes(1)
        ..avatars[aliceUrl] = _bytes(2)
        ..roomList = [
          _chat('!team:example.org', 'Team', minutesAgo: 3, avatar: teamUrl),
          _chat(
            '!alice:example.org',
            'Alice',
            direct: true,
            // A direct chat without its own picture shows the other person.
            heroes: [ChatAvatar(name: 'Alice', url: aliceUrl)],
          ),
          _chat(
            '!group:example.org',
            'Weekend plans',
            minutesAgo: 9,
            heroes: [
              ChatAvatar(name: 'Bo', url: Uri.parse('mxc://example.org/bo')),
              const ChatAvatar(name: 'Cy'),
            ],
          ),
          _chat('!local:example.org', 'Mum', minutesAgo: 12, avatar: teamUrl),
        ];
      await pictures.setFromImage('!local:example.org', _bytes(3));
      publisher();
      await tester.pump(const Duration(seconds: 1));
      expect(sink.calls, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      final shortcuts = sink.published.single;
      expect(_ids(shortcuts), [
        '!alice:example.org',
        '!team:example.org',
        '!group:example.org',
        '!local:example.org',
      ]);
      final alice = shortcuts[0];
      expect(alice.label, 'Alice');
      expect(alice.isDirect, isTrue);
      expect(alice.icon, _bytes(2));
      expect(shortcuts[1].icon, _bytes(1));
      // Several people and no chat picture: the initial, not one of them.
      expect(shortcuts[2].icon, isNull);
      expect(shortcuts[2].initial, 'W');
      expect(shortcuts[2].isDirect, isFalse);
      // A picture set on this phone wins over the chat's own.
      expect(shortcuts[3].icon, _bytes(3));
      // The cached picture needed no download.
      expect(backend.requested, [aliceUrl]);
      expect(sink.clears, 0);
      final channel = alice.toChannel();
      expect(channel['roomId'], '!alice:example.org');
      expect(channel['icon'], _bytes(2));
      expect(channel['background'], isA<int>());
    });

    testWidgets('republishes only when the suggestions change', (tester) async {
      final alice = _chat('!alice:example.org', 'Alice', direct: true);
      final team = _chat('!team:example.org', 'Team', minutesAgo: 5);
      backend.roomList = [alice, team];
      publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      // A new message in the chat already on top changes nothing here.
      backend.setRooms([
        _chat('!alice:example.org', 'Alice', direct: true, minutesAgo: -1),
        team,
      ]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      // Team becomes the most recent chat.
      backend.setRooms([
        alice,
        _chat('!team:example.org', 'Team', minutesAgo: -2),
      ]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(2));
      expect(_ids(sink.published.last), [
        '!team:example.org',
        '!alice:example.org',
      ]);

      // A rename is a change too.
      backend.setRooms([
        alice,
        _chat('!team:example.org', 'Team 2', minutesAgo: -2),
      ]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published.last.first.label, 'Team 2');
    });

    testWidgets('a burst of changes is published once', (tester) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      publisher();
      for (var i = 1; i <= 5; i++) {
        backend.setRooms([
          _chat('!a:example.org', 'A'),
          for (var j = 0; j < i; j++)
            _chat('!n$j:example.org', 'N$j', minutesAgo: -1 - j),
        ]);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));
      expect(sink.published.single, hasLength(6));
    });

    testWidgets('a rejected publish is tried again on the next change', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      sink.accept = false;
      publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      sink.accept = true;
      backend.setRooms([_chat('!a:example.org', 'A', minutesAgo: -1)]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(2));
    });

    testWidgets('nothing is published until the screen lock is known', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      final shortcuts = publisher(hidden: null);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.calls, isEmpty);

      shortcuts.configure(palette: palette, hidden: false);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));
    });

    testWidgets('a PIN removes the suggestions and keeps them away', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      final shortcuts = publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      shortcuts.configure(palette: palette, hidden: true);
      await tester.pump();
      expect(sink.calls.last, 'clear');
      backend.setRooms([_chat('!b:example.org', 'B')]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));
      expect(sink.clears, 1);

      // Without the PIN the same list has to be published again.
      shortcuts.configure(palette: palette, hidden: false);
      await tester.pump(delay);
      await tester.pump();
      expect(_ids(sink.published.last), ['!b:example.org']);
    });

    testWidgets('a PIN set at start clears what an earlier run published', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      publisher(hidden: true);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.calls, ['clear']);
    });

    testWidgets('a PIN set while publishing leaves nothing recorded', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      sink.gate = Completer<void>();
      final shortcuts = publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      // The clear follows the unfinished publish on the channel.
      shortcuts.configure(palette: palette, hidden: true);
      await tester.pump();
      expect(sink.calls.last, 'clear');
      sink.gate!.complete();
      sink.gate = null;
      await tester.pump();

      shortcuts.configure(palette: palette, hidden: false);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(2));
    });

    testWidgets('signing out removes the suggestions for good', (tester) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      backend.replaceAccount('account-b');
      await tester.pump();
      expect(sink.calls.last, 'clear');
      backend.setRooms([_chat('!other:example.org', 'Other account')]);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));
      expect(sink.clears, 1);
    });

    testWidgets('closing without signing out keeps the suggestions', (
      tester,
    ) async {
      backend.roomList = [_chat('!a:example.org', 'A')];
      final shortcuts = publisher();
      await tester.pump(delay);
      await tester.pump();
      shortcuts.dispose();
      await tester.pump(delay);
      expect(sink.clears, 0);
      expect(sink.published, hasLength(1));
    });

    testWidgets('a picture that will not load is not retried at once', (
      tester,
    ) async {
      ChatRoom alice(int minutesAgo) => _chat(
        '!alice:example.org',
        'Alice',
        avatar: aliceUrl,
        minutesAgo: minutesAgo,
      );
      backend.roomList = [alice(0)];
      publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published.single.single.icon, isNull);
      expect(sink.published.single.single.initial, 'A');
      expect(backend.requested, [aliceUrl]);

      // New messages do not ask again, or republish the same list.
      backend.setRooms([alice(-1)]);
      await tester.pump(delay);
      await tester.pump();
      expect(backend.requested, hasLength(1));
      expect(sink.published, hasLength(1));

      now = now.add(const Duration(minutes: 11));
      backend.avatars[aliceUrl] = _bytes(9);
      backend.setRooms([alice(-2)]);
      await tester.pump(delay);
      await tester.pump();
      expect(backend.requested, hasLength(2));
      expect(sink.published.last.single.icon, _bytes(9));
    });

    testWidgets('an empty list while rooms load is not published', (
      tester,
    ) async {
      backend.syncState = RoomSyncState.loading;
      publisher();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.calls, isEmpty);

      // Loaded and still empty: stale suggestions are replaced by none.
      backend.setSync(RoomSyncState.ready);
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published.single, isEmpty);
    });
  });

  group('ShareShortcutsHost', () {
    testWidgets('follows the screen lock PIN', (tester) async {
      final backend = _Backend()..roomList = [_chat('!a:example.org', 'A')];
      final sink = _Sink();
      final lock = AppLockController(
        store: _Store(),
        biometrics: _NoBiometrics(),
        hasher: (pin) async => PinHash.create(pin, iterations: 2),
        verifier: (hash, pin) async => hash.verify(pin),
      );
      addTearDown(lock.dispose);
      await tester.pumpWidget(
        AppLockScope(
          controller: lock,
          child: ShareShortcutsHost(
            app: AppHookContext(
              backend: backend,
              palette: palette,
              navigatorKey: GlobalKey<NavigatorState>(),
            ),
            sink: sink,
            pictures: RoomPictures(storage: _MemoryStorage()),
            delay: delay,
            child: const SizedBox(),
          ),
        ),
      );
      // Not loaded yet: a PIN may be set.
      await tester.pump(delay);
      await tester.pump();
      expect(sink.calls, isEmpty);

      await lock.load();
      await tester.pump();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(1));

      await lock.setPin('2580');
      await tester.pump();
      expect(sink.calls.last, 'clear');

      await lock.removePin();
      await tester.pump();
      await tester.pump(delay);
      await tester.pump();
      expect(sink.published, hasLength(2));
      expect(sink.calls.last, isA<List<ShareShortcut>>());
    });
  });

  group('ShareTargetScreen with a suggested chat', () {
    Future<void> open(
      WidgetTester tester,
      PlatformBackend backend, {
      required String? target,
    }) async {
      late BuildContext home;
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: Builder(
            builder: (context) {
              home = context;
              return const Scaffold(body: Text('Inbox'));
            },
          ),
        ),
      );
      unawaited(
        Navigator.of(home).push<String>(
          MaterialPageRoute(
            builder: (_) => ShareTargetScreen(
              backend: backend,
              palette: palette,
              share: const ShareIntent(text: 'https://example.org/a'),
              targetRoomId: target,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers that chat for one-tap sending', (tester) async {
      final backend = PlatformBackend()
        ..roomList = [
          room('!team:example.org', 'Team room'),
          room('!tully:example.org', 'Tully', minutesAgo: 30, direct: true),
        ];
      await open(tester, backend, target: '!tully:example.org');
      expect(find.text('Send to Tully'), findsOneWidget);
      expect(find.text('https://example.org/a'), findsOneWidget);
      // Once as the chosen chat, not again in the list of other rooms.
      expect(find.text('Tully'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('share-target-!tully:example.org')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('share-room-!tully:example.org')),
        findsNothing,
      );
      expect(find.text('Team room'), findsOneWidget);
      // Nothing is sent until Send is tapped.
      expect(backend.queuedText, isEmpty);

      await tester.tap(find.byKey(const ValueKey('share-target-send')));
      await tester.pumpAndSettle();
      expect(backend.queuedText.single, (
        '!tully:example.org',
        'https://example.org/a',
      ));
      expect(find.byType(ShareTargetScreen), findsNothing);
    });

    testWidgets('another room can still be picked', (tester) async {
      final backend = PlatformBackend()
        ..roomList = [
          room('!team:example.org', 'Team room'),
          room('!tully:example.org', 'Tully', direct: true),
        ];
      await open(tester, backend, target: '!tully:example.org');
      await tester.tap(find.text('Team room'));
      await tester.pumpAndSettle();
      expect(backend.queuedText.single.$1, '!team:example.org');
    });

    testWidgets('a chat that is gone falls back to the room list', (
      tester,
    ) async {
      final backend = PlatformBackend()
        ..roomList = [
          room('!team:example.org', 'Team room'),
          room('!invite:example.org', 'Invite', invited: true),
        ];
      await open(tester, backend, target: '!left:example.org');
      expect(find.text('Send to a room'), findsOneWidget);
      expect(find.byKey(const ValueKey('share-target-send')), findsNothing);
      expect(find.text('Team room'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await open(tester, backend, target: '!invite:example.org');
      expect(find.text('Send to a room'), findsOneWidget);
    });

    testWidgets('the chat appears once the room list has loaded', (
      tester,
    ) async {
      final backend = _Backend();
      await open(tester, backend, target: '!tully:example.org');
      expect(find.text('Send to a room'), findsOneWidget);
      backend.setRooms([room('!tully:example.org', 'Tully', direct: true)]);
      await tester.pump();
      expect(find.text('Send to Tully'), findsOneWidget);
    });
  });

  group('PlatformIntentsHost', () {
    late _Backend backend;
    late FakeIntentSource source;
    late GlobalKey<NavigatorState> navigatorKey;
    late List<String> opened;
    final original = openRoomRoute;

    setUp(() {
      backend = _Backend()
        ..roomList = [
          room('!team:example.org', 'Team room'),
          room('!tully:example.org', 'Tully', minutesAgo: 5, direct: true),
        ];
      source = FakeIntentSource();
      navigatorKey = GlobalKey<NavigatorState>();
      opened = [];
      openRoomRoute = (context, backend, palette, roomId) => opened.add(roomId);
    });

    tearDown(() => openRoomRoute = original);

    Widget app() => MaterialApp(
      navigatorKey: navigatorKey,
      theme: themeFor(VisualTheme.parallax),
      builder: (context, child) => FeatureSettingsScope(
        preferences: AppearancePreferences(),
        draftStore: MessageDraftStore(),
        child: PlatformIntentsHost(
          app: AppHookContext(
            backend: backend,
            palette: palette,
            navigatorKey: navigatorKey,
          ),
          source: source,
          readSharedFile: (_) async => Uint8List.fromList([7]),
          child: child!,
        ),
      ),
      home: const Scaffold(body: Text('Inbox')),
    );

    testWidgets('a share to a suggested chat is confirmed, sent and opened', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      final file = sharedFile('photo.jpg');
      source.controller.add(
        ShareIntent(
          text: 'Look',
          files: [file],
          targetRoomId: '!tully:example.org',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Send to Tully'), findsOneWidget);
      expect(backend.queuedMedia, isEmpty);

      await tester.tap(find.byKey(const ValueKey('share-target-send')));
      await tester.pumpAndSettle();
      expect(backend.queuedMedia.single.$1, '!tully:example.org');
      expect(backend.queuedMedia.single.$3, 'Look');
      expect(source.discarded, [file.path]);
      expect(opened, ['!tully:example.org']);
    });

    testWidgets('a chat shortcut opens its chat above the inbox only', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Settings')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      source.controller.add(const OpenRoomIntent('!tully:example.org'));
      await tester.pumpAndSettle();
      expect(opened, ['!tully:example.org']);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('a shortcut to a chat that is gone says so', (tester) async {
      await tester.pumpWidget(app());
      source.controller.add(const OpenRoomIntent('!left:example.org'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.text('That chat is no longer available.'), findsOneWidget);
    });

    testWidgets('a shortcut waits for the room list after a cold start', (
      tester,
    ) async {
      backend
        ..roomList = []
        ..syncState = RoomSyncState.loading;
      await tester.pumpWidget(app());
      source.controller.add(const OpenRoomIntent('!tully:example.org'));
      await tester.pump(const Duration(seconds: 3));
      expect(opened, isEmpty);

      backend.setRooms([room('!tully:example.org', 'Tully', direct: true)]);
      await tester.pumpAndSettle();
      expect(opened, ['!tully:example.org']);
    });

    testWidgets('the wait for the room list is bounded', (tester) async {
      backend
        ..roomList = []
        ..syncState = RoomSyncState.loading;
      await tester.pumpWidget(app());
      source.controller.add(const OpenRoomIntent('!tully:example.org'));
      await tester.pump();
      await tester.pump(PlatformIntentsHost.roomListWait);
      await tester.pump();
      expect(opened, isEmpty);
      expect(find.text('That chat is no longer available.'), findsOneWidget);
    });

    testWidgets('unmounting ends a pending wait', (tester) async {
      backend
        ..roomList = []
        ..syncState = RoomSyncState.loading;
      await tester.pumpWidget(app());
      source.controller.add(const OpenRoomIntent('!tully:example.org'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(opened, isEmpty);
    });
  });
}
