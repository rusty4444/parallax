// Screens: login entry, intro/camera/scan states, the full scan-side flow
// driven through the UI against an in-process grant flow, error wording,
// and the "Link new device" settings section and screen.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/qr_login/link_new_device_screen.dart';
import 'package:parallax/features/qr_login/qr_code_data.dart';
import 'package:parallax/features/qr_login/qr_grant_flow.dart';
import 'package:parallax/features/qr_login/qr_login_features.dart';
import 'package:parallax/features/qr_login/qr_login_flow.dart';
import 'package:parallax/features/qr_login/qr_login_hooks.dart';
import 'package:parallax/features/qr_login/qr_login_screen.dart';
import 'package:parallax/features/qr_login/qr_messages.dart';
import 'package:parallax/features/qr_login/rendezvous.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/login_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qr_login_fakes.dart';
import 'widget_test.dart' show FakeBackend;

class _Features implements QrLoginFeatures {
  _Features(this.server, {FakeLoginAccount? login})
    : login = login ?? FakeLoginAccount();
  final FakeRendezvousServer server;
  final FakeLoginAccount login;
  bool signIn = true;
  bool link = true;
  FakeGrantAccount? grant;
  Object? exportError;
  final exportKeys = <String>[];

  @override
  bool get canSignInWithQrCode => signIn;
  @override
  QrLoginAccount get loginAccount => login;
  @override
  bool get canLinkNewDevice => link;
  @override
  QrGrantAccount? grantAccount() => grant;
  @override
  Future<QrSecretsBundle> exportSecrets(String key) async {
    exportKeys.add(key);
    if (exportError != null) throw exportError!;
    return testSecrets();
  }

  @override
  http.Client newRendezvousClient() => server.client;
}

final _palette = paletteFor(VisualTheme.parallax);

/// Fake-async polling must advance the clock: a zero-length delay would let
/// two polling parties spin forever inside a single pump.
Future<void> _uiDelay(Duration _) =>
    Future<void>.delayed(const Duration(milliseconds: 1));

Widget _app(Widget child) =>
    MaterialApp(theme: themeFor(VisualTheme.parallax), home: child);

