import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';

void main() {
  testWidgets('Windows AppBar actions sit left of the caption buttons', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallax),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                key: const ValueKey('action'),
                icon: const Icon(Icons.share_outlined),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final actionRight = tester
        .getRect(find.byKey(const ValueKey('action')))
        .right;
    // The shell pins 3 caption buttons (3 * kDesktopCaptionButtonWidth) at
    // the top-right; AppBar actions must end before that zone.
    expect(
      actionRight,
      lessThanOrEqualTo(1280 - 3 * kDesktopCaptionButtonWidth + 1),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android AppBar actions keep the default padding', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeFor(VisualTheme.parallaxDay),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                key: const ValueKey('action'),
                icon: const Icon(Icons.share_outlined),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final actionRight = tester
        .getRect(find.byKey(const ValueKey('action')))
        .right;
    expect(actionRight, greaterThan(1280 - 3 * kDesktopCaptionButtonWidth));
    debugDefaultTargetPlatformOverride = null;
  });
}
