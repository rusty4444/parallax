// Windows and macOS notifications: toast actions that keep their routing
// payload, desktop action routing, no group summary off Android, and the
// unread badge on the taskbar/tray (Windows) and Dock (macOS).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notification_store.dart';
import 'package:parallax/features/notifications/rich_push_handler.dart';
import 'package:parallax/features/platform/desktop_app.dart';
import 'package:parallax/push_notifications.dart';

import 'notifications_fakes.dart';

const _room = '!room:example.org';
const _registration = 'RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR';

NotificationLine _line(String text, {String eventId = r'$event'}) =>
    NotificationLine(
      eventId: eventId,
      senderId: '@mia:example.org',
      senderName: 'Mia',
      text: text,
      timestamp: DateTime(2026, 11, 25, 10),
      senderAvatarPath: r'C:\cache\mia.png',
    );

RoomNotificationThread _thread(List<NotificationLine> lines) =>
    RoomNotificationThread(
      roomId: _room,
      roomName: 'Book club',
      isDirect: false,
      lines: lines,
      latestEventId: lines.last.eventId,
      roomAvatarPath: r'C:\cache\room.png',
    );

ResolvedPushEvent _resolved({String eventId = r'$event'}) => ResolvedPushEvent(
  roomId: _room,
  eventId: eventId,
  kind: NotifiableEventKind.message,
  roomName: 'Book club',
  isDirect: false,
  line: _line('See you at 6', eventId: eventId),
);

ChatRoom _chat(
  String id, {
  int unread = 0,
  int highlights = 0,
  bool invited = false,
  bool space = false,
  bool markedUnread = false,
  RoomNotificationMode mode = RoomNotificationMode.allMessages,
}) => ChatRoom(
  id: id,
  name: id,
  preview: '',
  lastActivity: null,
  unread: unread,
  highlightCount: highlights,
  invited: invited,
  isSpace: space,
  manuallyUnread: markedUnread,
  notificationMode: mode,
);

class _RoomsBackend extends ChatBackend {
  List<ChatRoom> list = const [];

  @override
  List<ChatRoom> get rooms => list;

  void update(List<ChatRoom> rooms) {
    list = rooms;
    notifyListeners();
  }

  void touch() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Decodes a Windows button's arguments into (action, payload).
(String, String?) _unwrap(String arguments) {
  final map = jsonDecode(arguments) as Map<String, dynamic>;
  return (map['parallax_action'] as String, map['payload'] as String?);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('notification responses', () {
    final payload = jsonEncode({
      'registration_id': _registration,
      'room_id': _room,
      'event_id': r'$event',
    });

    ({
      List<Map<String, dynamic>> opened,
      List<Map<String, dynamic>> markRead,
      List<NotificationResponse> actions,
    })
    route(NotificationResponse response) {
      final opened = <Map<String, dynamic>>[];
      final markRead = <Map<String, dynamic>>[];
      final actions = <NotificationResponse>[];
      routePushNotificationResponse(
        response,
        onOpen: opened.add,
        onMarkRead: markRead.add,
        onAction: actions.add,
      );
      return (opened: opened, markRead: markRead, actions: actions);
    }

    test('a click on a Windows toast opens its room', () {
      // Windows reports the toast's launch string as payload AND action.
      final result = route(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: payload,
        ),
      );
      expect(result.opened.single['room_id'], _room);
      expect(result.markRead, isEmpty);
      expect(result.actions, isEmpty);
    });

    test('Windows Mark as read keeps the toast payload', () {
      final arguments = windowsActionArguments(pushMarkReadActionId, payload);
      final result = route(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: arguments,
          actionId: arguments,
        ),
      );
      expect(result.markRead.single['event_id'], r'$event');
      expect(result.opened, isEmpty);
    });

    test('Windows Reply carries the typed text', () {
      final arguments = windowsActionArguments(pushReplyActionId, payload);
      final result = route(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: arguments,
          actionId: arguments,
          data: const {windowsReplyInputId: 'On my way'},
        ),
      );
      final action = result.actions.single;
      expect(action.actionId, pushReplyActionId);
      expect(action.payload, payload);
      expect(action.input, 'On my way');
      expect(result.opened, isEmpty);
    });

