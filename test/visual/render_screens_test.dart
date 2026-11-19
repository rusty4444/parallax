// Visual QA harness. Skipped unless PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/visual
// Writes PNGs of key screens with the bundled font so theme changes can be
// reviewed without a device. Not a golden test: nothing is asserted on pixels.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:parallax/features/platform/desktop_content_insets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/login_screen.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/two_pane.dart';

import '../widget_test.dart' show FakeBackend;

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
  await tester.pumpWidget(RepaintBoundary(key: key, child: child));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// Desktop-sized capture (1440x900 @1x) with an optional interaction before
/// the shot, for the tablet/foldable/Mac two-pane layout.
Future<void> _shootWide(
  WidgetTester tester,
  String name,
  Widget child, {
  Size size = const Size(1440, 900),
  Future<void> Function(WidgetTester)? interact,
}) async {
  final key = GlobalKey();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: key, child: child));
  await tester.pump(const Duration(milliseconds: 400));
  if (interact != null) {
    await interact(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

FakeBackend _backend() => FakeBackend()
  ..currentUserId = '@sam:example.org'
  ..roomList = [
    ChatRoom(
      id: '!a:example.org',
      name: 'Weekend crew',
      preview: 'Mia: Sunset at the pier?',
      lastActivity: DateTime.now(),
      unread: 3,
      encrypted: true,
    ),
    ChatRoom(
      id: '!b:example.org',
      name: 'Alex Rivera',
      preview: 'See you soon',
      lastActivity: DateTime.now().subtract(const Duration(hours: 2)),
      isDirect: true,
      encrypted: true,
    ),
    ChatRoom(
      id: '!c:example.org',
      name: 'Matrix HQ',
      preview: 'Welcome to the room',
      lastActivity: DateTime.now().subtract(const Duration(days: 2)),
    ),
    const ChatRoom(
      id: '!d:example.org',
      name: 'Design review',
      preview: '',
      lastActivity: null,
      invited: true,
    ),
  ]
  ..entries = [
    ChatEntry(
      id: r'$3',
      sender: '@sam:example.org',
      body: 'Absolutely — I will bring the camera.',
      time: DateTime.now(),
      mine: true,
    ),
    ChatEntry(
      id: r'$2',
      sender: '@mia:example.org',
      body: 'Sunset at the pier this Saturday?',
      time: DateTime.now().subtract(const Duration(minutes: 3)),
      mine: false,
      reactions: const [ChatReaction(emoji: '🔥', count: 2, mine: true)],
    ),
    ChatEntry(
      id: r'$1',
      sender: '@alex:example.org',
      body: 'Who is around this weekend?',
      time: DateTime.now().subtract(const Duration(minutes: 9)),
      mine: false,
    ),
  ];

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR to render' : null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);
    testWidgets('login ${style.name}', skip: skip != null, (tester) async {
      await _shoot(
        tester,
        'login_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: LoginScreen(backend: _backend(), palette: p),
        ),
      );
    });

    testWidgets('inbox ${style.name}', skip: skip != null, (tester) async {
      await _shoot(
        tester,
        'inbox_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: InboxScreen(
            backend: _backend(),
            palette: p,
            style: style,
            onThemeChanged: (_) {},
          ),
        ),
      );
    });

    testWidgets('room ${style.name}', skip: skip != null, (tester) async {
      final backend = _backend();
      await _shoot(
        tester,
        'room_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: RoomScreen(
            backend: backend,
            palette: p,
            roomId: '!a:example.org',
          ),
        ),
      );
    });

    for (final width in [700.0, 1440.0]) {
      testWidgets(
        'two-pane desktop ${style.name} ${width.toInt()}',
        skip: skip != null,
        (tester) async {
          final observer = RoomRouteObserver();
          await _shootWide(
            tester,
            'two_pane_${defaultTargetPlatform.name}_${style.name}_${width.toInt()}',
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: themeFor(style),
              builder: (_, child) => DesktopContentInsets(child: child!),
              navigatorObservers: [observer],
              home: InboxScreen(
                backend: _backend(),
                palette: p,
                style: style,
                onThemeChanged: (_) {},
                roomRoutes: observer,
              ),
            ),
            size: Size(width, 900),
            interact: (t) async {
              await t.tap(find.text('Weekend crew'));
              await t.pump(const Duration(milliseconds: 300));
            },
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.macOS,
          TargetPlatform.android,
        }),
      );
    }
  }
}
