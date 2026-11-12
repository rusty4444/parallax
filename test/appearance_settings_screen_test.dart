import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/appearance_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late AppearancePreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // Finish model setup inside each widget test's fake-async zone.
  });

  tearDown(() => preferences.dispose());

  Future<void> showScreen(WidgetTester tester) async {
    // Tall enough that the lazily built list holds every card.
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Create async queues in the widget test's zone, not setUp's real zone.
    preferences = AppearancePreferences(prefs: prefs);
    await preferences.load();
    await tester.pumpWidget(
      MaterialApp(home: AppearanceSettingsScreen(preferences: preferences)),
    );
  }

  testWidgets('renders each preference with its default value', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await showScreen(tester);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Compact layout'), findsOneWidget);
    expect(find.text('Show media in timeline'), findsOneWidget);
    expect(find.text('Send read receipts'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
    expect(tester.widget<Slider>(find.byType(Slider)).min, 0.85);
    expect(tester.widget<Slider>(find.byType(Slider)).max, 1.5);
    expect(
      tester
          .widget<RadioGroup<MediaPreviewMode>>(
            find.byType(RadioGroup<MediaPreviewMode>),
          )
          .groupValue,
      MediaPreviewMode.always,
    );
    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    // Compact, all home options, haptics, hide invite avatars, read
    // receipts, typing notifications.
    expect(switches.map((tile) => tile.value), [
      false,
      false,
      true,
      false,
      true,
      true,
    ]);
  });

  testWidgets('media preview choice is saved and restored', (tester) async {
    await showScreen(tester);
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
    await showScreen(tester);
    for (final title in [
      'Compact layout',
      'Show all home options',
      'Haptic feedback',
      'Hide avatars in room invites',
      'Send read receipts',
      'Send typing notifications',
    ]) {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
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

  testWidgets('slider changes text size and saves it', (tester) async {
    await showScreen(tester);
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
    await showScreen(tester);
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

  testWidgets('disposing the screen does not dispose its shared model', (
    tester,
  ) async {
    await showScreen(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await preferences.setCompact(true);
    expect(preferences.compact, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remains scrollable on a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    preferences = AppearancePreferences(prefs: prefs);
    await preferences.load();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.8)),
          child: child!,
        ),
        home: AppearanceSettingsScreen(preferences: preferences),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Send typing notifications'),
      160,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
