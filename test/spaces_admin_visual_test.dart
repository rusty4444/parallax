// Visual QA for the Space administration screens. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set (see test/visual/render_screens_test.dart):
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/spaces_admin_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/rooms_admin/security_privacy_screen.dart';
import 'package:parallax/features/spaces_admin/add_rooms_to_space_screen.dart';
import 'package:parallax/features/spaces_admin/create_space_screen.dart';
import 'package:parallax/features/spaces_admin/leave_space_screen.dart';
import 'package:parallax/features/spaces_admin/manage_authorised_spaces_screen.dart';
import 'package:parallax/features/spaces_admin/manage_space_screen.dart';
import 'package:parallax/features/spaces_admin/spaces_admin_models.dart';
import 'package:parallax/room_details_screen.dart';

import 'rooms_admin_fakes.dart';
import 'spaces_admin_fakes.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];

Future<void> _loadFonts() async {
  final grotesk = FontLoader('SpaceGrotesk')
    ..addFont(
      File(
        'assets/fonts/SpaceGrotesk.ttf',
      ).readAsBytes().then((b) => ByteData.sublistView(b)),
    );
  await grotesk.load();
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(icons.readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
  }
}

Future<void> _shoot(WidgetTester tester, String name, Widget child) async {
  final key = GlobalKey();
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: themeFor(VisualTheme.parallax),
        home: child,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  final skip = _dir == null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  SpacesBackend backend() => SpacesBackend()
    ..plan = LeaveSpacePlan(
      spaceId: spaceId,
      spaceName: 'Team',
      details: spaceDetails(),
      lastAdmin: false,
      rooms: const [
        LeaveSpaceRoom(id: general, name: 'General', members: 4),
        LeaveSpaceRoom(id: random, name: 'Random', members: 2),
        LeaveSpaceRoom(id: ops, name: 'Ops', members: 3, lastAdmin: true),
      ],
    );

  final screens = <String, Widget Function()>{
    'spaces_admin_new_space': () =>
        CreateSpaceScreen(backend: backend(), palette: palette),
    'spaces_admin_new_room_in_space': () => CreateSpaceScreen(
      backend: backend(),
      palette: palette,
      parentSpaceId: spaceId,
      parentSpaceName: 'Team',
    ),
    'spaces_admin_manage_rooms': () => ManageSpaceScreen(
      backend: backend(),
      palette: palette,
      spaceId: spaceId,
    ),
    'spaces_admin_add_rooms': () => AddRoomsToSpaceScreen(
      backend: backend(),
      palette: palette,
      spaceId: spaceId,
      skippable: true,
    ),
    'spaces_admin_leave': () => LeaveSpaceScreen(
      backend: backend(),
      palette: palette,
      spaceId: spaceId,
    ),
    'spaces_admin_settings': () => RoomDetailsScreen(
      backend: backend(),
      palette: palette,
      roomId: spaceId,
    ),
    'spaces_admin_security': () => SecurityPrivacyScreen(
      backend: backend()
        ..authorised = const AuthorisedSpaces(
          selectable: [
            SpaceRef(id: spaceId, name: 'Team'),
            SpaceRef(id: club, name: 'Club'),
          ],
          unknown: [],
        ),
      palette: palette,
      roomId: roomId,
    ),
    'spaces_admin_authorised': () => ManageAuthorisedSpacesScreen(
      backend: backend(),
      palette: palette,
      spaces: const AuthorisedSpaces(
        selectable: [
          SpaceRef(id: spaceId, name: 'Team'),
          SpaceRef(id: club, name: 'Club'),
        ],
        unknown: ['!elsewhere:example.org'],
      ),
      initial: const [spaceId],
    ),
  };
  for (final MapEntry(key: name, value: build) in screens.entries) {
    testWidgets(name, skip: skip, (tester) async {
      await _shoot(tester, name, build());
    });
  }
}
