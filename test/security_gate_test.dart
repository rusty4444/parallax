import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/crypto_setup_screen.dart';
import 'package:parallax/features/security/reset_identity_screen.dart';
import 'package:parallax/features/security/security_features.dart';
import 'package:parallax/features/security/security_gate.dart';

import 'security_fakes.dart';

const _app = Key('signed-in-app');

Future<List<bool>> _pumpGate(
  WidgetTester tester,
  FakeSecurity security, {
  SecurityTestBackend? backend,
  Duration retryDelay = const Duration(seconds: 15),
}) async {
  final secure = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      builder: (context, child) => SecurityGate(
        backend: backend ?? SecurityTestBackend(),
        security: security,
        palette: paletteFor(VisualTheme.parallax),
        setSecureWindow: (enabled) async => secure.add(enabled),
        openUrl: (_) async => true,
        retryDelay: retryDelay,
        child: child!,
      ),
      home: const Scaffold(body: Text('Inbox', key: _app)),
    ),
  );
  await tester.pumpAndSettle();
  return secure;
}

void main() {
  testWidgets('a verified device goes straight to the app', (tester) async {
    final security = FakeSecurity()..verified = true;
    await _pumpGate(tester, security);
    expect(find.byKey(_app), findsOneWidget);
    expect(find.text('Confirm your digital identity'), findsNothing);
  });

  testWidgets('no encryption never blocks', (tester) async {
    final security = FakeSecurity()..encryption = false;
    await _pumpGate(tester, security);
    expect(find.byKey(_app), findsOneWidget);
  });

  testWidgets('app stays usable while checking and if the check fails', (
    tester,
  ) async {
    final security = FakeSecurity()..loadGate = Completer<void>();
    await _pumpGate(tester, security);
    expect(find.byKey(_app), findsOneWidget);
    security.loadError = StateError('offline');
    security.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(_app), findsOneWidget);
    expect(find.text('Confirm your digital identity'), findsNothing);
    // Retries in the background, then shows the gate once reachable.
    security.loadError = null;
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(security.loads, 2);
    expect(find.text('Confirm your digital identity'), findsOneWidget);
  });

  testWidgets('unverified device on an existing identity is confirmed', (
    tester,
  ) async {
    final security = FakeSecurity();
    await _pumpGate(tester, security);
    expect(find.byKey(_app), findsNothing);
    expect(find.text('Confirm your digital identity'), findsOneWidget);
    expect(find.text('Use another device'), findsOneWidget);
    expect(find.text('Use recovery key'), findsOneWidget);
    expect(find.text('Can’t confirm?'), findsOneWidget);

    await tester.tap(find.text('Use another device'));
    await tester.pumpAndSettle();
    expect(security.selfVerifications, 1);
    expect(
      find.textContaining('Open the app on another verified device'),
      findsOneWidget,
    );

    // Verification lands from the other device: success, then the app.
    security.verified = true;
    security.update();
    await tester.pumpAndSettle();
    expect(find.text('Device verified'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byKey(_app), findsOneWidget);
  });

  testWidgets('recovery key is entered under screen protection', (
    tester,
  ) async {
    final security = FakeSecurity();
    final secure = await _pumpGate(tester, security);
    await tester.tap(find.text('Use recovery key'));
    await tester.pumpAndSettle();
    expect(secure, [true]);
    final field = find.byKey(const ValueKey('security.recoveryCredential'));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, 'EsTx recovery');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(secure, [true, false]);
    expect(security.recoveryKeys, ['EsTx recovery']);
    expect(find.text('Device verified'), findsOneWidget);
  });

  testWidgets('wrong recovery key keeps the gate with an error', (
    tester,
  ) async {
    final security = FakeSecurity()..recoveryError = StateError('bad key');
    await _pumpGate(tester, security);
    await tester.tap(find.text('Use recovery key'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('security.recoveryCredential')),
      'wrong',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Incorrect recovery key'), findsOneWidget);
    expect(find.byKey(_app), findsNothing);
  });

  testWidgets('Later explains the trade-off before unlocking', (tester) async {
    final security = FakeSecurity();
    await _pumpGate(tester, security);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Element X requires this step'), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(security.deferred, isFalse);
    expect(find.text('Confirm your digital identity'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without confirming'));
    await tester.pumpAndSettle();
    expect(security.deferred, isTrue);
    expect(find.byKey(_app), findsOneWidget);
    expect(find.text('Device verified'), findsNothing);
  });

  testWidgets('without devices or recovery only reset is offered', (
    tester,
  ) async {
    final security = FakeSecurity()
      ..state = const SessionSecurityState(
        encryptionAvailable: true,
        accountHasIdentity: true,
        deviceVerified: false,
        setupAvailability: CryptoSetupAvailability.blocked,
      );
    await _pumpGate(tester, security);
    expect(find.text('Use another device'), findsNothing);
    expect(find.text('Use recovery key'), findsNothing);
    expect(find.textContaining('you’ll need to reset'), findsOneWidget);
    await tester.tap(find.text('Can’t confirm?'));
    await tester.pumpAndSettle();
    expect(find.byType(ResetIdentityScreen), findsOneWidget);
    expect(
      find.text('Can’t confirm? You’ll need to reset your digital identity.'),
      findsOneWidget,
    );
  });

  testWidgets('a new account is routed to encryption setup', (tester) async {
    final backend = SecurityTestBackend();
    final security = FakeSecurity()
      ..state = const SessionSecurityState(
        encryptionAvailable: true,
        accountHasIdentity: false,
        deviceVerified: false,
        setupAvailability: CryptoSetupAvailability.create,
      );
    await _pumpGate(tester, security, backend: backend);
    expect(find.text('Set up secure messaging'), findsOneWidget);
    await tester.tap(find.text('Set up encryption'));
    await tester.pumpAndSettle();
    expect(find.byType(CryptoSetupScreen), findsOneWidget);
  });

  testWidgets('another-device setup waits for single device', (tester) async {
    final security = FakeSecurity()
      ..state = const SessionSecurityState(
        encryptionAvailable: true,
        accountHasIdentity: false,
        deviceVerified: false,
        setupAvailability: CryptoSetupAvailability.needsSingleDevice,
      );
    await _pumpGate(tester, security);
    expect(find.textContaining('Other devices are signed in'), findsOneWidget);
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(security.loads, 2);
  });

  testWidgets('a new session re-checks and resets deferral', (tester) async {
    final security = FakeSecurity();
    await _pumpGate(tester, security);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue without confirming'));
    await tester.pumpAndSettle();
    expect(find.byKey(_app), findsOneWidget);
    security
      ..deferred = false
      ..session = 'session-2';
    security.update();
    await tester.pumpAndSettle();
    expect(security.loads, 2);
    expect(find.text('Confirm your digital identity'), findsOneWidget);
  });

  testWidgets('settings route pops once the device is verified', (
    tester,
  ) async {
    final security = FakeSecurity();
    final backend = SecurityTestBackend();
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => ConfirmIdentityScreen(
                    backend: backend,
                    security: security,
                    palette: paletteFor(VisualTheme.parallax),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm your digital identity'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    security.verified = true;
    backend.ping();
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
