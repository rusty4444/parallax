import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/notifications/notification_content.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notification_store.dart';
import 'package:parallax/features/notifications/rich_push_handler.dart';
import 'package:parallax/push_notifications.dart';

import 'notifications_fakes.dart';
import 'package:parallax/features/notifications/matrix_push_projection.dart'
    show SilentPushEvent, silentPushEventTypes;

const registration = 'RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR';
const room = '!room:example.org';

PushEnvelope envelope([String eventId = r'$event']) =>
    PushEnvelope(registrationId: registration, roomId: room, eventId: eventId);

ResolvedPushEvent resolved({
  String eventId = r'$event',
  String text = 'See you at 6',
  NotifiableEventKind kind = NotifiableEventKind.message,
  bool ringing = false,
  bool isDirect = false,
  bool highlight = false,
  String? imagePath,
  String? avatarPath,
  String? roomAvatarPath,
  DateTime? at,
}) => ResolvedPushEvent(
  roomId: room,
  eventId: eventId,
  kind: kind,
  roomName: 'Book club',
  isDirect: isDirect,
  roomAvatarPath: roomAvatarPath,
  ringing: ringing,
  line: NotificationLine(
    eventId: eventId,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    text: text,
    timestamp: at ?? DateTime.now(),
    highlight: highlight,
    imagePath: imagePath,
    senderAvatarPath: avatarPath,
  ),
);

AndroidNotificationDetails android(RenderedNotification n) =>
    n.details.android!;

MessagingStyleInformation style(RenderedNotification n) =>
    android(n).styleInformation! as MessagingStyleInformation;

