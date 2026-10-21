import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/app_theme.dart';
import 'package:matrixpress/chat_backend.dart';
import 'package:matrixpress/room_details.dart';
import 'package:matrixpress/room_details_screen.dart';
import 'package:matrixpress/room_screen.dart';

import 'widget_test.dart' show FakeBackend;

const roomId = '!room:example.org';
const owner = '@owner:example.org';
const guest = '@guest:example.org';
const banned = '@banned:example.org';

RoomStateEntry member(String id, String membership, {String? name}) =>
    RoomStateEntry('m.room.member', id, {
      'membership': membership,
      'displayname': ?name,
    }, owner);

RoomDetails fixture({
  int ownerPower = 100,
  int guestPower = 0,
  String ownMembership = 'join',
  Map<String, Object?>? levels,
}) => RoomDetails.fromState(
  roomId: roomId,
  userId: owner,
  state: [
    const RoomStateEntry('m.room.create', '', {'room_version': '11'}, owner),
    const RoomStateEntry('m.room.name', '', {'name': 'Project room'}, owner),
    const RoomStateEntry('m.room.topic', '', {'topic': 'Announcements'}, owner),
    RoomStateEntry(
      'm.room.power_levels',
      '',
      levels ??
          {
            'users': {owner: ownerPower, guest: guestPower},
          },
      owner,
    ),
    member(owner, ownMembership),
    member(guest, 'join', name: 'Guest'),
    member(banned, 'ban'),
  ],
);

class DetailsBackend extends FakeBackend {
  DetailsBackend() {
    currentUserId = owner;
    roomList = const [
      ChatRoom(
        id: roomId,
        name: 'Project room',
        preview: '',
        lastActivity: null,
      ),
    ];
  }

  RoomDetails details = fixture();
  bool failRead = false;
  bool failWrite = false;
  int reads = 0;
  final writes = <String>[];
  Completer<RoomDetails>? pendingRead;

  @override
  Future<RoomDetails> getRoomDetails(String roomId) async {
    reads++;
    if (pendingRead case final future?) return future.future;
    if (failRead) throw StateError('Network unavailable');
    return details;
  }

  void write(String value) {
    if (failWrite) throw StateError('Forbidden');
    writes.add(value);
  }

  @override
  Future<void> editRoomName(String roomId, String name) async {
    write('name:$name');
    details = RoomDetails(
      roomId: roomId,
      name: name,
      topic: details.topic,
      members: details.members,
      permissions: details.permissions,
      ownPowerLevel: details.ownPowerLevel,
      canManage: details.canManage,
    );
  }

  @override
  Future<void> editRoomTopic(String roomId, String topic) async {
    write('topic:$topic');
    details = RoomDetails(
      roomId: roomId,
      name: details.name,
      topic: topic,
      members: details.members,
      permissions: details.permissions,
      ownPowerLevel: details.ownPowerLevel,
      canManage: details.canManage,
    );
  }

  @override
  Future<void> inviteToRoom(String roomId, String userId) async =>
      write('invite:$userId');

  @override
  Future<void> moderateRoomMember(
    String roomId,
    String userId,
    RoomAction action,
  ) async => write('${action.name}:$userId');
}

