// Visual QA for the saved module (inbox folder tabs, Note to self, saved
// messages). Skipped unless PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/saved_visual_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/saved/folder_editor_screen.dart';
import 'package:parallax/features/saved/saved_features.dart';
import 'package:parallax/features/saved/saved_messages_screen.dart';
import 'package:parallax/features/saved/saved_models.dart';
import 'package:parallax/inbox_screen.dart';

import 'saved_fakes.dart';

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
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

SavedFakeBackend _backend() {
  final backend = SavedFakeBackend()
    ..noteRoom = '!note:x.org'
    ..roomList = [
      savedRoom('!note:x.org', encrypted: true, preview: 'Passport renewal'),
      savedRoom(
        '!team:x.org',
        name: 'Design team',
        unread: 3,
        encrypted: true,
        preview: 'Mock-ups are up',
      ),
      savedRoom(
        '!alex:x.org',
        name: 'Alex Chen',
        direct: true,
        preview: 'See you at 6',
      ),
      savedRoom('!fam:x.org', name: 'Family', unread: 1, preview: 'Dinner?'),
    ]
    ..folderData = const ChatFolders(
      folders: [
        ChatFolder(
          id: 'work',
          name: 'Work',
          icon: '💼',
          includeRooms: ['!team:x.org'],
        ),
        ChatFolder(
          id: 'home',
          name: 'Home',
          icon: '🏠',
          includeRooms: ['!fam:x.org'],
          include: FolderIncludes(people: true),
        ),
      ],
    );
  backend.saved = BookmarkList.empty
      .withAdded('!team:x.org', r'$a', savedTs: 1762833900000)
      .withAdded('!alex:x.org', r'$b', savedTs: 1762800000000)
      .withAdded('!gone:x.org', r'$c', savedTs: 1762500000000);
  backend.events[r'$a'] = SavedEventResult.available(
    ChatEntry(
      id: r'$a',
      sender: '@mia:x.org',
      senderName: 'Mia Lopez',
      body: 'Final colour palette: ember red, amber and charcoal.',
      time: DateTime(2026, 11, 10, 14, 5),
      mine: false,
    ),
  );
  backend.events[r'$b'] = SavedEventResult.available(
    ChatEntry(
      id: r'$b',
      sender: '@alex:x.org',
      senderName: 'Alex Chen',
      body: 'Wi-Fi password is on the fridge 🙂',
      time: DateTime(2026, 11, 8, 19, 40),
      mine: false,
    ),
  );
  return backend;
}

void main() {
  final skip = _dir == null;
  // Real file reads hang inside the fake-async widget-test zone.
  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  testWidgets('saved module screens', (tester) async {
    final palette = paletteFor(VisualTheme.parallax);
    final theme = themeFor(VisualTheme.parallax);
    final backend = _backend();

    await _shoot(
      tester,
      'saved_inbox',
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: InboxScreen(
          backend: backend,
          palette: palette,
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
    await _shoot(
      tester,
      'saved_messages',
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: SavedMessagesScreen(backend: backend, palette: palette),
      ),
    );
    await _shoot(
      tester,
      'saved_folder_editor',
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: FolderEditorScreen(
          backend: backend,
          palette: palette,
          features: backend,
          folder: backend.folderData.byId('home'),
        ),
      ),
    );
    final prompt = _backend()..noteRoom = null;
    prompt.roomList = prompt.roomList.skip(1).toList();
    await _shoot(
      tester,
      'saved_inbox_prompt',
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: InboxScreen(
          backend: prompt,
          palette: palette,
          style: VisualTheme.parallax,
          onThemeChanged: (_) {},
        ),
      ),
    );
  }, skip: skip);
}
