import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/android_auto/android_auto_features.dart';
import 'package:parallax/features/android_auto/android_auto_host.dart';
import 'package:parallax/features/android_auto/android_auto_platform.dart';
import 'package:parallax/features/android_auto/car_conversations.dart';
import 'package:parallax/features/chat_lock/chat_lock_store.dart';
import 'package:parallax/features/home/app_lock/app_lock_controller.dart';
import 'package:parallax/features/home/app_lock/app_lock_gate.dart';
import 'package:parallax/features/home/app_lock/pin_hash.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/room_events.dart' show MatrixSdkAccess;
import 'package:parallax/secure_store.dart';

import 'widget_test.dart' show FakeBackend;

const _me = '@me:example.org';
const _alice = '@alice:example.org';
const _bob = '@bob:example.org';

ChatRoom _room(
  String id, {
  int unread = 0,
  int minutesAgo = 0,
  bool invited = false,
  bool space = false,
  bool manuallyUnread = false,
}) => ChatRoom(
  id: id,
  name: 'Room $id',
  preview: '',
  lastActivity: DateTime(
    2026,
    11,
    25,
    9,
  ).subtract(Duration(minutes: minutesAgo)),
  unread: unread,
  invited: invited,
  isSpace: space,
  manuallyUnread: manuallyUnread,
);

CarTimelineEvent _event(
  String id,
  String sender,
  int minute, {
  String type = 'm.room.message',
  Map<String, Object?>? content,
  String body = '',
  bool redacted = false,
  String? stateKey,
}) => CarTimelineEvent(
  eventId: id,
  senderId: sender,
  type: type,
  content: content ?? {'msgtype': 'm.text', 'body': body},
  timestamp: DateTime(2026, 11, 25, 9, minute),
  redacted: redacted,
  stateKey: stateKey,
);

String _name(String userId) => switch (userId) {
  _alice => 'Alice',
  _bob => 'Bob',
  _ => 'Me',
};

class _Backend extends FakeBackend implements AndroidAutoFeatures {
  _Backend() {
    currentUserId = _me;
  }

  final marked = <(String, bool)>[];
  final replies = <(String, String)>[];
  CarReplyResult replyResult = CarReplyResult.sent;
  int conversationRequests = 0;

  void setRooms(List<ChatRoom> rooms) {
    roomList = rooms;
    notifyListeners();
  }

  @override
  Future<List<CarConversation>> conversations(
    List<ChatRoom> rooms, {
    int messages = maxCarMessagesPerConversation,
    Directory? cacheRoot,
    void Function()? onLatePictures,
  }) async {
    conversationRequests++;
    return [
      for (final room in rooms)
        CarConversation(
          roomId: room.id,
          title: room.name,
          isDirect: false,
          unread: room.unread,
          messages: [
            CarMessageLine(
              eventId: '\$${room.id}',
              senderId: _alice,
              senderName: 'Alice',
              text: 'Hello from ${room.name}',
              timestamp: DateTime(2026, 11, 25, 9),
              fromMe: false,
              read: room.unread == 0,
            ),
          ],
        ),
    ];
  }

  @override
  Future<void> markRead(String roomId, {required bool publicReceipt}) async =>
      marked.add((roomId, publicReceipt));

  @override
  Future<CarReplyResult> reply(String roomId, String text) async {
    replies.add((roomId, text));
    return replyResult;
  }
}

class _Platform implements AndroidAutoPlatform {
  CarRequestHandler? handler;
  final attached = <bool>[];
  int invalidations = 0;
  bool carScreenActive = false;

  @override
  void setHandler(CarRequestHandler? handler) => this.handler = handler;

  @override
  Future<bool> hostAttached(bool attached) async {
    this.attached.add(attached);
    return carScreenActive;
  }

  @override
  Future<void> invalidate() async => invalidations++;
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

class _Database extends Fake implements matrix.DatabaseApi {
  _Database(this.events);
  final List<matrix.Event> events;
  @override
  Future<matrix.User?> getUser(String userId, matrix.Room room) async => null;
  @override
  Future<List<matrix.Event>> getEventList(
    matrix.Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => events.where((event) => event.roomId == room.id).toList();
}

class _Client extends matrix.Client {
  _Client(List<matrix.Event> Function(matrix.Client) events)
    : super(
        'android-auto-test',
        database: _Database([]),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example.org');
    accessToken = 'token';
    (database as _Database).events.addAll(events(this));
  }