void main() {
  late Directory directory;
  late NotificationStore store;
  late FakeSurface surface;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('parallax_handler');
    store = NotificationStore(directory);
    surface = FakeSurface();
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  RichPushHandler handler(
    PushEventResolver resolve, {
    bool Function()? isCurrent,
    Future<bool> Function()? confirm,
    bool Function(String)? suppress,
    Duration timeout = const Duration(seconds: 5),
    NotificationStore? overrideStore,
    bool useStore = true,
  }) => RichPushHandler(
    store: useStore ? (overrideStore ?? store) : null,
    surface: surface,
    resolve: resolve,
    userId: '@me:example.org',
    deviceId: 'DEVICE',
    contentUriFor: (path) => 'content://test$path',
    resolveTimeout: timeout,
    isCurrent: isCurrent,
    confirm: confirm,
    suppressRoom: suppress,
  );

  group('rendered notification', () {
    test(
      'MessagingStyle per room with sender, room title and actions',
      () async {
        final outcome = await handler(
          (_, _) async => resolved(highlight: true),
        ).handle(envelope());
        expect(outcome, RichPushOutcome.rich);
        final room = surface.byId(roomNotificationId('!room:example.org'))!;
        expect(room.title, 'Book club');
        expect(room.body, 'Alice: See you at 6');
        final messaging = style(room);
        expect(messaging.conversationTitle, 'Book club');
        expect(messaging.groupConversation, isTrue);
        expect(messaging.person.name, 'Me');
        expect(messaging.messages!.single.person!.name, 'Alice');
        expect(messaging.messages!.single.person!.key, '@alice:example.org');
        expect(messaging.messages!.single.text, 'See you at 6');
        final details = android(room);
        expect(details.subText, isNull);
        expect(details.visibility, NotificationVisibility.private);
        expect(details.groupKey, notificationGroupKey);
        expect(details.category, AndroidNotificationCategory.message);
        expect(details.priority, Priority.max);
        final actions = details.actions!;
        expect(actions.map((a) => a.id), [
          pushReplyActionId,
          pushMarkReadActionId,
        ]);
        final reply = actions.first;
        expect(reply.inputs.single.label, 'Message');
        // Replies never open the app: they go through the action isolate.
        expect(reply.showsUserInterface, isFalse);
        expect(reply.cancelNotification, isFalse);
        final payload = jsonDecode(room.payload!) as Map<String, dynamic>;
        expect(payload['registration_id'], registration);
        expect(payload['room_id'], '!room:example.org');
        expect(payload['event_id'], r'$event');
        expect(payload.containsKey('text'), isFalse);
        // Grouped under a summary.
        final summary = surface.byId(notificationSummaryId)!;
        expect(android(summary).setAsGroupSummary, isTrue);
      },
    );

    test('direct chats use the sender as title and no group title', () async {
      await handler(
        (_, _) async => resolved(isDirect: true),
      ).handle(envelope());
      final room = surface.byId(roomNotificationId('!room:example.org'))!;
      expect(room.title, 'Alice');
      expect(style(room).conversationTitle, isNull);
      expect(style(room).groupConversation, isFalse);
    });

    test(
      'direct avatars stay on the sender and group rows have fallbacks',
      () async {
        final roomAvatar = File('${directory.path}/room.png')
          ..writeAsBytesSync([1, 2, 3]);
        final senderAvatar = File('${directory.path}/sender.png')
          ..writeAsBytesSync([4, 5, 6]);

        Future<String?> largeIcon({
          required String eventId,
          required bool isDirect,
          String? roomPath,
          String? senderPath,
        }) async {
          await handler(
            (_, _) async => resolved(
              eventId: eventId,
              isDirect: isDirect,
              avatarPath: senderPath,
              roomAvatarPath: roomPath,
            ),
            useStore: false,
          ).handle(envelope(eventId));
          final bitmap = android(
            surface.byId(roomNotificationId(room))!,
          ).largeIcon;
          return bitmap is FilePathAndroidBitmap ? bitmap.data : null;
        }

        expect(
          await largeIcon(
            eventId: r'$group-room',
            isDirect: false,
            roomPath: roomAvatar.path,
          ),
          roomAvatar.path,
        );
        expect(
          await largeIcon(
            eventId: r'$direct-room',
            isDirect: true,
            roomPath: roomAvatar.path,
            senderPath: senderAvatar.path,
          ),
          isNull,
        );
        expect(
          await largeIcon(
            eventId: r'$direct-fallback',
            isDirect: true,
            senderPath: senderAvatar.path,
          ),
          isNull,
        );
        // The direct sender still has their name-level MessagingStyle avatar;
        // only the duplicate large bitmap is omitted.
        final person = style(
          surface.byId(roomNotificationId(room))!,
        ).messages!.single.person!;
        expect(
          (person.icon as BitmapFilePathAndroidIcon).data,
          senderAvatar.path,
        );
        expect(
          await largeIcon(
            eventId: r'$group-no-room-art',
            isDirect: false,
            senderPath: senderAvatar.path,
          ),
          senderAvatar.path,
        );
        final groupStyle = android(
          surface.byId(roomNotificationId(room))!,
        ).styleInformation;
        expect(groupStyle, isA<BigTextStyleInformation>());
        expect(
          (groupStyle as BigTextStyleInformation).bigText,
          'Alice: See you at 6',
        );
        // The collapsed group summary also has an avatar to show.
        final summaryIcon = android(
          surface.byId(notificationSummaryId)!,
        ).largeIcon;
        expect((summaryIcon as FilePathAndroidBitmap).data, senderAvatar.path);
      },
    );

    test('messages accumulate in one notification per room', () async {
      final base = DateTime.now().subtract(const Duration(minutes: 5));
      await handler(
        (_, _) async => resolved(eventId: r'$1', text: 'first', at: base),
      ).handle(envelope(r'$1'));
      await handler(
        (_, _) async => resolved(
          eventId: r'$2',
          text: 'second',
          at: base.add(const Duration(minutes: 1)),
        ),
      ).handle(envelope(r'$2'));
      final room = surface.byId(roomNotificationId('!room:example.org'))!;
      expect(style(room).messages!.map((m) => m.text), ['first', 'second']);
      expect(
        (jsonDecode(room.payload!) as Map<String, dynamic>)['event_id'],
        r'$2',
      );
    });

    test('image previews use content URIs when media is on', () async {
      final image = File('${directory.path}/notification_media/m.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await handler(
        (_, _) async => resolved(text: 'Image', imagePath: image.path),
      ).handle(envelope());
      final message = style(
        surface.byId(roomNotificationId('!room:example.org'))!,
      ).messages!.single;
      expect(message.dataMimeType, 'image/jpeg');
      expect(message.dataUri, 'content://test${image.path}');

      surface.shown.clear();
      await store.writePreferences(
        const NotificationPreferences(showMediaPreviews: false),
      );
      await handler(
        (_, _) async =>
            resolved(eventId: r'$2', text: 'Image', imagePath: image.path),
      ).handle(envelope(r'$2'));
      final messages = style(
        surface.byId(roomNotificationId('!room:example.org'))!,
      ).messages!;
      expect(messages.every((m) => m.dataUri == null), isTrue);
    });

    test('ringing calls and invites get their own notifications', () async {
      await handler(
        (_, _) async => resolved(
          text: 'Incoming call',
          kind: NotifiableEventKind.call,
          ringing: true,
          isDirect: true,
        ),
      ).handle(envelope());
      final call = surface.byId(callNotificationId('!room:example.org'))!;
      expect(android(call).category, AndroidNotificationCategory.call);
      expect(android(call).importance, Importance.max);
      expect(android(call).channelId, callChannelId);
      expect(android(call).visibility, NotificationVisibility.private);
      expect(
        (jsonDecode(call.payload!) as Map<String, dynamic>)['room_id'],
        '!room:example.org',
      );

      await handler(
        (_, _) async => resolved(
          text: 'Alice invited you to Book club',
          kind: NotifiableEventKind.invite,
        ),
      ).handle(envelope());
      final invite = surface.byId(inviteNotificationId('!room:example.org'))!;
      expect(invite.body, 'Alice invited you to Book club');
      expect({
        roomNotificationId(room),
        callNotificationId(room),
        inviteNotificationId(room),
        notificationSummaryId,
        1001,
      }, hasLength(5));
    });
  });

  group('fallback', () {
    test(
      'content off shows the generic notification without fetching',
      () async {
        await store.writePreferences(
          const NotificationPreferences(showContent: false),
        );
        var fetched = false;
        final outcome = await handler((_, _) async {
          fetched = true;
          return resolved();
        }).handle(envelope());
        expect(outcome, RichPushOutcome.generic);
        expect(fetched, isFalse);
        expect(surface.generic.single.roomId, room);
        expect(surface.shown, isEmpty);
      },
    );

    test('fetch or decrypt failure shows the generic notification', () async {
      final outcome = await handler(
        (_, _) async => throw StateError('no keys'),
      ).handle(envelope());
      expect(outcome, RichPushOutcome.generic);
      expect(surface.generic, hasLength(1));
    });

    test('live-location beacons and call membership never notify', () async {
      expect(silentPushEventTypes, contains('org.matrix.msc3672.beacon'));
      expect(silentPushEventTypes, contains('m.call.member'));
      final outcome = await handler(
        (_, _) async => throw const SilentPushEvent(),
      ).handle(envelope());
      expect(outcome, RichPushOutcome.skipped);
      expect(surface.generic, isEmpty);
      expect(surface.shown, isEmpty);
    });

    test('a slow fetch times out into the generic notification', () async {
      final never = Completer<ResolvedPushEvent?>();
      final outcome = await handler(
        (_, _) => never.future,
        timeout: const Duration(milliseconds: 20),
      ).handle(envelope());
      expect(outcome, RichPushOutcome.generic);
      expect(surface.generic, hasLength(1));
    });

    test(
      'a failing plugin post falls back to the generic notification',
      () async {
        surface.failShow = true;
        final outcome = await handler(
          (_, _) async => resolved(),
        ).handle(envelope());
        expect(outcome, RichPushOutcome.generic);
        expect(surface.generic, hasLength(1));
      },
    );

    test('a mismatched resolution is not trusted', () async {
      final outcome = await handler(
        (_, _) async => resolved(eventId: r'$other'),
      ).handle(envelope());
      expect(outcome, RichPushOutcome.generic);
    });

    test('push without an event stays generic', () async {
      final outcome = await handler(
        (_, _) async => resolved(),
      ).handle(const PushEnvelope(registrationId: registration, roomId: room));
      expect(outcome, RichPushOutcome.generic);
    });

    test(
      'an unreadable store still shows rich content without history',
      () async {
        final file = File('${directory.path}/blocker')..writeAsStringSync('x');
        final broken = NotificationStore(Directory('${file.path}/sub'));
        final outcome = await handler(
          (_, _) async => resolved(),
          overrideStore: broken,
        ).handle(envelope());
        expect(outcome, RichPushOutcome.rich);
        expect(surface.byId(roomNotificationId(room))!.title, 'Book club');
      },
    );

    test('stale sessions and rebinding post nothing', () async {
      expect(
        await handler(
          (_, _) async => resolved(),
          isCurrent: () => false,
        ).handle(envelope()),
        RichPushOutcome.skipped,
      );
      expect(
        await handler(
          (_, _) async => throw StateError('x'),
          confirm: () async => false,
        ).handle(envelope()),
        RichPushOutcome.skipped,
      );
      expect(surface.shown, isEmpty);
      expect(surface.generic, isEmpty);
    });

    test('already read events clear the room notification', () async {
      await handler((_, _) async => resolved()).handle(envelope());
      final outcome = await handler(
        (_, _) async => null,
      ).handle(envelope(r'$2'));
      expect(outcome, RichPushOutcome.seen);
      expect(surface.cancelled, contains(roomNotificationId(room)));
      expect(surface.cancelled, contains(notificationSummaryId));
      expect(
        await store.threads(
          notificationAccountKey('@me:example.org', 'DEVICE'),
        ),
        isEmpty,
      );
    });

    test('the room being viewed is not notified', () async {
      final outcome = await handler(
        (_, _) async => resolved(),
        suppress: (roomId) => roomId == room,
      ).handle(envelope());
      expect(outcome, RichPushOutcome.skipped);
      expect(surface.shown, isEmpty);
    });
  });

  group('quick reply', () {
    test('the reply is appended as Me without alerting again', () async {
      final h = handler((_, _) async => resolved());
      await h.handle(envelope());
      surface.shown.clear();
      await h.showReplyResult(room, 'On my way', registrationId: registration);
      final updated = surface.byId(roomNotificationId(room))!;
      final messages = style(updated).messages!;
      expect(messages.last.text, 'On my way');
      expect(messages.last.person!.name, 'Me');
      expect(android(updated).onlyAlertOnce, isTrue);
      expect(android(updated).silent, isTrue);
    });

    test('failures add a status line; unknown rooms still get one', () async {
      final h = handler((_, _) async => resolved());
      await h.handle(envelope());
      await h.showReplyResult(
        room,
        'On my way',
        registrationId: registration,
        appendReply: false,
        statusLine: quickReplyFailedLine,
      );
      expect(
        style(surface.byId(roomNotificationId(room))!).messages!.last.text,
        quickReplyFailedLine,
      );
      await h.showReplyResult(
        '!unknown:example.org',
        'hi',
        registrationId: registration,
        statusLine: quickReplyPendingLine,
      );
      expect(
        surface.byId(roomNotificationId('!unknown:example.org'))!.body,
        quickReplyPendingLine,
      );
    });
  });

  test('clearing rooms and everything', () async {
    final h = handler((_, _) async => resolved());
    await h.handle(envelope());
    await h.clearRooms([room]);
    expect(
      surface.cancelled,
      containsAll([
        roomNotificationId(room),
        callNotificationId(room),
        inviteNotificationId(room),
        notificationSummaryId,
      ]),
    );
    await handler(
      (_, _) async => resolved(eventId: r'$2'),
    ).handle(envelope(r'$2'));
    surface.cancelled.clear();
    await h.clearAll();
    expect(surface.cancelled, contains(roomNotificationId(room)));
    expect(
      await store.threads(notificationAccountKey('@me:example.org', 'DEVICE')),
      isEmpty,
    );
  });
}
