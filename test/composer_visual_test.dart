// Visual QA for the composer module. Skipped unless PARALLAX_SCREENSHOT_DIR
// is set (see test/visual/render_screens_test.dart):
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/composer_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/composer/chat_effects_overlay.dart';
import 'package:parallax/features/composer/chat_effects_preferences.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];

class _Backend extends ChatBackend {
  List<ChatEntry> entries = [];
  @override
  List<ChatEntry> get messages => entries;
  @override
  String? get activeRoomId => '!r:example.org';
  void update(List<ChatEntry> next) {
    entries = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _shoot(WidgetTester tester, GlobalKey key, String name) async {
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
    if (_dir == null) return;
    Directory(_dir!).createSync(recursive: true);
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
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    testWidgets('composer ${style.name}', skip: skip, (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = ChatEffectsPreferences(
        preferences: await SharedPreferences.getInstance(),
      );
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final p = paletteFor(style);
      final backend = _Backend()
        ..entries = [
          ChatEntry(
            id: 'old',
            sender: '@mia:example.org',
            body: 'history',
            time: DateTime(2020),
            mine: false,
          ),
        ];
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: p.background),
                        ChatEffectsOverlay(
                          backend: backend,
                          roomId: '!r:example.org',
                          preferences: preferences,
                          random: math.Random(3),
                        ),
                      ],
                    ),
                  ),
                  Material(
                    color: p.surface,
                    child: SafeArea(
                      child: RichMessageComposer(
                        controller: controller,
                        sending: false,
                        onSend: (_, _) async {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Text formatting'));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField),
        'Plans for **Saturday**:\n- <u>picnic</u> at the ~~pier~~ park\n'
        '- bring `snacks` and [the map](https://example.com)\n> sunset 🎉',
      );
      controller.selection = const TextSelection.collapsed(offset: 17);
      await tester.pump();
      backend.update([
        ...backend.entries,
        ChatEntry(
          id: 'new',
          sender: '@mia:example.org',
          body: 'Happy birthday',
          msgtype: 'nic.custom.confetti',
          time: DateTime.now(),
          mine: false,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      await _shoot(tester, key, 'composer_toolbar_${style.name}');

      await tester.enterText(find.byType(TextField), '/s');
      await tester.pump();
      await _shoot(tester, key, 'composer_commands_${style.name}');
      await tester.pumpAndSettle();
    });
  }
}