    test('Windows copy actions reach the action handler', () {
      final arguments = windowsActionArguments(pushCopyCodeActionId, payload);
      final result = route(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: arguments,
          actionId: arguments,
        ),
      );
      expect(result.actions.single.actionId, pushCopyCodeActionId);
      expect(result.actions.single.payload, payload);
    });

    test('Android and Apple responses route as before', () {
      expect(
        route(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: payload,
          ),
        ).opened,
        hasLength(1),
      );
      expect(
        route(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            payload: payload,
            actionId: pushMarkReadActionId,
          ),
        ).markRead,
        hasLength(1),
      );
      // macOS: Reply arrives with its own action ID and typed input.
      final reply = route(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: pushReplyActionId,
          input: 'Hi',
        ),
      ).actions.single;
      expect(reply.input, 'Hi');
      expect(reply.payload, payload);
    });

    test('without an action handler, Reply does nothing', () {
      final opened = <Map<String, dynamic>>[];
      routePushNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: pushReplyActionId,
          input: 'Hi',
        ),
        onOpen: opened.add,
      );
      expect(opened, isEmpty);
    });

    test('the generic Windows alert wraps its payload into Mark as read', () {
      const envelope = PushEnvelope(
        registrationId: _registration,
        roomId: _room,
        eventId: r'$event',
      );
      final action = genericPushNotificationDetails(
        envelope,
      ).windows!.actions.single;
      final (id, routed) = _unwrap(action.arguments);
      expect(id, pushMarkReadActionId);
      expect(jsonDecode(routed!), envelope.toJson());
    });
  });

  group('Windows toasts', () {
    bool exists(String _) => true;

    test('room notifications offer Reply and Mark as read', () {
      final rendered = renderRoomThread(
        _thread([_line('See you at 6')]),
        myUserId: '@me:example.org',
        registrationId: _registration,
        fileExists: exists,
      );
      final windows = rendered.details.windows!;
      expect(windows.inputs.single.id, windowsReplyInputId);
      expect(windows.actions.map((a) => a.content), ['Reply', 'Mark as read']);
      final reply = windows.actions.first;
      expect(reply.inputId, windowsReplyInputId);
      for (final action in windows.actions) {
        final (_, payload) = _unwrap(action.arguments);
        expect(payload, rendered.payload);
      }
      expect(rendered.title, 'Book club');
      expect(rendered.body, 'Mia: See you at 6');
      // Room art as the toast's app logo.
      expect(
        windows.images.single.uri,
        Uri.file(r'C:\cache\room.png', windows: true),
      );
      expect(
        windows.images.single.placement,
        WindowsImagePlacement.appLogoOverride,
      );
    });

    test('a one-time code adds Copy code', () {
      final rendered = renderRoomThread(
        _thread([_line('Your code is 482913')]),
        myUserId: '@me:example.org',
        registrationId: _registration,
        fileExists: exists,
      );
      final actions = rendered.details.windows!.actions;
      expect(actions.map((a) => a.content), contains('Copy code'));
      final copy = actions.firstWhere((a) => a.content == 'Copy code');
      expect(_unwrap(copy.arguments).$1, pushCopyCodeActionId);
    });

    test('updates after a quick reply are silent', () {
      final rendered = renderRoomThread(
        _thread([_line('See you at 6')]),
        myUserId: '@me:example.org',
        registrationId: _registration,
        alert: false,
        fileExists: exists,
      );
      expect(rendered.details.windows!.audio!.isSilent, isTrue);
    });

    test('missing image files are left out', () {
      final rendered = renderRoomThread(
        _thread([_line('See you at 6')]),
        myUserId: '@me:example.org',
        registrationId: _registration,
        fileExists: (_) => false,
      );
      expect(rendered.details.windows!.images, isEmpty);
    });

    test(
      'calls, invites, reply status and the summary have Windows details',
      () {
        final event = _resolved();
        expect(
          renderCall(event, registrationId: _registration).details.windows,
          isNotNull,
        );
        expect(
          renderInvite(event, registrationId: _registration).details.windows,
          isNotNull,
        );
        expect(
          renderReplyStatus(
            _room,
            'Sent',
            registrationId: _registration,
          ).details.windows!.audio!.isSilent,
          isTrue,
        );
        expect(
          renderSummary([
            _thread([_line('x')]),
          ]).details.windows,
          isNotNull,
        );
      },
    );
  });

  group('summary notification', () {
    late Directory directory;
    late NotificationStore store;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('parallax_desktop');
      store = NotificationStore(directory);
    });
    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      test('is not posted on $platform', () async {
        debugDefaultTargetPlatformOverride = platform;
        final surface = FakeSurface();
        final handler = RichPushHandler(
          store: store,
          surface: surface,
          resolve: (_, _) async => _resolved(),
          userId: '@me:example.org',
          deviceId: 'DEVICE',
        );
        debugDefaultTargetPlatformOverride = null;
        expect(handler.showSummary, isFalse);
        final outcome = await handler.handle(
          const PushEnvelope(
            registrationId: _registration,
            roomId: _room,
            eventId: r'$event',
          ),
        );
        expect(outcome, RichPushOutcome.rich);
        expect(surface.shown.map((n) => n.id), [roomNotificationId(_room)]);
      });
    }

    test(
      'Windows clears its toasts once every notified chat is read',
      () async {
        final surface = FakeSurface();
        final handler = RichPushHandler(
          store: store,
          surface: surface,
          resolve: (envelope, _) async => ResolvedPushEvent(
            roomId: envelope.roomId,
            eventId: envelope.eventId!,
            kind: NotifiableEventKind.message,
            roomName: 'Room',
            isDirect: false,
            line: _line('Hi', eventId: envelope.eventId!),
          ),
          userId: '@me:example.org',
          deviceId: 'DEVICE',
          showSummary: false,
          clearAllWhenRead: true,
        );
        for (final room in ['!a:example.org', '!b:example.org']) {
          await handler.handle(
            PushEnvelope(
              registrationId: _registration,
              roomId: room,
              eventId: r'$e',
            ),
          );
        }
        await handler.clearRooms(['!a:example.org']);
        expect(surface.cancelledAll, 0, reason: '!b is still unread');
        await handler.clearRooms(['!b:example.org']);
        expect(surface.cancelledAll, 1);
      },
    );

    test('Android keeps grouping under a summary', () {
      final handler = RichPushHandler(
        store: store,
        surface: FakeSurface(),
        resolve: (_, _) async => _resolved(),
        userId: '@me:example.org',
        deviceId: 'DEVICE',
      );
      expect(handler.showSummary, isTrue);
    });
  });

  group('unread badge count', () {
    test('counts unread messages, mentions in muted rooms and invites', () {
      expect(
        unreadBadgeCount([
          _chat('!a', unread: 3),
          _chat('!b', unread: 2, highlights: 1),
          _chat(
            '!muted',
            unread: 9,
            highlights: 1,
            mode: RoomNotificationMode.mute,
          ),
          _chat('!quiet', unread: 0, mode: RoomNotificationMode.mute),
          _chat('!invite', invited: true),
          _chat('!marked', markedUnread: true),
          _chat('!space', unread: 4, space: true),
          _chat('!read'),
        ]),
        3 + 2 + 1 + 1 + 1,
      );
    });

    test('is zero with nothing unread', () {
      expect(unreadBadgeCount([_chat('!a'), _chat('!b')]), 0);
    });
  });

  group('desktop badge host', () {
    const channel = MethodChannel('parallax/desktop');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    List<Object?> counts() => [
      for (final call in calls)
        if (call.method == 'setBadgeCount')
          (call.arguments as Map<Object?, Object?>)['count'],
    ];

    testWidgets('follows the room list and clears on sign-out', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final backend = _RoomsBackend()..list = [_chat('!a', unread: 2)];
        await tester.pumpWidget(
          AppBadgeHost(backend: backend, child: const SizedBox()),
        );
        await tester.pump();
        expect(counts(), [2]);

        // Timeline updates that leave the room list alone send nothing.
        backend.touch();
        await tester.pump();
        expect(counts(), [2]);

        backend.update([_chat('!a', unread: 2), _chat('!b', unread: 1)]);
        await tester.pump();
        expect(counts(), [2, 3]);

        // A new list with the same count sends nothing.
        backend.update([_chat('!a', unread: 3)]);
        await tester.pump();
        expect(counts(), [2, 3]);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(counts(), [2, 3, 0]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('does nothing on phones', (tester) async {
      final backend = _RoomsBackend()..list = [_chat('!a', unread: 2)];
      await tester.pumpWidget(
        AppBadgeHost(backend: backend, child: const SizedBox()),
      );
      backend.update([_chat('!a', unread: 5)]);
      await tester.pump();
      expect(calls, isEmpty);
    });

    test('showWindow reaches the desktop runner only', () async {
      await const DesktopAppChannel().showWindow();
      expect(calls, isEmpty);
      for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = platform;
        await const DesktopAppChannel().showWindow();
      }
      debugDefaultTargetPlatformOverride = null;
      expect(calls.map((c) => c.method), ['showWindow', 'showWindow']);
    });
  });
}
