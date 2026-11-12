// Visual QA for the home options menu and the composer layout. Skipped
// unless PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/home_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';
import 'home_options.dart';
import 'messaging_integration_test.dart' show Drafts, FeaturesBackend, roomId;
import 'widget_test.dart' show FakeBackgroundStore;

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
final _boundary = GlobalKey();

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

Future<void> _frame(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(key: _boundary, child: child));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

ChatRoom _room(
  String id,
  String name,
  String preview, {
  bool direct = false,
  int unread = 0,
  bool favourite = false,
  String? sender,
}) => ChatRoom(
  id: id,
  name: name,
  preview: preview,
  lastActivity: DateTime(2026, 11, 12, 17, 20),
  isDirect: direct,
  unread: unread,
  favourite: favourite,
  previewSender: sender,
);

HomeFakeBackend _homeBackend() => HomeFakeBackend()
  ..roomList = [
    _room(
      '!p:x',
      'Quinn Harper',
      '11605.jpg',
      direct: true,
      favourite: true,
    ),
    _room('!g:x', 'Giftnote', 'You’ve received a gift card!', favourite: true),
    _room('!m:x', 'Matrix Donkeys', 'Encrypted message', sender: 'You'),
    _room('!i:x', 'Is This Real?', 'Yardwork multitasking', sender: 'You'),
    _room('!h:x', 'hayander', 'Encrypted message', direct: true, unread: 2),
    _room('!t:x', 'Team', 'Standup moved to 10', sender: 'Mia', unread: 4),
    _room('!a:x', 'Alex', 'See you then', direct: true),
  ]
  ..spaces = const [
    HomeSpace(id: '!s1:x', name: 'Direct Messages'),
    HomeSpace(id: '!s2:x', name: 'Discover'),
  ];

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR to render' : null;

  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Widget inbox(AppearancePreferences prefs) => FeatureSettingsScope(
    preferences: prefs,
    draftStore: MessageDraftStore(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: themeFor(VisualTheme.parallax),
      home: InboxScreen(
        backend: _homeBackend(),
        palette: paletteFor(VisualTheme.parallax),
        style: VisualTheme.parallax,
        onThemeChanged: (_) {},
      ),
    ),
  );

  testWidgets('home collapsed and open', skip: skip != null, (tester) async {
    final prefs = AppearancePreferences();
    addTearDown(prefs.dispose);
    await _frame(tester, inbox(prefs));
    await _capture(tester, 'home_collapsed');
    await openHomeOptions(tester);
    await _capture(tester, 'home_options_open');
    await tester.tap(find.text('Unread'));
    await tester.tap(find.byTooltip('Hide options'));
    await tester.pump();
    await _capture(tester, 'home_collapsed_filtered');
  });

  testWidgets('home with all options', skip: skip != null, (tester) async {
    final prefs = AppearancePreferences();
    addTearDown(prefs.dispose);
    await prefs.setExpandedHome(true);
    await _frame(tester, inbox(prefs));
    await _capture(tester, 'home_all_options');
  });

  testWidgets('room composer', skip: skip != null, (tester) async {
    await _frame(
      tester,
      FeatureSettingsScope(
        preferences: AppearancePreferences(),
        draftStore: Drafts(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(VisualTheme.parallax),
          home: RoomScreen(
            backend: FeaturesBackend(),
            palette: paletteFor(VisualTheme.parallax),
            roomId: roomId,
            draftStore: Drafts(),
            backgroundStore: FakeBackgroundStore(),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextField).last,
      'The message box now has the full width to itself',
    );
    await _capture(tester, 'room_composer');
    await tester.tap(find.byTooltip('Text formatting'));
    await _capture(tester, 'room_composer_formatting');
  });
}
