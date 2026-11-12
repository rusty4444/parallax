// Widget tests for the Space administration screens with a fake backend
// implementing SpacesAdminFeatures (request shapes are covered by
// spaces_admin_matrix_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/home/space_switcher.dart';
import 'package:parallax/features/rooms_admin/security_privacy_screen.dart';
import 'package:parallax/features/rooms_admin/start_chat_screen.dart';
import 'package:parallax/features/spaces_admin/add_rooms_to_space_screen.dart';
import 'package:parallax/features/spaces_admin/create_space_screen.dart';
import 'package:parallax/features/spaces_admin/leave_space_screen.dart';
import 'package:parallax/features/spaces_admin/manage_space_screen.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_models.dart';
import 'package:parallax/room_details.dart';
import 'package:parallax/room_details_screen.dart';
import 'package:parallax/space_browser_screen.dart';

import 'rooms_admin_fakes.dart';
import 'spaces_admin_fakes.dart';

void main() {
  late SpacesBackend backend;

  setUp(() => backend = SpacesBackend());

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('create', () {
    testWidgets('New space creates once, then offers existing rooms', (
      tester,
    ) async {
      tall(tester);
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build(
          (context) => Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) =>
                  CreateSpaceScreen(backend: backend, palette: palette),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('New space'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Space name'),
        'Team HQ',
      );
      await tester.tap(find.text('Public'));
      await tester.pump();
      expect(find.text('Space address'), findsOneWidget);
      await tester.tap(find.text('Create space'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['createSpace:Team HQ:public:team-hq']);
      // Element X follows creation with "add rooms"; it can be skipped.
      expect(find.byType(AddRoomsToSpaceScreen), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(launcher.result, '!newspace:example.org');
    });

    testWidgets('New room in a Space defaults to Space members and links it', (
      tester,
    ) async {
      tall(tester);
      backend.failAdd.add('!newroom:example.org');
      final launcher = Launcher<String?>();
      await tester.pumpWidget(
        launcher.build(
          (context) => Navigator.of(context).push<String>(
            MaterialPageRoute(
              builder: (_) => CreateSpaceScreen(
                backend: backend,
                palette: palette,
                parentSpaceId: spaceId,
                parentSpaceName: 'Team',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('New room'), findsOneWidget);
      expect(find.text('Anyone in Team can join.'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Room name'),
        'General',
      );
      await tester.pump();
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();
      expect(backend.calls, [
        'createIn:$spaceId:General:spaceMembers',
        'add:$spaceId:!newroom:example.org:false',
      ]);
      // The room exists; only the link is retried, never the create.
      expect(
        find.text('It couldn’t be added to the space yet.'),
        findsOneWidget,
      );
      backend.failAdd.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        backend.calls.where((c) => c.startsWith('createIn')),
        hasLength(1),
      );
      expect(launcher.result, '!newroom:example.org');
    });

    testWidgets('Start chat offers New space', (tester) async {
      await tester.pumpWidget(
        app(StartChatScreen(backend: backend, palette: palette)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New space'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateSpaceScreen), findsOneWidget);
    });
  });

  group('children', () {
    testWidgets('Add rooms adds the selection and keeps failures', (
      tester,
    ) async {
      tall(tester);
      backend.failAdd.add(random);
      await tester.pumpWidget(
        app(
          AddRoomsToSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('General'));
      await tester.tap(find.text('Random'));
      await tester.tap(find.text('Suggest to space members'));
      await tester.pump();
      await tester.tap(find.text('Add 2 rooms'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['add:$spaceId:$general,$random:true']);
      expect(find.textContaining('Couldn’t add 1 room'), findsOneWidget);
      // General was added and disappears; Random stays selected for a retry.
      expect(find.text('General'), findsNothing);
      expect(find.text('Add 1 room'), findsOneWidget);
    });

    testWidgets('Manage rooms suggests, reorders and removes', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          ManageSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Add existing rooms'), findsOneWidget);
      expect(find.text('Create a new room'), findsOneWidget);
      expect(find.text('Suggested · 3 members'), findsOneWidget);

      await tester.tap(find.byTooltip('Options for Random'));
      await tester.pumpAndSettle();
      expect(find.text('Move down'), findsNothing);
      await tester.tap(find.text('Move up'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['move:$random:0']);

      await tester.tap(find.byTooltip('Options for General'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove suggestion'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'suggest:$general:false');

      await tester.tap(find.byTooltip('Options for General'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from space'));
      await tester.pumpAndSettle();
      expect(find.text('Remove General from Team?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'remove:$general');
      expect(find.text('General'), findsNothing);
    });

    testWidgets('members without permission see a read-only list', (
      tester,
    ) async {
      backend.space = spaceDetails(myPower: 0);
      await tester.pumpWidget(
        app(
          ManageSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('General'), findsOneWidget);
      expect(find.text('Add existing rooms'), findsNothing);
      expect(find.byTooltip('Options for General'), findsNothing);
      expect(find.textContaining('Only space admins'), findsOneWidget);
    });
  });

  group('leave', () {
    testWidgets('chooses which rooms to leave with the Space', (tester) async {
      tall(tester);
      backend.plan = leavePlanFor();
      final launcher = Launcher<bool?>();
      await tester.pumpWidget(
        launcher.build(
          (context) => Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => LeaveSpaceScreen(
                backend: backend,
                palette: palette,
                spaceId: spaceId,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch'));
      await tester.pumpAndSettle();
      expect(find.text('Leave Team?'), findsOneWidget);
      expect(find.text('Ops (Admin)'), findsOneWidget);
      expect(find.text('Leave 2 rooms and space'), findsOneWidget);
      await tester.tap(find.text('Random'));
      await tester.pump();
      await tester.tap(find.text('Leave 1 room and space'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['leaveSpace:$spaceId:$general']);
      expect(launcher.result, isTrue);
    });

    testWidgets('warns the last admin and offers Choose admins', (
      tester,
    ) async {
      tall(tester);
      backend.plan = leavePlanFor(lastAdmin: true);
      await tester.pumpWidget(
        app(
          LeaveSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('You are the only administrator for Team'),
        findsOneWidget,
      );
      expect(find.text('Choose admins'), findsOneWidget);
      await tester.tap(find.text('Deselect all'));
      await tester.pump();
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();
      expect(find.text('Leave anyway?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Leave anyway').last);
      await tester.pumpAndSettle();
      expect(backend.calls, ['leaveSpace:$spaceId:']);
    });

    testWidgets('a failed leave stays on screen and reloads', (tester) async {
      tall(tester);
      backend
        ..plan = leavePlanFor()
        ..leaveFailure = const LeaveSpaceFailure(random, [general]);
      await tester.pumpWidget(
        app(
          LeaveSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave 2 rooms and space'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t leave Random. Try again.'), findsOneWidget);
      expect(find.byType(LeaveSpaceScreen), findsOneWidget);
    });
  });

  group('authorised spaces', () {
    Future<void> pumpSecurity(WidgetTester tester) async {
      tall(tester);
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
    }

    testWidgets('one candidate Space is authorised directly', (tester) async {
      await pumpSecurity(tester);
      expect(find.text('Space members'), findsOneWidget);
      expect(find.text('Anyone in Team can join.'), findsOneWidget);
      await tester.tap(find.text('Space members'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['authorised:$spaceId:false']);
    });

    testWidgets('several candidates open Manage spaces', (tester) async {
      backend.authorised = const AuthorisedSpaces(
        selectable: [
          SpaceRef(id: spaceId, name: 'Team'),
          SpaceRef(id: club, name: 'Club'),
        ],
        unknown: ['!gone:example.org'],
      );
      await pumpSecurity(tester);
      expect(
        find.text('Anyone in authorised spaces can join.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Ask to join (space members join directly)'));
      await tester.pumpAndSettle();
      expect(find.text('Manage spaces'), findsOneWidget);
      expect(find.text('(Unknown space)'), findsOneWidget);
      await tester.tap(find.text('Club'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['authorised:$club:true']);
    });

    testWidgets('Space-member rooms manage and switch their allow list', (
      tester,
    ) async {
      backend.authorised = const AuthorisedSpaces(
        selectable: [
          SpaceRef(id: spaceId, name: 'Team'),
          SpaceRef(id: club, name: 'Club'),
        ],
        unknown: [],
      );
      backend.details = RoomDetails.fromState(
        roomId: roomId,
        userId: me,
        state: [
          const RoomStateEntry('m.room.create', '', {'room_version': '11'}, me),
          RoomStateEntry('m.room.power_levels', '', {
            'users': {me: 100},
          }, me),
          const RoomStateEntry('m.room.join_rules', '', {
            'join_rule': 'restricted',
            'allow': [
              {'type': 'm.room_membership', 'room_id': spaceId},
            ],
          }, me),
          memberState(me, 'join'),
        ],
      );
      await pumpSecurity(tester);
      expect(find.text('1 authorised space'), findsOneWidget);
      // Switching variant keeps the authorised Spaces.
      await tester.tap(find.text('Ask to join (space members join directly)'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['authorised:$spaceId:true']);

      await tester.tap(find.text('1 authorised space'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Club'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'authorised:$spaceId,$club:false');
    });

    testWidgets('a Space hides encryption and history', (tester) async {
      backend.details = spaceDetails();
      await pumpSecurity(tester);
      expect(find.text('Invite only'), findsOneWidget);
      expect(find.text('Enable end-to-end encryption'), findsNothing);
      expect(find.text('Who can read history'), findsNothing);
    });
  });

  group('Space settings and entry points', () {
    testWidgets('room details for a Space become Space settings', (
      tester,
    ) async {
      tall(tester);
      backend.plan = leavePlanFor();
      await tester.pumpWidget(
        app(
          RoomDetailsScreen(
            backend: backend,
            palette: palette,
            roomId: spaceId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Space settings'), findsOneWidget);
      expect(find.text('Space'), findsOneWidget);
      expect(find.text('Manage rooms'), findsOneWidget);
      expect(find.text('Security & privacy'), findsOneWidget);
      expect(find.text('Roles & permissions'), findsOneWidget);
      for (final hidden in [
        'Notifications',
        'Report room',
        'Favourite',
        'Mute',
        'Not encrypted',
      ]) {
        expect(find.text(hidden), findsNothing, reason: hidden);
      }
      await tester.tap(find.text('Manage rooms'));
      await tester.pumpAndSettle();
      expect(find.byType(ManageSpaceScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave space'));
      await tester.pumpAndSettle();
      expect(find.byType(LeaveSpaceScreen), findsOneWidget);
    });

    testWidgets('an ordinary room can be added to a Space', (tester) async {
      tall(tester);
      await tester.pumpWidget(
        app(
          RoomDetailsScreen(backend: backend, palette: palette, roomId: roomId),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Room info'), findsOneWidget);
      await tester.tap(find.text('Add to space'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Team'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('add:$spaceId:$roomId:false'));
      expect(find.text('Added to Team.'), findsOneWidget);
    });

    testWidgets('Space switcher long-press opens the Space menu', (
      tester,
    ) async {
      tall(tester);
      final options = <String>[];
      final selected = <String?>[];
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SpaceSwitcher(
              spaces: const [HomeSpace(id: spaceId, name: 'Team')],
              selected: spaceId,
              backend: backend,
              palette: palette,
              onSelected: selected.add,
              onOptions: (space) => options.add(space.id),
            ),
          ),
        ),
      );
      await tester.longPress(find.text('Team'));
      await tester.pumpAndSettle();
      expect(options, isEmpty);
      for (final item in [
        'Explore rooms',
        'Manage rooms',
        'Space settings',
        'Leave space',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      await tester.tap(find.text('Manage rooms'));
      await tester.pumpAndSettle();
      expect(find.byType(ManageSpaceScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      backend.plan = leavePlanFor();
      await tester.longPress(find.text('Team'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave space'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave 2 rooms and space'));
      await tester.pumpAndSettle();
      expect(backend.calls.last, 'leaveSpace:$spaceId:$general,$random');
      // The left Space is no longer the active filter.
      expect(selected, [null]);
    });

    testWidgets('Space switcher New space selects the new Space', (
      tester,
    ) async {
      tall(tester);
      final selected = <String?>[];
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SpaceSwitcher(
              spaces: const [HomeSpace(id: spaceId, name: 'Team')],
              selected: null,
              backend: backend,
              palette: palette,
              onSelected: selected.add,
              onOptions: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('New space'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Space name'),
        'Club',
      );
      await tester.pump();
      await tester.tap(find.text('Create space'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(selected, ['!newspace:example.org']);
    });

    testWidgets('Space browser offers New space and Space management', (
      tester,
    ) async {
      await tester.pumpWidget(app(SpaceBrowserScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(find.byTooltip('New space'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(SpaceBrowserScreen(backend: backend, spaceId: spaceId)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Manage rooms'));
      await tester.pumpAndSettle();
      expect(find.byType(ManageSpaceScreen), findsOneWidget);
    });
  });
}
