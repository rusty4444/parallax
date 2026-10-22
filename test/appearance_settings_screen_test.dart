import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrixpress/appearance_preferences.dart';
import 'package:matrixpress/appearance_settings_screen.dart';
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
    // Create async queues in the widget test's zone, not setUp's real zone.
    preferences = AppearancePreferences(prefs: prefs);
    await preferences.load();
    await tester.pumpWidget(
      MaterialApp(home: AppearanceSettingsScreen(preferences: preferences)),
    );
  }

  testWidgets('renders each preference with its default value', (tester) async {
    await showScreen(tester);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Compact layout'), findsOneWidget);
    expect(find.text('Auto-load media'), findsOneWidget);
    expect(find.text('Send read receipts'), findsOneWidget);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
    expect(tester.widget<Slider>(find.byType(Slider)).min, 0.85);
    expect(tester.widget<Slider>(find.byType(Slider)).max, 1.5);
    final switches = tester.widgetList<SwitchListTile>(
      find.byType(SwitchListTile),
    );
    expect(switches.map((tile) => tile.value), [false, true, true]);
  });

  testWidgets('all switches update the model and persisted preferences', (
    tester,
  ) async {
    await showScreen(tester);
    for (final title in [
      'Compact layout',
      'Auto-load media',
      'Send read receipts',
    ]) {
      await tester.ensureVisible(find.text(title));
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }
    expect(preferences.compact, isTrue);
    expect(preferences.autoLoadMedia, isFalse);
    expect(preferences.sendReadReceipts, isFalse);
    final restored = AppearancePreferences(prefs: prefs);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.compact, isTrue);
    expect(restored.autoLoadMedia, isFalse);
    expect(restored.sendReadReceipts, isFalse);
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
    await tester.scrollUntilVisible(find.text('Send read receipts'), 160);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
