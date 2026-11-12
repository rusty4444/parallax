// Visual QA for the QR sign-in screens. Skipped unless
// PARALLAX_SCREENSHOT_DIR is set:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/qr_login_visual_test.dart
// Not a golden test: nothing is asserted on pixels.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/qr_login/link_new_device_screen.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';
import 'package:parallax/features/qr_login/qr_grant_flow.dart';
import 'package:parallax/features/qr_login/qr_login_features.dart';
import 'package:parallax/features/qr_login/qr_login_flow.dart';
import 'package:parallax/features/qr_login/qr_login_screen.dart';
import 'package:parallax/features/qr_login/qr_messages.dart';
import 'package:parallax/features/qr_login/rendezvous.dart';

import 'qr_login_fakes.dart';
import 'widget_test.dart' show FakeBackend;

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

class _Features implements QrLoginFeatures {
  _Features(this.server);
  final FakeRendezvousServer server;
  final login = FakeLoginAccount();
  @override
  bool get canSignInWithQrCode => true;
  @override
  QrLoginAccount get loginAccount => login;
  @override
  bool get canLinkNewDevice => true;
  @override
  QrGrantAccount? grantAccount() =>
      FakeGrantAccount(homeserver: server.homeserver);
  @override
  Future<QrSecretsBundle> exportSecrets(String key) async => testSecrets();
  @override
  http.Client newRendezvousClient() => server.client;
}

Future<void> _delay(Duration _) =>
    Future<void>.delayed(const Duration(milliseconds: 1));

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 5000 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
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
  final skip = _dir == null ? 'Set PARALLAX_SCREENSHOT_DIR' : null;
  setUpAll(() async {
    if (_dir != null) {
      Directory(_dir!).createSync(recursive: true);
      await _loadFonts();
    }
  });

  for (final style in [VisualTheme.parallax, VisualTheme.parallaxDay]) {
    final p = paletteFor(style);

    testWidgets('qr login ${style.name}', skip: skip != null, (tester) async {
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final server = FakeRendezvousServer();
      final backend = FakeBackend();
      debugSetQrLoginFeatures(backend, _Features(server));
      late ValueChanged<Uint8List> scan;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: QrLoginScreen(
              backend: backend,
              palette: p,
              delay: _delay,
              requestCamera: () async => true,
              scannerBuilder: (context, onScanned) {
                scan = onScanned;
                return const ColoredBox(color: Color(0xFF101010));
              },
            ),
          ),
        ),
      );
      await _capture(tester, key, 'qr_intro_${style.name}');
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      await _capture(tester, key, 'qr_scan_${style.name}');
      scan(Uint8List.fromList('https://example.org'.codeUnits));
      await tester.pump();
      await _capture(tester, key, 'qr_wrong_code_${style.name}');
      await tester.tap(find.text('Try again'));
      await tester.pump();

      QrCodeData? qr;
      unawaited(
        QrGrantFlow(
          client: server.client,
          account: FakeGrantAccount(homeserver: server.homeserver),
          secrets: testSecrets(),
          delay: _delay,
          onStep: (step) {
            if (step is QrGrantQrReady) qr = step.data;
          },
        ).run(QrCancellation()),
      );
      await _settle(tester, () => qr != null);
      scan(qr!.encode());
      await _settle(
        tester,
        () => find
            .text('Enter the number below on your other device')
            .evaluate()
            .isNotEmpty,
      );
      await _capture(tester, key, 'qr_check_code_${style.name}');
      server.expireAll();
      await _settle(tester, () => find.text('Try again').evaluate().isNotEmpty);
      await _capture(tester, key, 'qr_expired_${style.name}');

      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: QrLoginErrorPage(
              palette: p,
              error: QrLoginError.connectionInsecure,
              onRetry: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await _capture(tester, key, 'qr_insecure_${style.name}');
    });

    testWidgets('link new device ${style.name}', skip: skip != null, (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2280);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final server = FakeRendezvousServer();
      final backend = FakeBackend();
      debugSetQrLoginFeatures(backend, _Features(server));
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(style),
            home: LinkNewDeviceScreen(
              backend: backend,
              palette: p,
              delay: _delay,
              askRecoveryKey: (_) async => 'key',
            ),
          ),
        ),
      );
      await _capture(tester, key, 'link_intro_${style.name}');
      await tester.tap(find.text('Show QR code'));
      await _settle(
        tester,
        () =>
            find
                .text('Open Parallax or Element X on the other device')
                .evaluate()
                .length >
            1,
      );
      await _capture(tester, key, 'link_qr_${style.name}');
      // Leaving the screen cancels the grant.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    });
  }
}
