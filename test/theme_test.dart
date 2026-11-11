import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';

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
}

double _contrast(Color a, Color b) {
  final lighter = math.max(a.computeLuminance(), b.computeLuminance());
  final darker = math.min(a.computeLuminance(), b.computeLuminance());
  return (lighter + 0.05) / (darker + 0.05);
}
