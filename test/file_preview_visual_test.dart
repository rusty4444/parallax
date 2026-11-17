// Visual QA for document previews. Skipped unless PARALLAX_SCREENSHOT_DIR
// is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/file_preview_visual_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/file_preview/document_loader.dart';
import 'package:parallax/features/file_preview/document_parser.dart';
import 'package:parallax/features/media/media_viewer_pager.dart';
import 'package:parallax/timeline/message_bubble.dart';

import 'media_test_support.dart';

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
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Uint8List _fixture(String name) =>
    File('test/fixtures/file_preview/$name').readAsBytesSync();

const _readme = '''
# Parallax

A **vivid**, focused Matrix messenger for _Android_.

## What's new

- File previews for Word, Excel, PowerPoint, Markdown and CSV
- A [changelog](https://example.org/changelog) worth reading
  - nested point
1. First
2. Second

> Messages wait for the account to reconnect instead of failing.

```dart
final preview = parseDocument(request);
```

| Format | Preview |
|--------|---------|
| .docx  | yes     |
| .pdf   | not yet |
''';

const _csv =
    'Name,Team,Start,Location\n'
    'Quinn,Operations,2024-02-01,Sydney\n'
    'Sam,IT,2019-07-15,Sydney\n'
    'Mia,"Design, brand",2022-11-30,Melbourne\n'
    'Alex,Finance,2021-05-03,Perth\n'
    'Jo,Legal,2020-01-20,Brisbane\n';

final _files = <String, (String, Uint8List)>{
  r'$xlsx': ('Budget 2027.xlsx', _fixture('budget.xlsx')),
  r'$docx': ('Quarterly report.docx', _fixture('report.docx')),
  r'$pptx': ('Roadmap.pptx', _fixture('roadmap.pptx')),
  r'$md': ('README.md', Uint8List.fromList(utf8.encode(_readme))),
  r'$csv': ('team.csv', Uint8List.fromList(utf8.encode(_csv))),
  r'$log': (
    'access.log',
    Uint8List.fromList(
      utf8.encode(
        [
          for (var i = 0; i < 60; i++)
            '192.168.68.${20 + i} - - [17/Nov/2026:09:${(i % 60).toString().padLeft(2, '0')}:11 +1100] '
                '"GET /_matrix/client/v3/sync HTTP/2.0" 200 ${1200 + i * 37}',
        ].join('\n'),
      ),
    ),
  ),
};

class _Backend extends FakeMediaBackend {
  @override
  List<ChatRoom> get rooms => const [];
}

_Backend _backend() => _Backend()
  ..original = (id) {
    final (name, bytes) = _files[id]!;
    return DownloadedAttachment(
      name: name,
      mimeType: 'application/octet-stream',
      bytes: bytes,
    );
  };

ChatEntry _entry(String id, {bool mine = false}) => mediaEntry(
  id,
  EntryKind.file,
  body: _files[id]!.$1,
  mine: mine,
  sender: mine ? me : '@alice:example.org',
  content: {
    'info': {'size': _files[id]!.$2.length},
  },
);

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR' : null;
  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });
  setUp(() => debugDocumentParser = (request) async => parseDocument(request));
  tearDown(() => debugDocumentParser = parseDocumentInBackground);

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);
    testWidgets('timeline ${style.name}', skip: skip != null, (tester) async {
      final backend = _backend();
      final entries = [
        _entry(r'$xlsx'),
        _entry(r'$docx', mine: true),
        _entry(r'$md'),
        _entry(r'$csv', mine: true),
        _entry(r'$log'),
      ];
      await _shoot(
        tester,
        'file_preview_timeline_${style.name}',
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: themeFor(style),
          home: Scaffold(
            body: GlowBackdrop(
              palette: p,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
                children: [
                  for (final entry in entries)
                    MessageBubble(
                      entry: entry,
                      backend: backend,
                      roomId: roomId,
                      palette: p,
                      group: false,
                      onHeart: () {},
                      onAction: () {},
                      onReaction: (_) {},
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    });

    for (final id in _files.keys) {
      testWidgets('viewer $id ${style.name}', skip: skip != null, (
        tester,
      ) async {
        final backend = _backend();
        final entry = _entry(id);
        await _shoot(
          tester,
          'file_preview_viewer_${id.substring(1)}_${style.name}',
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: MediaViewerPager(
              backend: backend,
              roomId: roomId,
              items: mediaViewerItems(
                backend,
                roomId,
                entry.id,
                entries: [entry],
              ),
            ),
          ),
        );
      });
    }
  }
}
