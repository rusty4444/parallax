import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rooms_admin/knock_requests_screen.dart';
import 'package:parallax/features/rooms_admin/leave_room.dart';
import 'package:parallax/features/rooms_admin/report_room_screen.dart';
import 'package:parallax/features/rooms_admin/roles_permissions_screen.dart';
import 'package:parallax/features/rooms_admin/room_members_screen.dart';
import 'package:parallax/features/rooms_admin/room_notifications_screen.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_hooks.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_models.dart';
import 'package:parallax/features/rooms_admin/security_privacy_screen.dart';
import 'package:parallax/features/rooms_admin/share_text.dart';
import 'package:parallax/features/rooms_admin/user_profile_screen.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/room_details_screen.dart';
import 'package:parallax/room_screen.dart';

import 'rooms_admin_fakes.dart';

void main() {
  final shared = <String>[];
  setUp(() {
    shared.clear();
    shareText = (text, {subject}) async => shared.add(text);
  });

  group('room details', () {
    testWidgets('header, quick actions and admin sections', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..details = adminDetails(joinRule: 'knock', knock: true);
      await tester.pumpWidget(
        app(
          RoomDetailsScreen(backend: backend, palette: palette, roomId: roomId),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Project room'), findsOneWidget);
      expect(find.text('#project:example.org'), findsOneWidget);
      expect(find.text('2 people'), findsOneWidget);
      expect(find.text('Not encrypted'), findsOneWidget);
      await scrollTo(tester, find.text('Default · All messages'));
      expect(find.text('Default · All messages'), findsOneWidget);
      for (final label in [
        'People',
        'Requests to join',
        'Roles & permissions',
        'Security & privacy',
        'Report room',
        'Leave room',
      ]) {
        await scrollTo(tester, find.text(label));
        expect(find.text(label), findsOneWidget, reason: label);
      }

      await tester.drag(find.byType(ListView), const Offset(0, 2000));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();
      expect(shared, ['https://matrix.to/#/%23project:example.org']);

      await tester.tap(find.byTooltip('Favourite'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('favourite:true'));
      expect(find.byTooltip('Unfavourite'), findsOneWidget);

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('notify:mute'));
      expect(find.byTooltip('Unmute'), findsOneWidget);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'notify:null');
    });

    testWidgets('members can only see permitted sections', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()..details = adminDetails(myPower: 0);
      await tester.pumpWidget(
        app(
          RoomDetailsScreen(backend: backend, palette: palette, roomId: roomId),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Roles & permissions'), findsNothing);
      expect(find.text('Security & privacy'), findsNothing);
      expect(find.byTooltip('Edit details'), findsNothing);
      expect(find.byTooltip('Invite'), findsOneWidget); // invite level 0
    });

    testWidgets('leaving as the last admin warns and offers admins', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend();
      final launcher = Launcher<void>();
      await tester.pumpWidget(
        launcher.build(
          (context) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RoomDetailsScreen(
                backend: backend,
                palette: palette,
                roomId: roomId,
              ),
            ),
          ),
        ),
      );
      await launcher.launch(tester);
      await scrollTo(tester, find.text('Leave room'));
      await tester.tap(find.text('Leave room'));
      await tester.pumpAndSettle();
      expect(
        find.text(leaveWarningText(LeaveWarning.lastAdmin)),
        findsOneWidget,
      );
      expect(find.text('Choose admins'), findsOneWidget);
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('leave:$roomId'));
      expect(find.byType(RoomDetailsScreen), findsNothing);
    });
  });

  testWidgets('members screen moderates with a reason', (tester) async {
    tallScreen(tester);
    final backend = AdminBackend();
    await tester.pumpWidget(
      app(
        RoomMembersScreen(backend: backend, palette: palette, roomId: roomId),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Me (you)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'gue');
    await tester.pumpAndSettle();
    expect(find.text('Me (you)'), findsNothing);
    await tester.tap(find.byTooltip('Moderate $guest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ban user'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Spam');
    await tester.tap(find.text('Ban'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('ban:$guest:Spam'));
    await tester.enterText(find.byType(TextField).first, 'nobody');
    await tester.pumpAndSettle();
    expect(find.text('No results for “nobody”'), findsOneWidget);
  });

  testWidgets('notification settings switch between default and custom', (
    tester,
  ) async {
    tallScreen(tester);
    final backend = AdminBackend();
    await tester.pumpWidget(
      app(
        RoomNotificationsScreen(
          backend: backend,
          palette: palette,
          roomId: roomId,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('All messages'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'notify:allMessages');
    await tester.tap(find.text('Mute'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'notify:mute');
    await tester.tap(find.text('Remove custom setting'));
    await tester.pumpAndSettle();
    expect(backend.calls.last, 'notify:null');
    expect(find.text('Default setting'.toUpperCase()), findsOneWidget);
  });

  testWidgets('security & privacy writes each setting', (tester) async {
    tallScreen(tester);
    final backend = AdminBackend()
      ..details = adminDetails(joinRule: 'public', alias: null);
    await tester.pumpWidget(
      app(
        SecurityPrivacyScreen(
          backend: backend,
          palette: palette,
          roomId: roomId,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask to join'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('joinRule:knock'));

    // Directory listing needs an address first.
    final directory = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Visible in public directory'),
    );
    expect(directory.onChanged, isNull);
    await tester.tap(find.text('Add address'));
    await tester.pumpAndSettle();
    expect(find.text('project-room'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'bad:value');
    await tester.pumpAndSettle();
    expect(find.text('Not a valid address'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'projects');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('address:projects'));

    await scrollTo(tester, find.text('Enable end-to-end encryption'));
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Enable end-to-end encryption'),
    );
    await tester.pumpAndSettle();
    expect(backend.calls, isNot(contains('encryption')));
    await tester.tap(find.text('Yes, enable encryption'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('encryption'));

    await scrollTo(tester, find.text('Members since invited'));
    await tester.tap(find.text('Members since invited'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('history:invited'));
  });

  testWidgets('roles: edit admins, permissions and reset', (tester) async {
    tallScreen(tester);
    final backend = AdminBackend();
    await tester.pumpWidget(
      app(
        RolesPermissionsScreen(
          backend: backend,
          palette: palette,
          roomId: roomId,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Admins'));
    await tester.pumpAndSettle();
    expect(find.byType(ChangeRolesScreen), findsOneWidget);
    await tester.tap(find.text('Guest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Add Admin?'), findsOneWidget);
    await tester.tap(find.text('Add Admin'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('levels:{$guest: 100}'));

    await scrollTo(tester, find.text('Invite people'));
    await tester.tap(find.text('Invite people'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Moderator'),
      ),
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('permission:invite:50'));

    await scrollTo(tester, find.text('Reset permissions'));
    await tester.tap(find.text('Reset permissions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('resetPermissions'));
  });

  group('knock requests', () {
    testWidgets('list accepts and declines with a reason', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..details = adminDetails(joinRule: 'knock', knock: true);
      await tester.pumpWidget(
        app(
          KnockRequestsScreen(
            backend: backend,
            palette: palette,
            roomId: roomId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Please let me in'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('accept:$knocker'));
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Not now');
      await tester.tap(find.text('Yes, decline'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('declineKnock:$knocker:false:Not now'));
    });

    testWidgets('room banner shows pending requests to moderators', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..details = adminDetails(joinRule: 'knock', knock: true);
      final ctx = RoomHookContext(
        backend: backend,
        roomId: roomId,
        palette: palette,
      );
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: Column(children: roomsAdminRoomBanners(context, ctx)),
            ),
          ),
        ),
      );
      expect(find.text('Knocker wants to join this room'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('accept:$knocker'));
      expect(find.text('Knocker wants to join this room'), findsNothing);

      backend.details = adminDetails(
        joinRule: 'knock',
        knock: true,
        myPower: 0,
        levels: {
          'users': {me: 0},
          'invite': 50,
          'kick': 50,
        },
      );
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: roomsAdminRoomBanners(
                  context,
                  RoomHookContext(
                    backend: backend,
                    roomId: '$roomId-other',
                    palette: palette,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('wants to join'), findsNothing);
    });
  });

  group('report room', () {
    testWidgets('unsupported servers explain the gap', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()..reportSupported = false;
      await tester.pumpWidget(
        app(
          ReportRoomScreen(
            backend: backend,
            palette: palette,
            details: backend.details,
          ),
        ),
      );
      final report = find.widgetWithText(FilledButton, 'Report');
      expect(tester.widget<FilledButton>(report).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Abuse');
      await tester.pump();
      await tester.tap(report);
      await tester.pumpAndSettle();
      expect(find.textContaining('doesn’t support reporting'), findsOneWidget);
    });

    testWidgets('report then leave', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend();
      await tester.pumpWidget(
        app(
          ReportRoomScreen(
            backend: backend,
            palette: palette,
            details: backend.details,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Abuse');
      await tester.tap(find.text('Leave room'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Report'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['report:Abuse', 'leave:$roomId']);
    });
  });

  group('user profile', () {
    testWidgets('verify, block and change role in room context', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend();
      await tester.pumpWidget(
        app(
          UserProfileScreen(
            backend: backend,
            palette: palette,
            userId: guest,
            roomId: roomId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Guest'), findsOneWidget);
      expect(find.text('Not verified'), findsOneWidget);
      await tester.tap(find.text('Verify Guest'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('verify:$guest'));

      await tester.tap(find.text('Block user'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('ignore:$guest:true'));
      expect(find.text('Unblock user'), findsOneWidget);

      await scrollTo(tester, find.text('Role'));
      await tester.tap(find.text('Role'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Moderator'),
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('levels:{$guest: 50}'));

      await scrollTo(tester, find.text('Remove from room'));
      await tester.tap(find.text('Remove from room'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('kick:$guest:'));
    });

    testWidgets('message opens an existing DM above the home route', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend()..dms[guest] = '!dm:example.org';
      final launcher = Launcher<void>();
      await tester.pumpWidget(
        launcher.build(
          (context) => openUserProfile(context, backend, palette, guest),
        ),
      );
      await launcher.launch(tester);
      expect(find.byType(UserProfileScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Message'));
      await tester.pumpAndSettle();
      final room = tester.widget<RoomScreen>(find.byType(RoomScreen));
      expect(room.roomId, '!dm:example.org');
      expect(find.byType(UserProfileScreen), findsNothing);
    });

    testWidgets('own profile hides message and block', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend();
      await tester.pumpWidget(
        app(UserProfileScreen(backend: backend, palette: palette, userId: me)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Message'), findsNothing);
      expect(find.text('Block user'), findsNothing);
    });
  });

  group('start chat', () {
    testWidgets('typed Matrix ID starts a confirmed DM', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend();
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build((context) => openStartChat(context, backend, palette)),
      );
      await launcher.launch(tester);
      expect(startChatAvailable, isTrue);
      for (final label in [
        'New room',
        'Join room by address',
        'Room directory',
        'Invite people to Parallax',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('Invite people to Parallax'));
      await tester.pumpAndSettle();
      expect(shared.single, contains('https://matrix.to/#/@me:example.org'));

      await tester.enterText(find.byType(TextField), '@new:example.org');
      await tester.pumpAndSettle();
      await tester.tap(find.text('@new:example.org').last);
      await tester.pumpAndSettle();
      expect(find.text('Start a chat with @new:example.org?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Start chat'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('dm:@new:example.org'));
      expect(launcher.done, isTrue);
      expect(launcher.result, '!dm-@new:example.org');
    });

    testWidgets('directory result with an existing DM reopens it', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..directory = const [DirectoryUser(id: guest, name: 'Guest')]
        ..dms[guest] = '!dm:example.org';
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build((context) => openStartChat(context, backend, palette)),
      );
      await launcher.launch(tester);
      await tester.enterText(find.byType(TextField), 'gue');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guest'));
      await tester.pumpAndSettle();
      expect(launcher.result, '!dm:example.org');
      expect(backend.calls, isNot(contains('dm:$guest')));
    });

    testWidgets('join by address previews, joins and knocks', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..previews['#club:example.org'] = const RoomPreview(
          roomId: '!club:example.org',
          name: 'Club',
          memberCount: 12,
          joinRule: 'public',
          alias: '#club:example.org',
        )
        ..previews['#vip:example.org'] = const RoomPreview(
          roomId: '!vip:example.org',
          name: 'VIP',
          joinRule: 'knock',
        );
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build((context) => openStartChat(context, backend, palette)),
      );
      await launcher.launch(tester);
      await tester.tap(find.text('Join room by address'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'club');
      await tester.pumpAndSettle();
      expect(find.text('Not a valid address'), findsWidgets);
      await tester.enterText(find.byType(TextField), '#vip:example.org');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('Matching room found'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Hello');
      await tester.tap(find.text('Send request to join'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('knock:!vip:example.org:Hello'));
      expect(find.text('Request to join sent'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '#club:example.org');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.textContaining('12 members'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Join'));
      await tester.pumpAndSettle();
      expect(launcher.result, '!club:example.org');
    });

    testWidgets('new public room creates once then offers invites', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend();
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build((context) => openStartChat(context, backend, palette)),
      );
      await launcher.launch(tester);
      await tester.tap(find.text('New room'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Room name'),
        'Book Club',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public'));
      await tester.pumpAndSettle();
      expect(find.text('book-club'), findsOneWidget);
      await scrollTo(tester, find.text('Create room'));
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c.startsWith('create:')), [
        'create:Book Club',
      ]);
      expect(backend.created?.isPublic, isTrue);
      expect(backend.created?.aliasLocalpart, 'book-club');
      expect(backend.created?.encrypted, isFalse);
      expect(find.text('Invite people'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(launcher.result, '!created:example.org');
    });

    testWidgets('definite failure allows a corrected create', (tester) async {
      tallScreen(tester);
      final backend = AdminBackend()
        ..createFailure = const RoomCreationFailure.notSubmitted(
          'That room address is already taken. Choose another address.',
        );
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build((context) => openStartChat(context, backend, palette)),
      );
      await launcher.launch(tester);
      await tester.tap(find.text('New room'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Room name'),
        'Family',
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Create room'));
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();
      expect(find.text('Room not created'), findsOneWidget);
      expect(backend.created?.encrypted, isTrue);
      backend.createFailure = null;
      await scrollTo(tester, find.text('Create room'));
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();
      expect(find.text('Invite people'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(launcher.result, '!created:example.org');
    });
  });

  group('message actions', () {
    ChatEntry entry({bool mine = false, String id = r'$event'}) => ChatEntry(
      id: id,
      sender: mine ? me : guest,
      body: 'Hello',
      time: DateTime(2026),
      mine: mine,
    );

    testWidgets('moderators remove others’ messages with a reason', (
      tester,
    ) async {
      tallScreen(tester);
      final backend = AdminBackend();
      late List<MessageActionItem> actions;
      late BuildContext captured;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              captured = context;
              actions = roomsAdminMessageActions(
                context,
                EntryHookContext(
                  backend: backend,
                  roomId: roomId,
                  palette: palette,
                  entry: entry(),
                ),
              );
              return const Scaffold();
            },
          ),
        ),
      );
      expect(actions.single.id, 'rooms_admin.remove');
      final future = actions.single.onSelected(captured);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Off topic');
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await future;
      expect(backend.calls, contains(r'redact:$event:Off topic'));

      for (final hidden in [entry(mine: true), entry(id: 'local-txn')]) {
        expect(
          roomsAdminMessageActions(
            captured,
            EntryHookContext(
              backend: backend,
              roomId: roomId,
              palette: palette,
              entry: hidden,
            ),
          ),
          isEmpty,
        );
      }
      backend.details = adminDetails(myPower: 0);
      expect(
        roomsAdminMessageActions(
          captured,
          EntryHookContext(
            backend: backend,
            roomId: roomId,
            palette: palette,
            entry: entry(),
          ),
        ),
        isEmpty,
      );
    });
  });

  testWidgets('decline and block reports, blocks, then declines', (
    tester,
  ) async {
    tallScreen(tester);
    final backend = AdminBackend();
    final launcher = Launcher<bool>();
    await tester.pumpWidget(
      launcher.build(
        (context) => showDeclineAndBlock(context, backend, palette, roomId),
      ),
    );
    await launcher.launch(tester);
    expect(find.textContaining('@spammer:example.org'), findsOneWidget);
    await tester.tap(find.text('Report room'));
    await tester.pumpAndSettle();
    final decline = find.widgetWithText(FilledButton, 'Decline');
    expect(tester.widget<FilledButton>(decline).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Spam invites');
    await tester.pump();
    await tester.tap(decline);
    await tester.pumpAndSettle();
    expect(backend.calls, [
      'report:Spam invites',
      'ignore:@spammer:example.org:true',
      'decline:$roomId',
    ]);
    expect(launcher.result, isTrue);
  });
}