  @override
  String? get userID => _me;

  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _SdkBackend extends FakeBackend implements MatrixSdkAccess {
  _SdkBackend(this.client);
  final matrix.Client client;
  bool signedIn = true;
  @override
  matrix.Client? get sdkClient => client;
  @override
  bool isSessionCurrent(matrix.Client client) =>
      signedIn && identical(client, this.client);
}

void main() {
  test('the live client reads recent messages from its store', () async {
    late matrix.Room room;
    matrix.Event message(String id, String sender, int minute, Object body) =>
        matrix.Event(
          type: 'm.room.message',
          content: body is Map<String, Object?>
              ? body
              : {'msgtype': 'm.text', 'body': body},
          senderId: sender,
          eventId: id,
          originServerTs: DateTime(2026, 11, 25, 9, minute),
          room: room,
        );
    final client = _Client((client) {
      room = matrix.Room(id: '!group:example.org', client: client);
      room.setState(
        matrix.Event(
          type: 'm.room.member',
          stateKey: _alice,
          content: {'membership': 'join', 'displayname': 'Alice'},
          senderId: _alice,
          eventId: r'$member',
          originServerTs: DateTime(2026, 11, 25),
          room: room,
        ),
      );
      client.rooms.add(room);
      return [
        message(r'$1', _alice, 1, 'Lunch?'),
        message(r'$2', _me, 2, 'Sure'),
        message(r'$3', _alice, 3, {
          'msgtype': 'm.text',
          'body': '* At 1',
          'm.new_content': {'msgtype': 'm.text', 'body': 'At 1'},
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$1'},
        }),
        message(r'$4', _alice, 4, 'See you there'),
      ];
    });
    final backend = _SdkBackend(client);
    final features = androidAutoFeaturesOf(backend)!;
    expect(features.userId, _me);
    final conversations = await features.conversations([
      ChatRoom(
        id: '!group:example.org',
        name: 'Lunch club',
        preview: '',
        lastActivity: DateTime(2026, 11, 25, 9, 4),
        unread: 1,
      ),
      // Not in the client: skipped.
      _room('!missing:example.org'),
    ]);
    final conversation = conversations.single;
    expect(conversation.title, 'Lunch club');
    expect(conversation.isDirect, isFalse);
    expect(conversation.messages.map((line) => line.text), [
      'At 1',
      'Sure',
      'See you there',
    ]);
    expect(conversation.messages.map((line) => line.senderName), [
      'Alice',
      'Me',
      'Alice',
    ]);
    expect(conversation.messages.map((line) => line.read), [true, true, false]);
    backend.signedIn = false;
    expect(features.userId, isNull);
    await expectLater(
      features.conversations([_room('!group:example.org')]),
      throwsA(isA<CarSessionChanged>()),
    );
  });

  group('car rooms', () {
    test('joined chats only, newest first, bounded', () {
      final rooms = [
        _room('!old:x.org', minutesAgo: 30),
        _room('!new:x.org', unread: 1),
        _room('!invite:x.org', invited: true),
        _room('!space:x.org', space: true),
        _room('!locked:x.org', unread: 4, minutesAgo: 1),
        _room('!marked:x.org', manuallyUnread: true, minutesAgo: 5),
      ];
      List<String> ids({bool unreadOnly = false, int limit = 10}) => [
        for (final room in carRoomsFor(
          rooms,
          unreadOnly: unreadOnly,
          limit: limit,
          isLocked: (id) => id == '!locked:x.org',
        ))
          room.id,
      ];
      expect(ids(), ['!new:x.org', '!marked:x.org', '!old:x.org']);
      expect(ids(unreadOnly: true), ['!new:x.org', '!marked:x.org']);
      expect(ids(limit: 1), ['!new:x.org']);
      expect(ids(limit: 500), hasLength(3));
    });
  });

  group('car message lines', () {
    test('messages oldest first, edits applied, noise left out', () {
      final lines = carMessageLines(
        [
          _event(r'$3', _alice, 3, body: 'See you at 6'),
          _event(r'$1', _alice, 1, body: 'Hi'),
          _event(r'$2', _me, 2, body: 'Hello'),
          // Alice edits her message.
          _event(
            r'$4',
            _alice,
            4,
            content: {
              'msgtype': 'm.text',
              'body': '* See you at 7',
              'm.new_content': {'msgtype': 'm.text', 'body': 'See you at 7'},
              'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$3'},
            },
          ),
          // Bob cannot edit Alice's message.
          _event(
            r'$5',
            _bob,
            5,
            content: {
              'msgtype': 'm.text',
              'body': '* hijacked',
              'm.new_content': {'msgtype': 'm.text', 'body': 'hijacked'},
              'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$1'},
            },
          ),
          _event(
            r'$6',
            _bob,
            6,
            type: 'm.reaction',
            content: {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': r'$1',
                'key': '👍',
              },
            },
          ),
          _event(r'$7', _bob, 7, body: 'gone', redacted: true),
          _event(
            r'$8',
            _bob,
            8,
            type: 'm.room.member',
            content: {'membership': 'join'},
            stateKey: _bob,
          ),
          _event(r'$9', _bob, 9, type: 'm.room.encrypted', content: {}),
          _event(r'$10', _bob, 10, type: 'm.call.invite', content: {}),
          _event(
            r'$11',
            _bob,
            11,
            content: {'msgtype': 'm.image', 'body': 'photo.jpg'},
          ),
        ],
        myUserId: _me,
        nameOf: _name,
        unreadCount: 0,
      );
      expect(lines.map((line) => line.text), [
        'Hi',
        'Hello',
        'See you at 7',
        'Image',
      ]);
      expect(lines.map((line) => line.fromMe), [false, true, false, false]);
      expect(lines.first.senderName, 'Alice');
      expect(lines.every((line) => line.read), isTrue);
    });

