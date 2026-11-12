// Visual QA for room key export/import. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/key_export_visual_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/security/key_export_features.dart';
import 'package:parallax/features/security/key_export_format.dart';
import 'package:parallax/features/security/key_export_screens.dart';
import 'package:parallax/features/security/security_settings.dart';

import 'key_export_fakes.dart';
import 'security_fakes.dart';

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

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$_dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });

Widget _app(GlobalKey key, VisualTheme style, Widget home) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: themeFor(style),
    home: home,
  ),
);

RoomKeyTransfer _transfer(FakeKeyFiles files) => RoomKeyTransfer(
  FakeKeyStore([fakeSession('a'), fakeSession('b'), fakeSession('c')]),
  cipher: const InlineKeyExportCipher(),
  files: files,
  rounds: 100,
);

void main() {
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR' : null;
  setUpAll(() async {
    if (skip == null) await _loadFonts();
  });

  for (final style in [VisualTheme.parallax]) {
    final palette = paletteFor(style);
    void size(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    testWidgets('settings ${style.name}', skip: skip != null, (tester) async {
      size(tester);
      tester.view.physicalSize = const Size(1080, 4400);
      final key = GlobalKey();
      await tester.pumpWidget(
        _app(
          key,
          style,
          Scaffold(
            body: GlowBackdrop(
              palette: palette,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  SecuritySettingsSection(
                    backend: SecurityTestBackend(),
                    security: FakeSecurity(),
                    palette: palette,
                    setSecureWindow: (_) async {},
                    keyTransfer: _transfer(FakeKeyFiles()),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, key, 'key_export_settings_${style.name}');
    });

    testWidgets('export ${style.name}', skip: skip != null, (tester) async {
      size(tester);
      final key = GlobalKey();
      final files = FakeKeyFiles();
      await tester.pumpWidget(
        _app(
          key,
          style,
          KeyExportScreen(
            transfer: _transfer(files),
            palette: palette,
            setSecureWindow: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyExport.passphrase')),
        'Password1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('keyExport.confirm')),
        'Password123',
      );
      await tester.pumpAndSettle();
      await _capture(tester, key, 'key_export_form_${style.name}');
      await tester.enterText(
        find.byKey(const ValueKey('keyExport.confirm')),
        'Password1234',
      );
      await tester.pump();
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'key_export_done_${style.name}');
    });

    testWidgets('import ${style.name}', skip: skip != null, (tester) async {
      size(tester);
      final key = GlobalKey();
      final files = FakeKeyFiles()
        ..next = PickedKeyFile(
          name: 'element-keys.txt',
          bytes: encryptKeyExport(
            jsonEncode([fakeSession('a'), fakeSession('x'), fakeSession('y')]),
            'pw',
            rounds: 50,
          ),
        );
      await tester.pumpWidget(
        _app(
          key,
          style,
          KeyImportScreen(
            transfer: _transfer(files),
            palette: palette,
            setSecureWindow: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose file'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('keyImport.passphrase')),
        'nope',
      );
      await tester.pump();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'key_import_error_${style.name}');
      await tester.enterText(
        find.byKey(const ValueKey('keyImport.passphrase')),
        'pw',
      );
      await tester.pump();
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'key_import_done_${style.name}');
    });
  }
}
