import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/main.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend;

void main() {
  test('all palettes keep primary text and buttons legible', () {
    for (final style in VisualTheme.values) {
      final p = paletteFor(style);
      expect(
        _contrast(p.foreground, p.background),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: foreground',
      );
      expect(
        _contrast(p.accentOn, p.accent),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: action',
      );
      expect(
        _contrast(p.bubbleText, p.bubble),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: outgoing bubble',
      );
      expect(
        _contrast(p.muted, p.surface),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: muted text on cards',
      );
    }
  });

  test('Match system picks the Parallax palette for the brightness', () {
    expect(visualThemeForBrightness(Brightness.dark), VisualTheme.parallax);
    expect(visualThemeForBrightness(Brightness.light), VisualTheme.parallaxDay);
  });

  testWidgets('a saved Match system theme follows platform brightness', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'visual_theme': systemThemePreference,
    });
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final preferences = AppearancePreferences();
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      ParallaxApp(
        backend: FakeBackend(),
        preferences: preferences,
        draftStore: MessageDraftStore(),
      ),
    );
    await tester.pumpAndSettle();
    Color background() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .scaffoldBackgroundColor;
    expect(background(), paletteFor(VisualTheme.parallaxDay).background);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(background(), paletteFor(VisualTheme.parallax).background);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

double _contrast(Color a, Color b) {
  final lighter = math.max(a.computeLuminance(), b.computeLuminance());
  final darker = math.min(a.computeLuminance(), b.computeLuminance());
  return (lighter + 0.05) / (darker + 0.05);
}
