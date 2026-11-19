import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/features/home/settings_widgets.dart';
import 'package:parallax/features/platform/desktop_content_insets.dart';

void main() {
  final platforms = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  testWidgets(
    'pushed settings and fullscreen controls clear native chrome',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      final top = defaultTargetPlatform == TargetPlatform.macOS
          ? kDesktopTitleBarHeight
          : 0.0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: themeFor(VisualTheme.parallax),
          builder: (_, child) => DesktopContentInsets(child: child!),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsPage(
            palette: paletteFor(VisualTheme.parallax),
            eyebrow: 'SETTINGS',
            title: 'Appearance',
            children: const [Text('Settings content')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.widgetWithIcon(IconButton, Icons.arrow_back_rounded);
      expect(tester.getTopLeft(back).dy, greaterThanOrEqualTo(top));
      expect(tester.getTopLeft(back).dy, lessThan(top + 24));
      await tester.tap(back);
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (context) => Scaffold(
            appBar: AppBar(
              leading: IconButton(
                key: const ValueKey('close-media'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            body: const SafeArea(child: Text('Media content')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('close-media'));
      expect(tester.getTopLeft(close).dy, greaterThanOrEqualTo(top));
      expect(tester.getTopLeft(close).dy, lessThan(top + 16));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(close, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: platforms,
  );

  testWidgets(
    'insets preserve larger safe areas, keyboard and bottom padding',
    (tester) async {
      late MediaQueryData actual;
      const original = MediaQueryData(
        size: Size(900, 700),
        padding: EdgeInsets.fromLTRB(3, 50, 5, 21),
        viewPadding: EdgeInsets.fromLTRB(3, 50, 5, 21),
        viewInsets: EdgeInsets.only(bottom: 240),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: original,
          child: DesktopContentInsets(
            child: Builder(
              builder: (context) {
                actual = MediaQuery.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(actual.padding, original.padding);
      expect(actual.viewPadding, original.viewPadding);
      expect(actual.viewInsets, original.viewInsets);
      expect(actual.size, original.size);
    },
    variant: platforms,
  );
}