    test('only the newest lines are kept', () {
      final lines = carMessageLines(
        [for (var i = 0; i < 10; i++) _event('\$$i', _alice, i, body: 'm$i')],
        myUserId: _me,
        nameOf: _name,
        unreadCount: 0,
        max: 3,
      );
      expect(lines.map((line) => line.text), ['m7', 'm8', 'm9']);
    });

    test('unread from the read receipt, else from the unread count', () {
      final events = [
        _event(r'$1', _alice, 1, body: 'one'),
        _event(r'$2', _me, 2, body: 'mine'),
        _event(r'$3', _alice, 3, body: 'three'),
        _event(r'$4', _bob, 4, body: 'four'),
      ];
      List<bool> read({
        int unread = 2,
        bool marked = false,
        DateTime? receipt,
      }) => [
        for (final line in carMessageLines(
          events,
          myUserId: _me,
          nameOf: _name,
          unreadCount: unread,
          markedUnread: marked,
          readUpTo: receipt,
        ))
          line.read,
      ];
      // Receipt sent at 9:02: later messages from others are unread.
      expect(read(receipt: DateTime(2026, 11, 25, 9, 2)), [
        true,
        true,
        false,
        false,
      ]);
      // No receipt: the newest two from others.
      expect(read(), [true, true, false, false]);
      // Counting stops at your own message.
      expect(read(unread: 5), [true, true, false, false]);
      // Marked unread with no count: the newest message.
      expect(read(unread: 0, marked: true), [true, true, true, false]);
      // Nothing unread.
      expect(read(unread: 0, receipt: DateTime(2026, 11, 25, 9)), [
        true,
        true,
        true,
        true,
      ]);
    });

    test('mentions are named and blank text is dropped', () {
      final lines = carMessageLines(
        [
          _event(r'$1', _alice, 1, body: 'hey @bob:example.org'),
          _event(r'$2', _alice, 2, body: '   '),
        ],
        myUserId: _me,
        nameOf: _name,
        unreadCount: 0,
        decorate: (text) => text.replaceAll(_bob, 'Bob'),
      );
      expect(lines.single.text, 'hey Bob');
    });
  });

  group('car snapshot', () {
    test('states carry no chats; chats without messages are dropped', () {
      expect(carSnapshotJson(CarScreenState.locked), {'state': 'locked'});
      final json = carSnapshotJson(
        CarScreenState.ready,
        selfId: _me,
        conversations: [
          CarConversation(
            roomId: '!a:x.org',
            title: 'A',
            isDirect: true,
            unread: 1,
            iconPath: '/cache/a.png',
            messages: [
              CarMessageLine(
                eventId: r'$1',
                senderId: _alice,
                senderName: 'Alice',
                senderIconPath: '/cache/alice.png',
                text: 'Hi',
                timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
                fromMe: false,
                read: false,
              ),
              CarMessageLine(
                eventId: r'$2',
                senderId: _me,
                senderName: 'Me',
                text: 'Hello',
                timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
                fromMe: true,
                read: true,
              ),
            ],
          ),
          const CarConversation(
            roomId: '!empty:x.org',
            title: 'Empty',
            isDirect: false,
            unread: 0,
            messages: [],
          ),
        ],
      );
      expect(json['state'], 'ready');
      expect(json['self'], {'id': _me, 'name': 'Me'});
      final conversations = json['conversations']! as List;
      expect(conversations, hasLength(1));
      expect(conversations.single, {
        'id': '!a:x.org',
        'title': 'A',
        'direct': true,
        'icon': '/cache/a.png',
        'unread': 1,
        'messages': [
          {
            'sender': _alice,
            'senderName': 'Alice',
            'senderIcon': '/cache/alice.png',
            'text': 'Hi',
            'ts': 1000,
            'me': false,
            'read': false,
          },
          // Your own messages carry no sender.
          {
            'senderName': 'Me',
            'text': 'Hello',
            'ts': 2000,
            'me': true,
            'read': true,
          },
        ],
      });
    });
  });

