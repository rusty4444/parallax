import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/home/about_screen.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/home/sign_out.dart';
import 'package:parallax/settings_screen.dart';

import 'home_fakes.dart';

void main() {
  late HomeFakeBackend backend;
  final themes = <VisualTheme>[];
  final follows = <bool>[];

  setUp(() {
    backend = HomeFakeBackend();
    themes.clear();
    follows.clear();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 4200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: SettingsScreen(
          backend: backend,
          palette: paletteFor(VisualTheme.parallax),
          style: VisualTheme.parallax,
          onThemeChanged: themes.add,
          setSecureWindow: (_) async {},
          onFollowSystemTheme: follows.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets('profile card edits display name and changes password', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('@sam:example.org'), findsOneWidget);
    await open(tester, 'Sam');
    expect(find.text('Profile'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Samantha');
    await tester.tap(find.byTooltip('Save display name'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('name:Samantha'));

    await open(tester, 'Change password');
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(fields.evaluate().length - 3), 'old-pass');
    await tester.enterText(
      fields.at(fields.evaluate().length - 2),
      'new-pass-1',
    );
    await tester.enterText(fields.last, 'new-pass-1');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('password'));
    expect(find.text('Password changed.'), findsOneWidget);
  });

  testWidgets('delegated accounts link to account management', (tester) async {
    backend.management = AccountManagement(
      url: Uri.parse('https://account.example.org/'),
      deviceDeleteSupported: true,
    );
    await pumpSettings(tester);
    expect(find.text('Manage account'), findsOneWidget);
    expect(find.text('Profile and password'), findsNothing);
    expect(
      backend.management.sessionEndUrl('DEV').toString(),
      'https://account.example.org/?action=org.matrix.device_delete&device_id=DEV',
    );
  });

  testWidgets('notification rules read and write global defaults', (
    tester,
  ) async {
    await pumpSettings(tester);
    await open(tester, 'Notifications');
    expect(find.text('Enable notifications on this device'), findsOneWidget);
    expect(find.text('Mentions and keywords'), findsOneWidget);
    await open(tester, 'Group chats');
    await tester.tap(find.text('All messages').last);
    await tester.pumpAndSettle();
    expect(backend.calls, contains('mode:group:true'));
    expect(find.text('Mentions and keywords'), findsNothing);

    await tester.tap(find.text('Audio and video calls'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('toggle:calls:true'));
    await tester.tap(find.text('Mentions of @room'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('toggle:roomMentions:false'));

    backend.failNext = true;
    await tester.tap(find.text('Invitations'));
    await tester.pumpAndSettle();
    expect(
      find.text('An error occurred while updating the notification setting.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Invitations'),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('other sessions sign out after a password prompt', (
    tester,
  ) async {
    backend.requiredPassword = 'secret';
    await pumpSettings(tester);
    await open(tester, 'Devices');
    expect(find.text('Parallax Android'), findsOneWidget);
    expect(find.textContaining('Verified'), findsOneWidget);
    await tester.tap(find.byTooltip('Session options').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm it’s you'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('signOut:OTHER'));
    expect(backend.lastPassword, 'secret');
    expect(find.text('Element Web'), findsNothing);
    expect(find.text('No other sessions'), findsOneWidget);
  });

  testWidgets('blocked users can be unblocked', (tester) async {
    await pumpSettings(tester);
    await open(tester, 'Blocked users');
    expect(find.text('@spam:example.org'), findsOneWidget);
    await open(tester, 'Unblock');
    await tester.tap(find.widgetWithText(FilledButton, 'Unblock'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('unblock:@spam:example.org'));
    expect(find.text('You have no blocked users'), findsOneWidget);
  });

  testWidgets('sign out warns when key backup is off', (tester) async {
    backend.crypto = const CryptoStatus(
      initialized: true,
      connected: true,
      keyBackupEnabled: false,
      crossSigningEnabled: true,
      setupAvailability: CryptoSetupAvailability.connected,
    );
    await pumpSettings(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(
      find.text('You’re about to lose access to your encrypted chats'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.logouts, 0);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out anyway'));
    await tester.pumpAndSettle();
    expect(backend.logouts, 1);
  });

  test('sign-out risk follows backup state', () {
    expect(signOutRiskFor(null), SignOutRisk.unknown);
    expect(
      signOutRiskFor(
        const CryptoStatus(
          initialized: false,
          connected: false,
          keyBackupEnabled: false,
          crossSigningEnabled: false,
          setupAvailability: CryptoSetupAvailability.create,
        ),
      ),
      SignOutRisk.noBackup,
    );
  });

  testWidgets('delete account needs a password and confirmation', (
    tester,
  ) async {
    await pumpSettings(tester);
    await open(tester, 'Delete account');
    expect(find.text('irreversible', findRichText: true), findsNothing);
    expect(find.textContaining('irreversible', findRichText: true), findsOne);
    final delete = find.widgetWithText(FilledButton, 'Delete account');
    expect(tester.widget<FilledButton>(delete).onPressed, isNull);
    await tester.tap(find.text('Delete all my messages'));
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pump();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(backend.calls, contains('deactivate:true'));
    expect(backend.lastPassword, 'secret');
    expect(backend.logouts, 1);
  });

  testWidgets('theme choice includes Match system', (tester) async {
    await pumpSettings(tester);
    await open(tester, 'Match system');
    expect(follows, [true]);
    await open(tester, 'Daybreak');
    expect(themes, [VisualTheme.daylight]);
  });

  testWidgets('about shows version and licences', (tester) async {
    await pumpSettings(tester);
    await open(tester, 'About Parallax');
    expect(find.text('Parallax $parallaxVersion ($parallaxBuild)'), findsOne);
    await open(tester, 'Open source licences');
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
