// Visual QA for the room administration screens. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set (see test/visual/render_screens_test.dart):
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/rooms_admin_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/rooms_admin/create_room_screen.dart';
import 'package:parallax/features/rooms_admin/roles_permissions_screen.dart';
import 'package:parallax/features/rooms_admin/room_members_screen.dart';
import 'package:parallax/features/rooms_admin/security_privacy_screen.dart';
import 'package:parallax/features/rooms_admin/start_chat_screen.dart';
import 'package:parallax/features/rooms_admin/user_profile_screen.dart';
import 'package:parallax/room_details_screen.dart';

import 'rooms_admin_fakes.dart';

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

  AdminBackend backend() => AdminBackend()
    ..details = adminDetails(joinRule: 'knock', knock: true, encrypted: true);

  final screens = <String, Widget Function()>{
    'rooms_admin_details': () =>
        RoomDetailsScreen(backend: backend(), palette: palette, roomId: roomId),
    'rooms_admin_members': () =>
        RoomMembersScreen(backend: backend(), palette: palette, roomId: roomId),
    'rooms_admin_security': () => SecurityPrivacyScreen(
      backend: AdminBackend()..details = adminDetails(joinRule: 'public'),
      palette: palette,
      roomId: roomId,
    ),
    'rooms_admin_roles': () => RolesPermissionsScreen(
      backend: backend(),
      palette: palette,
      roomId: roomId,
    ),
    'rooms_admin_profile': () => UserProfileScreen(
      backend: backend(),
      palette: palette,
      userId: guest,
      roomId: roomId,
    ),
    'rooms_admin_start_chat': () =>
        StartChatScreen(backend: backend(), palette: palette),
    'rooms_admin_create_room': () =>
        CreateRoomScreen(backend: backend(), palette: palette),
  };
  for (final MapEntry(key: name, value: build) in screens.entries) {
    testWidgets(name, skip: skip, (tester) async {
      await _shoot(tester, name, build());
    });
  }
}