  group('car host', () {
    late _Backend backend;
    late _Platform platform;
    late ChatLockStore chatLocks;

    setUp(() async {
      backend = _Backend()
        ..roomList = [
          _room('!a:x.org', unread: 2),
          _room('!b:x.org', minutesAgo: 5),
          _room('!locked:x.org', unread: 1, minutesAgo: 1),
        ];
      platform = _Platform();
      chatLocks = ChatLockStore(
        secureStore: _Store(),
        biometrics: _NoBiometrics(),
      );
      await chatLocks.bindAccount(null);
      await chatLocks.setLocked('!locked:x.org', true);
    });

    Widget host({Widget Function(Widget child)? wrap}) {
      final child = AndroidAutoHost(
        app: AppHookContext(
          backend: backend,
          palette: paletteFor(defaultVisualTheme),
          navigatorKey: GlobalKey<NavigatorState>(),
        ),
        platform: platform,
        enabled: true,
        cacheRoot: () async => null,
        chatLocks: chatLocks,
        child: const SizedBox(),
      );
      return wrap?.call(child) ?? child;
    }

    Future<Object?> ask(
      WidgetTester tester,
      String method, [
      Map<String, Object?> arguments = const {},
    ]) async =>
        tester.runAsync<Object?>(() => platform.handler!(method, arguments));

    List<String> ids(Object? snapshot) => [
      for (final conversation in (snapshot! as Map)['conversations']! as List)
        (conversation as Map)['id'] as String,
    ];

    testWidgets('answers the car with the chats it may show', (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      expect(platform.attached, [true]);
      expect(platform.handler, isNotNull);

      final all = await ask(tester, 'conversations', {
        'limit': 10,
        'unreadOnly': false,
        'messages': 6,
      });
      expect((all! as Map)['state'], 'ready');
      expect((all as Map)['self'], {'id': _me, 'name': 'Me'});
      // The locked chat never reaches the car.
      expect(ids(all), ['!a:x.org', '!b:x.org']);
      final unread = await ask(tester, 'conversations', {
        'limit': 10,
        'unreadOnly': true,
      });
      expect(ids(unread), ['!a:x.org']);

      expect(await ask(tester, 'markRead', {'roomId': '!a:x.org'}), isTrue);
      expect(backend.marked, [('!a:x.org', true)]);
      expect(
        await ask(tester, 'markRead', {'roomId': '!locked:x.org'}),
        isFalse,
      );
      expect(await ask(tester, 'markRead', {'roomId': '!gone:x.org'}), isFalse);

      expect(
        await ask(tester, 'reply', {
          'roomId': '!a:x.org',
          'text': '  On my way  ',
        }),
        'sent',
      );
      backend.replyResult = CarReplyResult.stillSending;
      expect(
        await ask(tester, 'reply', {'roomId': '!b:x.org', 'text': 'Soon'}),
        'stillSending',
      );
      expect(
        await ask(tester, 'reply', {'roomId': '!locked:x.org', 'text': 'x'}),
        'failed',
      );
      expect(
        await ask(tester, 'reply', {'roomId': '!a:x.org', 'text': '   '}),
        'failed',
      );
      expect(backend.replies, [
        ('!a:x.org', 'On my way'),
        ('!b:x.org', 'Soon'),
      ]);

      await tester.pumpWidget(const SizedBox());
      expect(platform.attached, [true, false]);
      expect(platform.handler, isNull);
    });

    testWidgets('waits for the room list and the locked-chat list', (
      tester,
    ) async {
      backend
        ..roomList = []
        ..syncState = RoomSyncState.loading;
      await tester.pumpWidget(host());
      await tester.pump();
      expect(
        ((await ask(tester, 'conversations'))! as Map)['state'],
        'loading',
      );
      final unloaded = ChatLockStore(
        secureStore: _Store(),
        biometrics: _NoBiometrics(),
      );
      chatLocks = unloaded;
      backend
        ..roomList = [_room('!a:x.org')]
        ..syncState = RoomSyncState.ready;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(host());
      await tester.pump();
      expect(
        ((await ask(tester, 'conversations'))! as Map)['state'],
        'loading',
      );
      expect(await ask(tester, 'markRead', {'roomId': '!a:x.org'}), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('says only that Parallax is locked while the app lock is on', (
      tester,
    ) async {
      final store = _Store()
        ..values['parallax.app_lock.v1.pin'] = PinHash.create(
          '2580',
          iterations: 2,
        ).encode();
      final lock = AppLockController(
        store: store,
        biometrics: _NoBiometrics(),
        hasher: (pin) async => PinHash.create(pin, iterations: 2),
        verifier: (hash, pin) async => hash.verify(pin),
      );
      addTearDown(lock.dispose);
      await tester.runAsync(lock.load);
      expect(lock.locked, isTrue);
      await tester.pumpWidget(
        host(
          wrap: (child) => AppLockScope(controller: lock, child: child),
        ),
      );
      await tester.pump();
      expect(await ask(tester, 'conversations'), {'state': 'locked'});
      expect(await ask(tester, 'markRead', {'roomId': '!a:x.org'}), isFalse);
      expect(
        await ask(tester, 'reply', {'roomId': '!a:x.org', 'text': 'hi'}),
        'failed',
      );
      expect(backend.conversationRequests, 0);
      expect(backend.marked, isEmpty);
      expect(backend.replies, isEmpty);

      // Unlocking on the phone lets the car show chats again.
      platform.carScreenActive = true;
      await tester.runAsync(
        () => platform.handler!('carScreenActive', {'active': true}),
      );
      await tester.runAsync(() => lock.verifyPin('2580'));
      await tester.pump();
      await tester.pump(AndroidAutoHost.changeDelay);
      expect(platform.invalidations, 1);
      expect(ids(await ask(tester, 'conversations')), ['!a:x.org', '!b:x.org']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tells a showing car screen when the chats change', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pump();
      // No car screen: nothing to tell.
      backend.setRooms([_room('!a:x.org', unread: 3)]);
      await tester.pump(AndroidAutoHost.changeDelay);
      expect(platform.invalidations, 0);

      await ask(tester, 'carScreenActive', {'active': true});
      backend.setRooms([_room('!a:x.org', unread: 4)]);
      await tester.pump(const Duration(milliseconds: 300));
      backend.setRooms([_room('!a:x.org', unread: 5)]);
      // Same list again: not a change.
      backend.notifyListeners();
      await tester.pump(AndroidAutoHost.changeDelay);
      expect(platform.invalidations, 1);

      // Locking a chat is a change too.
      await chatLocks.setLocked('!a:x.org', true);
      await tester.pump(AndroidAutoHost.changeDelay);
      expect(platform.invalidations, 2);

      await ask(tester, 'carScreenActive', {'active': false});
      backend.setRooms([_room('!a:x.org', unread: 6)]);
      await tester.pump(AndroidAutoHost.changeDelay);
      expect(platform.invalidations, 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a replacement host keeps the car', (tester) async {
      await tester.pumpWidget(Column(children: [host(), const SizedBox()]));
      await tester.pump();
      final first = platform.handler;
      await tester.pumpWidget(
        Column(
          children: [
            const SizedBox(),
            KeyedSubtree(key: const ValueKey('second'), child: host()),
          ],
        ),
      );
      await tester.pump();
      expect(platform.handler, isNotNull);
      expect(identical(platform.handler, first), isFalse);
      // The old host's disposal did not detach the new one.
      expect(platform.attached.last, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(platform.handler, isNull);
    });

    testWidgets('other platforms and backends do nothing', (tester) async {
      await tester.pumpWidget(
        AndroidAutoHost(
          app: AppHookContext(
            backend: backend,
            palette: paletteFor(defaultVisualTheme),
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
          platform: platform,
          enabled: false,
          child: const SizedBox(),
        ),
      );
      final plain = FakeBackend();
      expect(androidAutoFeaturesOf(plain), isNull);
      await tester.pumpWidget(
        AndroidAutoHost(
          app: AppHookContext(
            backend: plain,
            palette: paletteFor(defaultVisualTheme),
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
          platform: platform,
          enabled: true,
          child: const SizedBox(),
        ),
      );
      expect(platform.handler, isNull);
      expect(platform.attached, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('projection is never assumed off the phone', () async {
    // Host tests do not run on Android.
    expect(await androidAutoProjecting(), isFalse);
  });
}
