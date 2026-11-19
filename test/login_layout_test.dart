import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/login_screen.dart';
import 'package:parallax/widgets.dart';

import 'widget_test.dart' show FakeBackend;

void main() {
  Future<void> pumpLogin(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: LoginScreen(
          backend: FakeBackend(),
          palette: paletteFor(VisualTheme.parallax),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('wide desktop layout fits the whole sign-in form on screen', (
    tester,
  ) async {
    await pumpLogin(tester, const Size(1280, 800));
    // Branding sits beside the sign-in card, not above it.
    final brand = tester.getRect(find.byType(BrandMark));
    final cardHeader = tester.getRect(find.text('SIGN IN TO MATRIX'));
    expect(brand.right, lessThan(cardHeader.left));
    // Every part of the form is on screen without scrolling.
    for (final label in [
      'Homeserver',
      'Matrix ID or username',
      'Password',
      'Enter the matrix',
    ]) {
      final rect = tester.getRect(find.text(label));
      expect(rect.top, greaterThanOrEqualTo(0), reason: '$label above screen');
      expect(rect.bottom, lessThanOrEqualTo(800), reason: '$label below fold');
    }
  });

  testWidgets('wide layout still works when the window is short', (
    tester,
  ) async {
    await pumpLogin(tester, const Size(1280, 620));
    // The form scrolls rather than overflowing; nothing renders off-screen
    // without a way to reach it.
    final scrollable = find.byType(Scrollable);
    expect(scrollable, findsWidgets);
    await tester.ensureVisible(find.text('Enter the matrix'));
    await tester.pumpAndSettle();
    final button = tester.getRect(find.text('Enter the matrix'));
    expect(button.bottom, lessThanOrEqualTo(620));
  });

  testWidgets('phone layout keeps the original vertical column', (
    tester,
  ) async {
    await pumpLogin(tester, const Size(460, 900));
    final brand = tester.getRect(find.byType(BrandMark));
    final cardHeader = tester.getRect(find.text('SIGN IN TO MATRIX'));
    expect(brand.bottom, lessThan(cardHeader.top));
  });
}
