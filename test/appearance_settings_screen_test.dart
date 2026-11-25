import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/appearance_settings_screen.dart';
import 'package:parallax/settings_pages.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend;

/// The app preferences are split across Settings → Appearance (reading and
/// home screen), Chats (touch), Media (timeline media) and Privacy (activity
/// and invites). These tests drive each page against the shared
/// [AppearancePreferences] model.
void main() {
  late SharedPreferences prefs;
  late AppearancePreferences preferences;
  final palette = paletteFor(VisualTheme.parallax);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // Finish model setup inside each widget test's fake-async zone.
  });

  tearDown(() => preferences.dispose());

  Widget appearance(AppearancePreferences preferences) =>
      AppearanceSettingsScreen(preferences: preferences);
  Widget chats(AppearancePreferences preferences) => ChatsSettingsPage(
    backend: FakeBackend(),
    palette: palette,
    preferences: preferences,
  );
  Widget media(AppearancePreferences preferences) => MediaSettingsPage(
    backend: FakeBackend(),
    palette: palette,
    preferences: preferences,
  );
  Widget privacy(AppearancePreferences preferences) => PrivacySettingsPage(
    backend: FakeBackend(),
    palette: palette,
    preferences: preferences,
  );

  /// Creates the model in the widget test's zone (not setUp's real zone).
  Future<void> createPreferences() async {
    preferences = AppearancePreferences(prefs: prefs);
    await preferences.load();
  }

  /// Shows [page] for the current model on a surface tall enough that the
  /// lazily built list holds every card.
  Future<void> showPage(
    WidgetTester tester,
    Widget Function(AppearancePreferences preferences) page,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: page(preferences)));
    await tester.pumpAndSettle();
  }

  Future<void> show(
    WidgetTester tester,
    Widget Function(AppearancePreferences preferences) page,
  ) async {
    await createPreferences();
    await showPage(tester, page);
  }

  List<bool> switchValues(WidgetTester tester) => [
    for (final tile in tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    ))
      tile.value,
  ];

  testWidgets('each page renders its preferences with default values', (
    tester,
  ) async {
    await show(tester, appearance);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Compact layout'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
    expect(tester.widget<Slider>(find.byType(Slider)).min, 0.85);
    expect(tester.widget<Slider>(find.byType(Slider)).max, 1.5);
    // Same look on all devices, compact, all home options, app logos.
    expect(switchValues(tester), [true, false, false, false]);
    final sync = find.byKey(const ValueKey('appearance.sync_appearance'));
    await tester.tap(sync);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(sync).value, isFalse);
    expect(preferences.syncAppearance, isFalse);
    final logos = find.byKey(const ValueKey('appearance.network_logos'));
    await tester.ensureVisible(logos);
    await tester.tap(logos);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(logos).value, isTrue);

    await showPage(tester, chats);
    expect(find.text('Double-tap reaction'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('appearance.haptics')),
          )
          .value,
      isTrue,
    );

    await showPage(tester, media);
    expect(find.text('Show media in timeline'), findsOneWidget);
    expect(
      tester
          .widget<RadioGroup<MediaPreviewMode>>(
            find.byType(RadioGroup<MediaPreviewMode>),
          )
          .groupValue,
      MediaPreviewMode.always,
    );

    await showPage(tester, privacy);
    expect(find.text('Send read receipts'), findsOneWidget);
    // Read receipts, typing notifications, hide invite avatars.
    expect(switchValues(tester), [true, true, false]);
  });

  testWidgets('media preview choice is saved and restored', (tester) async {
    await show(tester, media);
    await tester.ensureVisible(find.text('Show in private rooms'));
    await tester.tap(find.text('Show in private rooms'));
    await tester.pumpAndSettle();
    expect(preferences.mediaPreviewMode, MediaPreviewMode.privateRooms);
    await tester.ensureVisible(find.text('Always hide'));
    await tester.tap(find.text('Always hide'));
    await tester.pumpAndSettle();
    expect(preferences.autoLoadMedia, isFalse);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.mediaPreviewMode, MediaPreviewMode.never);
  });

  testWidgets('all switches update the model and persisted preferences', (
    tester,
  ) async {
    await createPreferences();
    for (final (page, titles) in [
      (appearance, ['Compact layout', 'Show all home options']),
      (chats, ['Haptic feedback']),
      (
        privacy,
        [
          'Hide avatars in room invites',
          'Send read receipts',
          'Send typing notifications',
        ],
      ),
    ]) {
      await showPage(tester, page);
      for (final title in titles) {
        await tester.ensureVisible(find.text(title));
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }
    }
    expect(preferences.compact, isTrue);
    expect(preferences.expandedHome, isTrue);
    expect(preferences.haptics, isFalse);
    expect(preferences.hideInviteAvatars, isTrue);
    expect(preferences.sendReadReceipts, isFalse);
    expect(preferences.sendTypingNotifications, isFalse);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.compact, isTrue);
    expect(restored.expandedHome, isTrue);
    expect(restored.haptics, isFalse);
    expect(restored.hideInviteAvatars, isTrue);
    expect(restored.sendReadReceipts, isFalse);
    expect(restored.sendTypingNotifications, isFalse);
  });

  testWidgets('home row style and message preview are saved and restored', (
    tester,
  ) async {
    await show(tester, appearance);
    expect(preferences.homeRowStyle, HomeRowStyle.cards);
    expect(preferences.homePreview, HomePreview.long);
    await tester.ensureVisible(find.text('Compact'));
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    expect(preferences.homeRowStyle, HomeRowStyle.compact);
    expect(preferences.homePreview, HomePreview.none);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Small'));
    await tester.pumpAndSettle();
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.homeRowStyle, HomeRowStyle.list);
    expect(restored.homePreview, HomePreview.small);
  });

  testWidgets('the double-tap reaction can be changed', (tester) async {
    await show(tester, chats);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appearance.quick_reaction')),
        matching: find.text('❤️'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('appearance.quick_reaction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick-reaction-🔥')));
    await tester.pumpAndSettle();
    expect(preferences.quickReaction, '🔥');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('appearance.quick_reaction')),
        matching: find.text('🔥'),
      ),
      findsOneWidget,
    );
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.quickReaction, '🔥');
  });

  testWidgets('slider changes text size and saves it', (tester) async {
    await show(tester, appearance);
    await tester.drag(find.byType(Slider), const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(preferences.textScale, greaterThan(1));
    expect(preferences.textScale, lessThanOrEqualTo(1.5));
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.textScale, preferences.textScale);
  });

  testWidgets('listens to external model changes', (tester) async {
    await show(tester, appearance);
    await preferences.setTextScale(1.5);
    await preferences.setCompact(true);
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1.5);
    final compact = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Compact layout'),
    );
    expect(compact.value, isTrue);
  });

  testWidgets('disposing a page does not dispose its shared model', (
    tester,
  ) async {
    await show(tester, appearance);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await preferences.setCompact(true);
    expect(preferences.compact, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme cards report the choice', (tester) async {
    final themes = <VisualTheme>[];
    final follows = <bool>[];
    await show(
      tester,
      (preferences) => AppearanceSettingsScreen(
        preferences: preferences,
        onThemeChanged: themes.add,
        onFollowSystemTheme: follows.add,
      ),
    );
    expect(find.text('THEME'), findsOneWidget);
    await tester.tap(find.text('Daybreak'));
    await tester.pumpAndSettle();
    expect(themes, [VisualTheme.daylight]);
    await tester.tap(find.text('Match system'));
    await tester.pumpAndSettle();
    expect(follows, [true]);
  });

  testWidgets('without a theme callback only the preferences are shown', (
    tester,
  ) async {
    await show(tester, appearance);
    expect(find.text('THEME'), findsNothing);
    expect(find.text('Match system'), findsNothing);
  });

  testWidgets('pages remain scrollable on a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await createPreferences();
    for (final (page, last) in [
      (appearance, 'Show all home options'),
      (privacy, 'Send typing notifications'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: page(preferences),
        ),
      );
      await tester.scrollUntilVisible(find.text(last), 160);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}