void main() {
  test(
    'invite ID validation accepts Matrix IPv6 and rejects malformed IDs',
    () {
      expect(isValidRoomInviteId('@alice:example.org'), isTrue);
      expect(isValidRoomInviteId('@alice:[::1]:8448'), isTrue);
      expect(isValidRoomInviteId('alice:example.org'), isFalse);
      expect(isValidRoomInviteId('@:example.org'), isFalse);
      expect(isValidRoomInviteId('@alice:example.org:bad'), isFalse);
    },
  );

  test(
    'state event overrides, defaults and target levels gate each action',
    () {
      final details = fixture(
        levels: {
          'users': {owner: 40, guest: 40},
          'state_default': 50,
          'events': {'m.room.name': 30, 'm.room.topic': 60},
          'invite': 50,
          'kick': 40,
          'ban': 40,
        },
      );
      final guestMember = details.members.firstWhere((m) => m.id == guest);
      final bannedMember = details.members.firstWhere((m) => m.id == banned);
      expect(details.can(RoomAction.name), isTrue);
      expect(details.can(RoomAction.topic), isFalse);
      expect(details.can(RoomAction.invite), isFalse);
      expect(details.can(RoomAction.kick, guestMember), isFalse); // equal power
      expect(details.can(RoomAction.ban, guestMember), isFalse);
      expect(details.can(RoomAction.unban, bannedMember), isTrue);
      expect(details.can(RoomAction.kick, bannedMember), isFalse);
      expect(details.can(RoomAction.ban, bannedMember), isFalse);
      expect(details.name, 'Project room');
      expect(details.topic, 'Announcements');
      expect(guestMember.name, 'Guest');
    },
  );

  test(
    'non-joined user is denied even with high power; v12 creator is owner',
    () {
      final left = fixture(ownMembership: 'leave');
      expect(left.can(RoomAction.name), isFalse);
      expect(left.can(RoomAction.invite), isFalse);
      final modern = RoomDetails.fromState(
        roomId: roomId,
        userId: owner,
        state: [
          const RoomStateEntry('m.room.create', '', {
            'room_version': '12',
          }, owner),
          const RoomStateEntry('m.room.power_levels', '', {
            'users': {owner: 0},
            'state_default': 50,
          }, owner),
          member(owner, 'join'),
        ],
      );
      expect(modern.can(RoomAction.name), isTrue);
      expect(modern.ownPowerLevel, 100);
      final missing = RoomDetails.fromState(
        roomId: roomId,
        userId: owner,
        state: [member(owner, 'join')],
      );
      expect(missing.can(RoomAction.ban), isFalse);
    },
  );

  testWidgets(
    'room entry opens server details; edit, invite and moderation write',
    (tester) async {
      final backend = DetailsBackend();
      final palette = paletteFor(VisualTheme.ultraviolet);
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.ultraviolet),
          home: RoomScreen(backend: backend, palette: palette, roomId: roomId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Room details'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomDetailsScreen), findsOneWidget);
      expect(find.text('Announcements'), findsOneWidget);
      expect(find.text('Guest'), findsOneWidget);
      expect(backend.reads, 1);

      await tester.tap(find.byTooltip('Edit room name'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'New name');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.writes, contains('name:New name'));
      expect(find.text('New name'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit room topic'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'New topic');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.writes, contains('topic:New topic'));

      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '@new:example.org');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.writes, contains('invite:@new:example.org'));

      await tester.tap(find.byTooltip('Moderate $guest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kick').last);
      await tester.pumpAndSettle();
      expect(backend.writes, isNot(contains('kick:$guest')));
      await tester.tap(find.text('Kick').last);
      await tester.pumpAndSettle();
      expect(backend.writes, contains('kick:$guest'));

      await tester.tap(find.byTooltip('Moderate $guest'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ban').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ban').last);
      await tester.pumpAndSettle();
      expect(backend.writes, contains('ban:$guest'));

      await tester.tap(find.byTooltip('Moderate $banned'));
      await tester.pumpAndSettle();
      expect(find.text('Unban'), findsWidgets);
      await tester.tap(find.text('Unban').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unban').last);
      await tester.pumpAndSettle();
      expect(backend.writes, contains('unban:$banned'));
    },
  );

  testWidgets('read failure and forbidden write remove stale controls', (
    tester,
  ) async {
    final backend = DetailsBackend();
    await tester.pumpWidget(
      MaterialApp(
        home: RoomDetailsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.ultraviolet),
          roomId: roomId,
        ),
      ),
    );
    await tester.pumpAndSettle();
    backend.failWrite = true;
    await tester.tap(find.byTooltip('Edit room name'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Denied');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    expect(find.textContaining('Couldn’t update room name'), findsOneWidget);
    expect(find.byTooltip('Edit room name'), findsNothing);
    backend.failWrite = false;
    backend.failRead = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn’t load room details'), findsOneWidget);
    expect(find.text('Invite'), findsNothing);
  });

  testWidgets(
    'permissions and loading block controls; invalid invite is local',
    (tester) async {
      final backend = DetailsBackend()..details = fixture(ownerPower: 0);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomDetailsScreen(
            backend: backend,
            palette: paletteFor(VisualTheme.ultraviolet),
            roomId: roomId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Edit room name'), findsNothing);
      expect(find.text('Invite'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'bad-id');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter a valid Matrix ID'), findsOneWidget);
      expect(backend.writes, isEmpty);
    },
  );
  testWidgets('server read must finish before controls appear', (tester) async {
    final backend = DetailsBackend()..pendingRead = Completer<RoomDetails>();
    await tester.pumpWidget(
      MaterialApp(
        home: RoomDetailsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.ultraviolet),
          roomId: roomId,
        ),
      ),
    );
    expect(find.byTooltip('Edit room name'), findsNothing);
    expect(find.text('Invite'), findsNothing);
    backend.pendingRead!.complete(backend.details);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit room name'), findsOneWidget);
  });
}