/// Runs real async work (crypto, mock HTTP, zero-length polls) to a
/// condition inside the fake-async widget zone.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int maxPumps = 5000,
}) async {
  for (var i = 0; i < maxPumps && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  if (!done()) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .join(' | ');
    fail('condition not reached; showing: $texts');
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late FakeRendezvousServer server;
  late FakeBackend backend;
  late _Features features;

  // Built inside each test body: completers created in setUp belong to the
  // real zone and never complete under the widget tester's fake async.
  void init() {
    server = FakeRendezvousServer();
    backend = FakeBackend();
    features = _Features(server);
    debugSetQrLoginFeatures(backend, features);
  }

  group('login screen entry', () {
    testWidgets('offers "Sign in with QR code" when available', (tester) async {
      init();
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(LoginScreen(backend: backend, palette: _palette)),
      );
      expect(find.text('Sign in with QR code'), findsOneWidget);
      await tester.tap(find.text('Sign in with QR code'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Open Element or Parallax on another device to get the QR code',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Only available if your account provider supports it.'),
        findsOneWidget,
      );
      expect(find.text('Select “Link new device”'), findsOneWidget);
    });

    testWidgets('hidden when QR sign-in cannot run', (tester) async {
      init();
      features.signIn = false;
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(LoginScreen(backend: backend, palette: _palette)),
      );
      expect(find.text('Sign in with QR code'), findsNothing);
      // The existing manual sign-in is untouched.
      expect(find.text('Enter the matrix'), findsOneWidget);
    });
  });

  group('scan side', () {
    late ValueChanged<Uint8List> scan;
    var cameraGranted = true;

    Widget screen() => _app(
      _Host(
        QrLoginScreen(
          backend: backend,
          palette: _palette,
          delay: _uiDelay,
          requestCamera: () async => cameraGranted,
          scannerBuilder: (context, onScanned) {
            scan = onScanned;
            return const ColoredBox(color: Colors.black);
          },
        ),
      ),
    );

    setUp(() => cameraGranted = true);

    testWidgets('camera permission denied', (tester) async {
      init();
      cameraGranted = false;
      _tall(tester);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      expect(
        find.text('Allow camera access to scan the QR code'),
        findsOneWidget,
      );
      cameraGranted = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Scan the QR code'), findsOneWidget);
    });

    testWidgets('wrong and not-signed-in codes are explained inline', (
      tester,
    ) async {
      init();
      _tall(tester);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      scan(Uint8List.fromList('https://example.org'.codeUnits));
      await tester.pump();
      expect(find.text('Wrong QR code'), findsOneWidget);
      expect(
        find.text('Use the QR code shown on the other device.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Try again'));
      await tester.pump();
      scan(
        QrCodeData.msc4108(
          publicKey: Uint8List(32)..[1] = 1,
          rendezvousUrl: 'https://rz.example/rendezvous/x',
        ).encode(),
      );
      await tester.pump();
      expect(find.text('Other device not signed in'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('full sign-in shows the check code and verification code', (
      tester,
    ) async {
      init();
      final grantAccount = FakeGrantAccount(
        homeserver: server.homeserver,
        login: features.login,
      );
      final grantSteps = <QrGrantStep>[];
      QrCodeData? qr;
      final grant = QrGrantFlow(
        client: server.client,
        account: grantAccount,
        secrets: testSecrets(),
        delay: _uiDelay,
        onStep: (step) {
          grantSteps.add(step);
          if (step is QrGrantQrReady) qr = step.data;
        },
      ).run(QrCancellation());

      _tall(tester);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () => qr != null);
      scan(qr!.encode());
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find
            .text('Enter the number below on your other device')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.text(
          'You’ll be asked to enter the two digits shown on this device.',
        ),
        findsOneWidget,
      );
      expect(find.text('Waiting for your other device'), findsOneWidget);

      // The user types the digits shown into the existing device.
      final scanned = grantSteps.whereType<QrGrantQrScanned>().single;
      final digits = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((d) => RegExp(r'^\d$').hasMatch(d))
          .join();
      expect(digits, hasLength(2));
      features.login.waitForApproval = true;
      scanned.checkCode.complete(int.parse(digits));
      await _pumpUntil(
        tester,
        () => find.text('Your verification code').evaluate().isNotEmpty,
      );
      expect(find.text('A'), findsOneWidget); // ABCD-1234 as tiles
      expect(find.text('-'), findsOneWidget);
      // Approval in the browser completes the sign-in; the route closes.
      await _pumpUntil(tester, () => grantSteps.last is QrGrantDone);
      await _pumpUntil(tester, () => features.login.imported != null);
      await _pumpUntil(
        tester,
        () => find.byType(QrLoginScreen).evaluate().isEmpty,
      );
      expect(find.text('home'), findsOneWidget);
      expect(features.login.imported, isNotNull);
      expect(await grant, isA<QrGrantDone>());
    });

    testWidgets('cancel on the check code screen returns to the intro', (
      tester,
    ) async {
      init();
      QrCodeData? qr;
      unawaited(
        QrGrantFlow(
          client: server.client,
          account: FakeGrantAccount(homeserver: server.homeserver),
          secrets: testSecrets(),
          delay: _uiDelay,
          onStep: (step) {
            if (step is QrGrantQrReady) qr = step.data;
          },
        ).run(QrCancellation()),
      );
      _tall(tester);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () => qr != null);
      scan(qr!.encode());
      await _pumpUntil(tester, () => find.text('Cancel').evaluate().isNotEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(find.text('Ready to scan'), findsOneWidget);
      server.expireAll();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    });

    testWidgets('closes once the app is signed in, however it got there', (
      tester,
    ) async {
      init();
      final signingIn = _SigningInBackend();
      debugSetQrLoginFeatures(signingIn, features);
      _tall(tester);
      await tester.pumpWidget(
        _app(
          _Host(
            QrLoginScreen(
              backend: signingIn,
              palette: _palette,
              requestCamera: () async => true,
              scannerBuilder: (context, onScanned) => const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QrLoginScreen), findsOneWidget);
      signingIn.signIn();
      await tester.pumpAndSettle();
      expect(find.byType(QrLoginScreen), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('an expired session shows the Element X error', (tester) async {
      init();
      _tall(tester);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ready to scan'));
      await tester.pumpAndSettle();
      scan(
        QrCodeData.msc4108(
          publicKey: Uint8List(32)..[1] = 1,
          rendezvousUrl: 'https://rz.example/rendezvous/gone',
          serverName: 'hs.example',
        ).encode(),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('The sign in was not completed in time')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Sign in expired. Please try again.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(find.text('Ready to scan'), findsOneWidget);
    });
  });

  group('error wording (Element X)', () {
    testWidgets('every login error has a page', (tester) async {
      init();
      for (final error in QrLoginError.values) {
        await tester.pumpWidget(
          _app(
            QrLoginErrorPage(
              palette: _palette,
              error: error,
              onRetry: () {},
              onCancel: () {},
            ),
          ),
        );
        final (title, subtitle) = QrLoginErrorPage.texts(error);
        expect(find.text(title), findsOneWidget);
        expect(find.text(subtitle), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
      }
      await tester.pumpWidget(
        _app(
          QrLoginErrorPage(
            palette: _palette,
            error: QrLoginError.connectionInsecure,
            onRetry: () {},
            onCancel: () {},
          ),
        ),
      );
      expect(find.text('Connection not secure'), findsOneWidget);
      expect(find.text('What now?'), findsOneWidget);
      expect(
        find.text('If that doesn’t work, sign in manually'),
        findsOneWidget,
      );
      expect(QrLoginErrorPage.texts(QrLoginError.declined), (
        'Sign in declined',
        'The sign in was declined on the other device.',
      ));
    });

    test('link-device errors use Element X wording', () {
      init();
      expect(
        LinkNewDeviceErrorPage.texts(QrGrantError.invalidCheckCode).$1,
        'The numbers don’t match',
      );
      expect(LinkNewDeviceErrorPage.texts(QrGrantError.cancelled), (
        'Sign in request cancelled',
        'The sign in was cancelled on the other device.',
      ));
    });
  });

  group('link new device', () {
    testWidgets('settings section appears only when linking is possible', (
      tester,
    ) async {
      init();
      final ctx = SettingsHookContext(backend: backend, palette: _palette);
      late List<Widget> sections;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              sections = qrLoginSettingsSections(context, ctx);
              return ListView(children: sections);
            },
          ),
        ),
      );
      expect(find.text('Link new device'), findsOneWidget);
      features.link = false;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) =>
                ListView(children: qrLoginSettingsSections(context, ctx)),
          ),
        ),
      );
      expect(find.text('Link new device'), findsNothing);
    });

    testWidgets('shows a QR code and checks the two digits', (tester) async {
      init();
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      features.grant = FakeGrantAccount(homeserver: server.homeserver);
      QrCodeData? shownData;
      await tester.pumpWidget(
        _app(
          LinkNewDeviceScreen(
            backend: backend,
            palette: _palette,
            delay: _uiDelay,
            askRecoveryKey: (_) async => 'recovery-key',
            onQrShown: (data) => shownData = data,
          ),
        ),
      );
      expect(
        find.text('Scan the QR code shown here with the other device'),
        findsOneWidget,
      );
      await tester.tap(find.text('Show QR code'));
      await _pumpUntil(
        tester,
        () => find.byType(QrImageView).evaluate().isNotEmpty,
      );
      expect(features.exportKeys, ['recovery-key']);

      // A new device scans it (the in-process login flow).
      final shown = find.byType(QrImageView);
      expect(shown, findsOneWidget);
      // The payload round-trips through the QR encoding.
      final data = QrCodeData.decode(shownData!.encode());
      expect(data.intent, QrCodeIntent.reciprocate);
      expect(data.serverName, 'https://hs.example');
      final newDevice = FakeLoginAccount();
      final loginSteps = <QrLoginStep>[];
      unawaited(
        QrLoginFlow(
          client: server.client,
          account: newDevice,
          delay: _uiDelay,
          onStep: loginSteps.add,
        ).run(data, QrCancellation()),
      );
      await _pumpUntil(
        tester,
        () => find
            .text('Enter the number shown on your other device')
            .evaluate()
            .isNotEmpty,
      );
      final code = loginSteps
          .whereType<QrLoginEstablishingSecureChannel>()
          .single
          .checkCode;
      final wrong = ((int.parse(code) + 1) % 100).toString().padLeft(2, '0');
      await tester.enterText(find.byType(TextField), wrong);
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await _pumpUntil(
        tester,
        () => find.text('The numbers don’t match').evaluate().isNotEmpty,
      );
      server.expireAll();
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    });

    testWidgets('a wrong recovery key is reported before any QR code', (
      tester,
    ) async {
      init();
      features
        ..grant = FakeGrantAccount(homeserver: server.homeserver)
        ..exportError = StateError('bad key');
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          LinkNewDeviceScreen(
            backend: backend,
            palette: _palette,
            delay: _uiDelay,
            askRecoveryKey: (_) async => 'nope',
          ),
        ),
      );
      await tester.tap(find.text('Show QR code'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t read your encryption keys'), findsOneWidget);
      expect(server.requests, isEmpty);
    });
  });
}

/// Pushes [child] over a home page, like the login screen does.
class _Host extends StatefulWidget {
  const _Host(this.child);
  final Widget child;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<bool>(builder: (_) => widget.child));
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('home')));
}

class _SigningInBackend extends FakeBackend {
  SessionStatus _status = SessionStatus.signedOut;
  @override
  SessionStatus get connection => _status;
  void signIn() {
    _status = SessionStatus.ready;
    notifyListeners();
  }
}
