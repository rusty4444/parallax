import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/security/change_recovery_key_screen.dart';
import 'package:parallax/features/security/reset_identity_screen.dart';
import 'package:parallax/features/security/security_features.dart';
import 'package:parallax/features/security/security_gate.dart';
import 'package:parallax/features/security/security_settings.dart';

import 'security_fakes.dart';

Future<List<bool>> _pumpSection(
  WidgetTester tester,
  FakeSecurity security, {
  SecurityTestBackend? backend,
  List<Uri>? opened,
}) async {
  final secure = <bool>[];
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: Scaffold(
        body: ListView(
          children: [
            SecuritySettingsSection(
              backend: backend ?? SecurityTestBackend(),
              security: security,
              palette: paletteFor(VisualTheme.parallax),
              setSecureWindow: (enabled) async => secure.add(enabled),
              openUrl: (url) async {
                opened?.add(url);
                return true;
              },
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return secure;
}

Future<void> _confirmPhrase(WidgetTester tester) async {
  final phrase = tester
      .widget<SelectableText>(find.byKey(const ValueKey('security.newPhrase')))
      .data!;
  expect(phrase.length, greaterThanOrEqualTo(40));
  await tester.ensureVisible(find.text('I saved this phrase outside Parallax'));
  await tester.tap(find.text('I saved this phrase outside Parallax'));
  await tester.pump();
  await tester.enterText(
    find.byKey(const ValueKey('security.phraseConfirmation')),
    phrase,
  );
  await tester.pump();
}

void main() {
  testWidgets('shows device, key storage, recovery and reset', (tester) async {
    final security = FakeSecurity();
    await _pumpSection(tester, security);
    expect(find.text('This device is verified'), findsOneWidget);
    expect(find.text('Allow key storage'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('Change recovery key'), findsOneWidget);
    expect(find.text('Reset digital identity'), findsOneWidget);
    expect(find.text('Set up recovery'), findsNothing);
  });

  testWidgets('unverified device links to identity confirmation', (
    tester,
  ) async {
    final security = FakeSecurity()
      ..overview = const SecurityOverview(
        deviceVerified: false,
        keyStorage: KeyStorageState.on,
        setupAvailability: CryptoSetupAvailability.restore,
        recoverySetUp: true,
      );
    await _pumpSection(tester, security);
    expect(find.text('This device is not verified'), findsOneWidget);
    await tester.tap(find.text('Verify this device'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmIdentityScreen), findsOneWidget);
    expect(find.text('Confirm your digital identity'), findsOneWidget);
  });

  testWidgets('turning off key storage needs two confirmations', (
    tester,
  ) async {
    final security = FakeSecurity();
    await _pumpSection(tester, security);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      find.text('Are you sure you want to turn off key storage and delete it?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete key storage'));
    await tester.pumpAndSettle();
    expect(
      find.text('Are you sure you want to delete key storage?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(security.disables, 0);
    await tester.tap(find.text('Delete key storage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(security.disables, 1);
    expect(find.text('Key storage deleted.'), findsOneWidget);
  });

  testWidgets('turning on key storage reuses the recovery key', (tester) async {
    final security = FakeSecurity()
      ..overview = const SecurityOverview(
        deviceVerified: true,
        keyStorage: KeyStorageState.off,
        setupAvailability: CryptoSetupAvailability.repair,
        recoverySetUp: true,
      );
    final secure = await _pumpSection(tester, security);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('security.recoveryCredential')),
      'EsTx existing',
    );
    await tester.pump();
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(security.enabled, ['EsTx existing']);
    expect(secure, [true, false]);
  });

  testWidgets('blocked identity cannot toggle key storage', (tester) async {
    final security = FakeSecurity()
      ..overview = const SecurityOverview(
        deviceVerified: true,
        keyStorage: KeyStorageState.off,
        setupAvailability: CryptoSetupAvailability.blocked,
        recoverySetUp: false,
      );
    await _pumpSection(tester, security);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.text('Change recovery key'), findsNothing);
  });

  testWidgets('incomplete key storage offers to finish turning off', (
    tester,
  ) async {
    final security = FakeSecurity()
      ..overview = const SecurityOverview(
        deviceVerified: true,
        keyStorage: KeyStorageState.incomplete,
        setupAvailability: CryptoSetupAvailability.blocked,
        recoverySetUp: true,
      );
    await _pumpSection(tester, security);
    await tester.tap(find.text('Finish turning off key storage'));
    await tester.pumpAndSettle();
    expect(
      find.text('Are you sure you want to turn off key storage and delete it?'),
      findsOneWidget,
    );
  });

  testWidgets('new accounts are offered recovery setup', (tester) async {
    final security = FakeSecurity()
      ..overview = const SecurityOverview(
        deviceVerified: false,
        keyStorage: KeyStorageState.off,
        setupAvailability: CryptoSetupAvailability.create,
        recoverySetUp: false,
      );
    await _pumpSection(tester, security);
    expect(find.text('Set up recovery'), findsOneWidget);
    expect(find.text('Change recovery key'), findsNothing);
  });

  testWidgets('changing the recovery key needs the old key and a saved '
      'phrase', (tester) async {
    final security = FakeSecurity();
    final secure = await _pumpSection(tester, security);
    await tester.tap(find.text('Change recovery key'));
    await tester.pumpAndSettle();
    expect(find.byType(ChangeRecoveryKeyScreen), findsOneWidget);
    expect(secure, [true]);
    FilledButton changeButton() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Change recovery key'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(changeButton().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('security.currentRecovery')),
      'EsTx old key',
    );
    await tester.pump();
    expect(changeButton().onPressed, isNull);
    await _confirmPhrase(tester);
    expect(changeButton().onPressed, isNotNull);
    await tester.ensureVisible(find.text('Change recovery key'));
    await tester.tap(find.text('Change recovery key'));
    await tester.pumpAndSettle();
    expect(security.rotations.single.$1, 'EsTx old key');
    expect(security.rotations.single.$2.length, greaterThanOrEqualTo(40));
    expect(find.text('Your new recovery key is now active'), findsOneWidget);
    expect(find.text('EsTn ew re co ve ry'), findsOneWidget);
    await tester.tap(find.text('I saved my recovery credentials'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ChangeRecoveryKeyScreen), findsNothing);
    expect(secure, [true, false]);
  });

  testWidgets('reset needs explanation, alert, saved phrase and RESET', (
    tester,
  ) async {
    final security = FakeSecurity()
      ..approvalUrl = Uri.parse('https://account.example.org/reset');
    final opened = <Uri>[];
    final secure = await _pumpSection(tester, security, opened: opened);
    await tester.tap(find.text('Reset digital identity'));
    await tester.pumpAndSettle();
    expect(find.byType(ResetIdentityScreen), findsOneWidget);
    expect(
      find.textContaining('You will lose any message history'),
      findsOneWidget,
    );
    expect(secure, isEmpty);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      find.text('Are you sure you want to reset your digital identity?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Yes, reset now'));
    await tester.pumpAndSettle();
    expect(secure, [true]);

    FilledButton resetButton() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Reset digital identity'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(resetButton().onPressed, isNull);
    await _confirmPhrase(tester);
    expect(resetButton().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('security.resetTyped')),
      'reset',
    );
    await tester.pump();
    expect(resetButton().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('security.resetTyped')),
      'RESET',
    );
    await tester.enterText(
      find.byKey(const ValueKey('security.resetPassword')),
      'hunter2',
    );
    await tester.pump();
    expect(resetButton().onPressed, isNotNull);
    await tester.ensureVisible(find.text('Reset digital identity'));
    await tester.tap(find.text('Reset digital identity'));
    await tester.pumpAndSettle();

    // The server asked for browser approval (MAS).
    expect(find.text('Approve the reset'), findsOneWidget);
    await tester.tap(find.text('Open browser'));
    await tester.pump();
    expect(opened, [Uri.parse('https://account.example.org/reset')]);
    await tester.tap(find.text('I’ve approved it'));
    await tester.pumpAndSettle();
    expect(security.approvalResult, isTrue);
    expect(security.resets.single.$2, 'hunter2');
    expect(find.text('Your digital identity was reset'), findsOneWidget);
    expect(find.text('EsTr es et ke y'), findsOneWidget);
    await tester.tap(find.text('I saved my recovery credentials'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(ResetIdentityScreen), findsNothing);
    expect(secure, [true, false]);
  });

  testWidgets('a failed reset keeps the same phrase for a retry', (
    tester,
  ) async {
    final security = FakeSecurity()..resetError = StateError('bad password');
    await _pumpSection(tester, security);
    await tester.tap(find.text('Reset digital identity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, reset now'));
    await tester.pumpAndSettle();
    await _confirmPhrase(tester);
    await tester.enterText(
      find.byKey(const ValueKey('security.resetTyped')),
      'RESET',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Reset digital identity'));
    await tester.tap(find.text('Reset digital identity'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The reset did not complete'), findsOneWidget);
    expect(security.resets.single.$2, isNull);
    security.resetError = null;
    await tester.scrollUntilVisible(
      find.text('Reset digital identity'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ResetIdentityScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Reset digital identity'));
    await tester.pumpAndSettle();
    expect(security.resets, hasLength(2));
    expect(security.resets[0].$1, security.resets[1].$1);
    expect(find.text('Your digital identity was reset'), findsOneWidget);
  });
}
