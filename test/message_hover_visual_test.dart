// Visual QA for the desktop message hover menu. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/message_hover_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/quick_reaction_settings.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, roomId;
import 'widget_test.dart' show FakeBackgroundStore;

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
final _key = GlobalKey();

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

ChatEntry _msg(
  String id,
  String name,
  String body, {
  required bool mine,
  int minute = 0,
}) => ChatEntry(
  id: id,
  sender: '@${name.toLowerCase()}:example.org',
  senderName: name,
  body: body,
  time: DateTime(2026, 11, 20, 10, minute),
  mine: mine,
  content: {'msgtype': 'm.text', 'body': body},
);

FeaturesBackend _backend() => FeaturesBackend()
  ..currentUserId = '@me:example.org'
  ..entries = [
    _msg(r'$a', 'Riley', 'Right click and drag both work here.', mine: false),
    _msg(r'$b', 'Me', 'A nice extra, not urgent.', mine: true, minute: 11),
    _msg(r'$c', 'Riley', 'The hover bar looks right.', mine: false, minute: 12),
  ];

/// The room screen with the app's real theme, so text renders in Space
/// Grotesk instead of test-font blocks.
Widget _room(FeaturesBackend backend, Drafts drafts) => FeatureSettingsScope(
  preferences: AppearancePreferences(),
  draftStore: drafts,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: themeFor(VisualTheme.parallax),
    home: RoomScreen(
      backend: backend,
      palette: paletteFor(VisualTheme.parallax),
      roomId: roomId,
      draftStore: drafts,
      backgroundStore: FakeBackgroundStore(),
    ),
  ),
);

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    EmojiRecents.instance = EmojiRecents();
    QuickReactionSettings.instance = QuickReactionSettings();
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('render hover menu on ${platform.name}', (tester) async {
      if (_dir == null) return;
      tester.view
        ..physicalSize = const Size(1100, 760)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = _backend();
      // Restore the foundation override inside the body: the binding checks
      // its invariants before addTearDown runs.
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(
          RepaintBoundary(key: _key, child: _room(backend, Drafts())),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        await tester.pump();

        // Someone else's message: react, reply, thread, pin, more.
        await gesture.moveTo(
          tester.getCenter(find.text('The hover bar looks right.')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        await _shoot(tester, 'hover-incoming-${platform.name}');

        // An own message: the edit pencil appears too.
        await gesture.moveTo(
          tester.getCenter(find.text('A nice extra, not urgent.')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        await _shoot(tester, 'hover-own-${platform.name}');

        await gesture.removePointer();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
