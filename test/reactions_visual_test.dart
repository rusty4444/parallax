// Visual QA for the reactions module. Skipped unless PARALLAX_SCREENSHOT_DIR
// is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/reactions_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/reactions/emoji_picker_sheet.dart';
import 'package:parallax/features/reactions/forward_screen.dart';
import 'package:parallax/features/reactions/message_action_features.dart';
import 'package:parallax/features/reactions/pinned_messages.dart';
import 'package:parallax/features/reactions/reaction_summary_sheet.dart';
import 'package:parallax/features/reactions/report_content_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reactions_fakes.dart';

final _dir = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
final _palette = paletteFor(defaultVisualTheme);

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

final _key = GlobalKey();

Future<void> _mount(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        key: UniqueKey(),
        debugShowCheckedModeBanner: false,
        theme: themeFor(defaultVisualTheme),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$_dir/reactions_$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

ChatEntry _msg(
  String id,
  String name,
  String body, {
  int minute = 0,
  List<ChatReaction> reactions = const [],
}) => ChatEntry(
  id: id,
  sender: '@${name.toLowerCase()}:example.org',
  senderName: name,
  body: body,
  time: DateTime(2026, 11, 12, 9, minute),
  mine: false,
  reactions: reactions,
  content: {'msgtype': 'm.text', 'body': body},
);

FakeReactionsBackend _backend() => FakeReactionsBackend()
  ..roomList = [
    for (final (i, name) in [
      'Weekend crew',
      'Alex Rivera',
      'Matrix HQ',
      'Design reviews',
      'Family',
      'Book club',
      'Parallax testers',
    ].indexed)
      ChatRoom(
        id: '!r$i:example.org',
        name: name,
        preview: '',
        lastActivity: DateTime(2026, 11, 12 - i),
        encrypted: i != 2,
      ),
  ]
  ..pins = [r'$p1', r'$p2', r'$p3']
  ..active = [
    _msg(r'$p1', 'Mia', 'Ferry leaves at 9:40 from Circular Quay'),
    _msg(r'$p2', 'Alex', 'Wi-Fi password is on the fridge', minute: 3),
    _msg(r'$p3', 'Sam', 'Bring sunscreen and a hat ☀️', minute: 9),
  ]
  ..senders = const [
    ReactionSender(
      emoji: '👍',
      userId: '@mia:example.org',
      displayName: 'Mia',
      time: null,
    ),
    ReactionSender(
      emoji: '👍',
      userId: '@sam:matrix.example',
      displayName: 'Sam',
    ),
    ReactionSender(
      emoji: '🎉',
      userId: '@alex:example.org',
      displayName: 'Alex Rivera',
    ),
  ];

void main() {
  setUpAll(() async {
    if (_dir != null) await _loadFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('render reactions screens', (tester) async {
    final backend = _backend();
    final entry = _msg(
      r'$m',
      'Mia',
      'Sunset at the pier tonight?',
      reactions: const [
        ChatReaction(emoji: '👍', count: 2, mine: true),
        ChatReaction(emoji: '🎉', count: 1, mine: false),
      ],
    );

    await _mount(
      tester,
      Scaffold(
        body: GlowBackdrop(
          palette: _palette,
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 64),
                PinnedMessagesBanner(
                  backend: backend,
                  features: backend,
                  roomId: fakeRoomId,
                  palette: _palette,
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    await _shoot(tester, 'pinned_banner');

    await _mount(
      tester,
      PinnedMessagesScreen(
        backend: backend,
        features: backend,
        roomId: fakeRoomId,
        palette: _palette,
      ),
    );
    await _shoot(tester, 'pinned_list');

    await _mount(
      tester,
      ForwardScreen(
        backend: backend,
        features: backend,
        palette: _palette,
        initial: entry,
        candidates: backend.active,
      ),
    );
    await tester.tap(find.text('Alex Rivera'));
    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await _shoot(tester, 'forward');

    await _mount(
      tester,
      ReportContentScreen(
        backend: backend,
        features: backend,
        roomId: fakeRoomId,
        entry: entry,
        palette: _palette,
      ),
    );
    await _shoot(tester, 'report');

    await _mount(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showEmojiPickerSheet(
              context,
              palette: _palette,
              forReaction: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _shoot(tester, 'emoji_picker');

    await _mount(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showReactionSummary(
              context,
              backend: backend,
              features: backend,
              roomId: fakeRoomId,
              entry: entry,
              palette: _palette,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _shoot(tester, 'reaction_summary');
  }, skip: _dir == null);
}
