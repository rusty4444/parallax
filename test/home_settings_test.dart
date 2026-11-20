import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/home/about_screen.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/home/sign_out.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/settings_pages.dart';
import 'package:parallax/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';

void main() {
  late HomeFakeBackend backend;
  final themes = <VisualTheme>[];
  final follows = <bool>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = HomeFakeBackend();
    themes.clear();
    follows.clear();
  });

  /// Pass [preferences] to provide the app's shared settings scope, as the
  /// signed-in app does.
  Future<void> pumpSettings(
    WidgetTester tester, {
    AppearancePreferences? preferences,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 4200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        builder: preferences == null
            ? null
            : (context, child) => FeatureSettingsScope(
                preferences: preferences,
                draftStore: MessageDraftStore(),
                child: child!,
              ),
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
    await open(tester, 'Account');
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
    await open(tester, 'Account');
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
    await open(tester, 'Privacy');
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
    await open(tester, 'Account');
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
    await open(tester, 'Appearance');
    await open(tester, 'Match system');
    expect(follows, [true]);
    await open(tester, 'Daybreak');
    expect(themes, [VisualTheme.daylight]);
  });

  testWidgets('about shows version and licences', (tester) async {
    await pumpSettings(tester);
    await open(tester, 'About & help');
    expect(find.text('Parallax $parallaxVersion ($parallaxBuild)'), findsOne);
    expect(find.text('Source code'), findsOne);
    expect(find.text('GNU AGPL v3 or later'), findsOne);
    expect(find.text(licenceNotice), findsOne);
    expect(sourceCodeUrl.toString(), 'https://github.com/rusty4444/parallax');
    await open(tester, 'Open source licences');
    expect(find.byType(LicensePage), findsOneWidget);
  });

  test('report a problem emails the developer with the app version', () {
    expect(reportProblemUrl.scheme, 'mailto');
    expect(reportProblemUrl.path, 'sam@samrusselltech.net');
    expect(
      reportProblemUrl.queryParameters['subject'],
      'Parallax $parallaxVersion ($parallaxBuild) problem report',
    );
    expect(
      reportProblemUrl.queryParameters['body'],
      contains('Parallax $parallaxVersion ($parallaxBuild)'),
    );
    // Mail apps show a query-encoded `+` literally instead of a space.
    expect(reportProblemUrl.query, isNot(contains('+')));
  });

  testWidgets('report a problem shows the address when no email app opens', (
    tester,
  ) async {
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
      call,
    ) async {
      if (call.method == 'launch') {
        launched.add((call.arguments as Map)['url'] as String);
      }
      return false; // No app handles mailto: links.
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcher,
        null,
      ),
    );
    await pumpSettings(tester);
    await open(tester, 'About & help');
    expect(find.text('sam@samrusselltech.net'), findsOne);
    await tester.tap(find.text('Report a problem'));
    await tester.pumpAndSettle();
    expect(launched, [reportProblemUrl.toString()]);
    expect(
      find.text('No email app found. Write to sam@samrusselltech.net.'),
      findsOne,
    );
  });

  testWidgets('settings is a menu: every setting is on a category page', (
    tester,
  ) async {
    final preferences = AppearancePreferences();
    addTearDown(preferences.dispose);
    await pumpSettings(tester, preferences: preferences);
    for (final title in [
      'Account',
      'Notifications',
      'Appearance',
      'Chats',
      'Media',
      'Privacy',
      'Security',
      'Advanced',
      'About & help',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // Nothing is set directly on the menu.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Switch ||
            widget is SwitchListTile ||
            widget is Slider ||
            widget is Radio ||
            widget is RadioListTile ||
            widget is SegmentedButton ||
            widget is Checkbox ||
            widget is TextField,
      ),
      findsNothing,
    );
    expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);
  });

  testWidgets('each category page opens with its settings', (tester) async {
    final preferences = AppearancePreferences();
    addTearDown(preferences.dispose);
    await pumpSettings(tester, preferences: preferences);
    Future<void> visit(String category, List<String> expected) async {
      await open(tester, category);
      for (final text in expected) {
        expect(find.text(text), findsWidgets, reason: '$category: $text');
      }
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget, reason: category);
    }

    await visit('Account', [
      'Profile and password',
      'Devices',
      'Delete account',
    ]);
    await visit('Notifications', [
      'Enable notifications on this device',
      'Show message content',
      'Direct chats',
    ]);
    await visit('Appearance', [
      'THEME',
      'Match system',
      'Text size',
      'Chat row style',
    ]);
    await visit('Chats', [
      'Double-tap reaction',
      'Haptic feedback',
      'Undo send',
      'Show chat effects',
    ]);
    await visit('Media', [
      'Show media in timeline',
      'Optimise image upload quality',
    ]);
    await visit('Privacy', [
      'Send read receipts',
      'Send typing notifications',
      'Hide avatars in room invites',
      'Blocked users',
    ]);
    await visit('Security', [
      'Identity connected on this device',
      'Verify with another device',
    ]);
    await visit('Advanced', [
      'REQUIRED FOR ADVANCED FEATURES',
      'Server & bridge setup',
      'Video thumbnails, compatibility and setup instructions',
      'Open a Matrix link',
    ]);
    await visit('About & help', ['Report a problem']);
  });

  testWidgets('a theme picked on Appearance repaints the menu summary', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('Theme: Parallax'), findsOneWidget);
    await open(tester, 'Appearance');
    await open(tester, 'Daybreak');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(themes, [VisualTheme.daylight]);
    expect(find.text('Theme: Daybreak'), findsOneWidget);
  });

  testWidgets('advanced server setup row opens the public setup guide', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final args = call.arguments;
      if (args is Map && args['url'] is String) {
        launched.add(args['url'] as String);
      }
      return true;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    await pumpSettings(tester);
    await open(tester, 'Advanced');
    expect(
      find.textContaining('Normal chats do not require a custom server.'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings.advanced.serverSetup')),
    );
    await tester.pumpAndSettle();
    expect(launched, ['https://github.com/rusty4444/parallax-server-setup']);
    expect(parallaxServerSetupUrl.scheme, 'https');
  });

  testWidgets('security row flags an identity that needs recovery', (
    tester,
  ) async {
    backend.crypto = const CryptoStatus(
      initialized: true,
      connected: false,
      keyBackupEnabled: true,
      crossSigningEnabled: true,
      setupAvailability: CryptoSetupAvailability.restore,
    );
    await pumpSettings(tester);
    expect(find.text('Recovery required on this device'), findsOneWidget);
    expect(find.byIcon(Icons.gpp_maybe_outlined), findsOneWidget);
  });
}
