// App font (Settings → Appearance → Font): the catalogue, its licences, the
// theme it builds, the saved preference, the picker, and a sweep that draws
// the main screens in every font, with the real font files loaded, to prove
// every section uses the chosen font and nothing overflows.
//
// Set PARALLAX_SCREENSHOT_DIR to also save PNGs of the sweep:
//   PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/app_fonts_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/appearance_settings_screen.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/app_fonts/app_font_picker.dart';
import 'package:parallax/features/app_fonts/app_fonts.dart';
import 'package:parallax/features/home/home_features.dart';
import 'package:parallax/features/message_fonts/message_fonts.dart';
import 'package:parallax/inbox_screen.dart';
import 'package:parallax/main.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/room_screen.dart';
import 'package:parallax/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_fakes.dart';
import 'messaging_integration_test.dart' show Drafts;
import 'widget_test.dart' show FakeBackend, FakeBackgroundStore;

const _appFontKey = 'parallax.appearance.v1.app_font';
final _shots = Platform.environment['PARALLAX_SCREENSHOT_DIR'];
final _boundary = GlobalKey();

/// Families allowed besides the app font: icon glyphs and code.
const _otherFamilies = {'MaterialIcons', 'monospace'};

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final path in files) {
    loader.addFont(
      File(path).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
    );
  }
  await loader.load();
}

/// The asset files pubspec.yaml declares for [family].
List<String> _declaredAssets(String pubspec, String family) {
  final block = RegExp(
    '- family: $family\\n((?:\\s+(?:fonts:|- asset: \\S+|weight: \\d+)\\n)+)',
  ).firstMatch(pubspec);
  if (block == null) return const [];
  return [
    for (final m in RegExp(r'- asset: (\S+)').allMatches(block.group(1)!))
      m.group(1)!,
  ];
}

/// Every (family, text) pair drawn on screen: plain and rich text, and the
/// text in input fields. A span without its own family inherits its
/// parent's, as the engine does.
List<(String?, String)> _drawnText(WidgetTester tester) {
  final drawn = <(String?, String)>[];
  void visit(InlineSpan span, String? inherited) {
    final family = span.style?.fontFamily ?? inherited;
    if (span is TextSpan) {
      final text = span.text;
      if (text != null && text.trim().isNotEmpty) drawn.add((family, text));
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, family);
      }
    }
  }

  for (final object in tester.allRenderObjects) {
    if (object is RenderParagraph) visit(object.text, null);
    if (object is RenderEditable) {
      final text = object.text;
      if (text != null) visit(text, null);
    }
  }
  return drawn;
}

void _expectDrawnIn(WidgetTester tester, String family, String screen) {
  final drawn = _drawnText(tester);
  expect(drawn, isNotEmpty, reason: screen);
  final strays = [
    for (final (f, text) in drawn)
      if (f != family && !_otherFamilies.contains(f)) '$f: "$text"',
  ];
  expect(strays, isEmpty, reason: '$screen should be drawn in $family');
}

List<TextStyle> _styles(TextTheme t) => [
  t.displayLarge!,
  t.displayMedium!,
  t.displaySmall!,
  t.headlineLarge!,
  t.headlineMedium!,
  t.headlineSmall!,
  t.titleLarge!,
  t.titleMedium!,
  t.titleSmall!,
  t.bodyLarge!,
  t.bodyMedium!,
  t.bodySmall!,
  t.labelLarge!,
  t.labelMedium!,
  t.labelSmall!,
];

Future<void> _capture(WidgetTester tester, String name) async {
  final dir = _shots;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

ChatRoom _room(
  String id,
  String name,
  String preview, {
  bool direct = false,
  int unread = 0,
  String? sender,
}) => ChatRoom(
  id: id,
  name: name,
  preview: preview,
  lastActivity: DateTime(2026, 11, 21, 9, 41),
  isDirect: direct,
  unread: unread,
  previewSender: sender,
);

HomeFakeBackend _homeBackend() => HomeFakeBackend()
  ..roomList = [
    _room('!p:x', 'Quinn Harper', 'Photo', direct: true),
    _room('!t:x', 'Weekend plans', 'Bring snacks', sender: 'Mia', unread: 4),
    _room('!c:x', 'Climbing crew', 'Who is in for Sunday?', unread: 12),
    _room('!a:x', 'Alex', 'See you then', direct: true),
    _room('!w:x', 'Work', 'Standup moved to 10', sender: 'You'),
  ]
  ..spaces = const [
    HomeSpace(id: '!s1:x', name: 'Friends'),
    HomeSpace(id: '!s2:x', name: 'Discover'),
  ];

FakeBackend _roomBackend() => FakeBackend()
  ..entries = [
    ChatEntry(
      id: '1',
      sender: '@mia:x',
      senderName: 'Mia',
      body: 'Are we still on for Saturday morning?',
      time: DateTime(2026, 11, 21, 9, 30),
      mine: false,
      reactions: const [ChatReaction(emoji: '👍', count: 2, mine: true)],
    ),
    ChatEntry(
      id: '2',
      sender: '@me:x',
      body: 'Yes! Meet at the café at 9, then the long walk along the coast.',
      time: DateTime(2026, 11, 21, 9, 32),
      mine: true,
    ),
    ChatEntry(
      id: '3',
      sender: '@mia:x',
      senderName: 'Mia',
      body: 'Perfect, see you there',
      time: DateTime(2026, 11, 21, 9, 33),
      mine: false,
    ),
  ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('catalogue', () {
    test('IDs are stable, unique and well formed', () {
      expect(appFonts.map((font) => font.id), [
        'spacegrotesk',
        'system',
        'figtree',
        'outfit',
        'manrope',
        'karla',
        'nunito',
        'quicksand',
        'josefinsans',
        'atkinson',
        'lexend',
        'lora',
        'librebaskerville',
        'bitter',
        'jetbrainsmono',
        'comicneue',
        'caveat',
      ]);
      expect(appFonts.first, same(defaultAppFont));
      expect(appFonts.map((font) => font.label).toSet(), hasLength(17));
      expect(appFonts.where((font) => font.isSystem).map((f) => f.id), [
        'system',
      ]);
      for (final font in appFonts) {
        expect(RegExp(r'^[a-z0-9]{1,32}$').hasMatch(font.id), isTrue);
        expect(font.description, isNotEmpty);
        expect(font.licenceAsset == null, font.isSystem, reason: font.id);
      }
    });

    test('lookup resolves known IDs only', () {
      expect(appFontById('lora')?.family, 'Lora');
      expect(appFontById('system')?.family, isNull);
      expect(appFontById(null), isNull);
      expect(appFontById('Lora'), isNull);
      expect(appFontById('wingdings'), isNull);
      expect(appFontById(''), isNull);
    });

    test('every bundled font is declared, TrueType and licensed', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final font in appFonts.where((font) => !font.isSystem)) {
        final assets = _declaredAssets(pubspec, font.family!);
        expect(assets, isNotEmpty, reason: font.family);
        for (final asset in assets) {
          final bytes = File(asset).readAsBytesSync();
          // A TrueType outline font starts with version 1.0 (00 01 00 00).
          expect(bytes.sublist(0, 4), [0, 1, 0, 0], reason: asset);
        }
        final licence = File(font.licenceAsset!).readAsStringSync();
        expect(licence, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(licence, contains('Copyright'));
      }
      // Comic Neue now has a real bold for headings and bold text.
      expect(_declaredAssets(pubspec, 'ComicNeue'), [
        'assets/fonts/ComicNeue-Regular.ttf',
        'assets/fonts/ComicNeue-Bold.ttf',
      ]);
    });

    test('licence entries cover each bundled font once', () async {
      final entries = await appFontLicences().toList();
      final packages = [for (final e in entries) ...e.packages];
      final messageLabels = {for (final f in messageFonts) '${f.label} font'};
      final expected = [
        for (final font in appFonts)
          if (!font.isSystem && !messageLabels.contains('${font.label} font'))
            '${font.label} font',
      ];
      expect(packages, expected);
      // Comic Neue's licence is already listed as a message font.
      expect(packages, isNot(contains('Comic Neue font')));
      expect(packages, contains('Space Grotesk font'));
      for (final entry in entries) {
        final text = entry.paragraphs.map((p) => p.text).join('\n');
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(text, isNot(contains('\r')));
      }
      final grotesk = entries.first.paragraphs.map((p) => p.text).join('\n');
      expect(grotesk, contains('The Space Grotesk Project Authors'));
    });
  });

  group('theme', () {
    test('a bundled font is used by every text style and chips', () {
      for (final font in appFonts.where((font) => !font.isSystem)) {
        final theme = themeFor(VisualTheme.parallax, font);
        final styles = [
          ..._styles(theme.textTheme),
          ..._styles(theme.primaryTextTheme),
          theme.chipTheme.labelStyle!,
        ];
        for (final style in styles) {
          expect(style.fontFamily, font.family, reason: font.id);
        }
      }
    });

    test('the default stays Space Grotesk', () {
      expect(
        themeFor(VisualTheme.parallax).textTheme.bodyMedium!.fontFamily,
        'SpaceGrotesk',
      );
      expect(
        themeFor(VisualTheme.parallax, defaultAppFont),
        same(themeFor(VisualTheme.parallax)),
      );
    });

    test('themes are cached per palette and font', () {
      final lora = appFontById('lora')!;
      expect(
        themeFor(VisualTheme.ember, lora),
        same(themeFor(VisualTheme.ember, lora)),
      );
      expect(
        themeFor(VisualTheme.ember, lora),
        isNot(same(themeFor(VisualTheme.daylight, lora))),
      );
      expect(
        themeFor(VisualTheme.ember, lora).scaffoldBackgroundColor,
        paletteFor(VisualTheme.ember).background,
      );
    });

    test('the system font follows the platform', () {
      final system = appFontById('system')!;
      String? family(TargetPlatform platform) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final theme = themeFor(VisualTheme.parallax, system);
          return theme.textTheme.bodyMedium!.fontFamily;
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }

      expect(family(TargetPlatform.android), 'Roboto');
      expect(family(TargetPlatform.windows), 'Segoe UI');
      expect(family(TargetPlatform.iOS), 'CupertinoSystemText');
      expect(family(TargetPlatform.macOS), '.AppleSystemUIFont');
      // The picker previews it in the platform's face, not the app font.
      expect(
        appFontPreviewStyle(
          system,
          platform: TargetPlatform.windows,
        ).fontFamily,
        'Segoe UI',
      );
      expect(appFontPreviewStyle(appFontById('karla')!).fontFamily, 'Karla');
    });
  });

  group('preferences', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('Space Grotesk until another font is chosen', () async {
      final preferences = AppearancePreferences();
      addTearDown(preferences.dispose);
      expect(preferences.appFont, same(defaultAppFont));
      await preferences.load();
      expect(preferences.appFont, same(defaultAppFont));
    });

    test('the font is saved, restored and notified once', () async {
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppearancePreferences(prefs: prefs);
      addTearDown(preferences.dispose);
      var notified = 0;
      preferences.addListener(() => notified++);
      await preferences.setAppFont('nunito');
      await preferences.setAppFont('nunito');
      expect(notified, 1);
      expect(preferences.appFont.family, 'Nunito');
      expect(prefs.getString(_appFontKey), 'nunito');

      final restored = AppearancePreferences(prefs: prefs);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.appFont.id, 'nunito');

      await preferences.setAppFont('spacegrotesk');
      expect(preferences.appFont, same(defaultAppFont));
      expect(prefs.getString(_appFontKey), 'spacegrotesk');
    });

    test('unknown fonts are refused and not saved', () async {
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppearancePreferences(prefs: prefs);
      addTearDown(preferences.dispose);
      await expectLater(
        preferences.setAppFont('wingdings'),
        throwsArgumentError,
      );
      expect(prefs.getString(_appFontKey), isNull);
      expect(preferences.appFont, same(defaultAppFont));
    });

    test('a stored font this version does not know loads as default', () async {
      SharedPreferences.setMockInitialValues({_appFontKey: 'future-font'});
      final preferences = AppearancePreferences();
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(preferences.appFont, same(defaultAppFont));
      SharedPreferences.setMockInitialValues({_appFontKey: 42});
      final malformed = AppearancePreferences();
      addTearDown(malformed.dispose);
      await malformed.load();
      expect(malformed.appFont, same(defaultAppFont));
    });
  });

  group('settings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('Appearance offers every font and saves the choice', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppearancePreferences(prefs: prefs);
      addTearDown(preferences.dispose);
      await preferences.load();
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: AppearanceSettingsScreen(preferences: preferences)),
      );
      await tester.pumpAndSettle();

      final row = find.byKey(const ValueKey('appearance.app_font'));
      expect(
        find.descendant(of: row, matching: find.text('Space Grotesk')),
        findsOneWidget,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      for (final font in appFonts) {
        final option = find.byKey(ValueKey('app-font-${font.id}'));
        await tester.scrollUntilVisible(
          option,
          80,
          scrollable: find
              .descendant(
                of: find.byType(AppFontSheet),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          tester.widget<ListTile>(option).selected,
          font.id == 'spacegrotesk',
          reason: font.id,
        );
        // Each option is drawn in its own face.
        final label = tester.widget<Text>(
          find.descendant(of: option, matching: find.text(font.label)),
        );
        expect(
          label.style?.fontFamily,
          appFontPreviewStyle(font).fontFamily,
          reason: font.id,
        );
      }
      await tester.tap(find.byKey(const ValueKey('app-font-lora')));
      await tester.pumpAndSettle();
      expect(preferences.appFont.id, 'lora');
      expect(prefs.getString(_appFontKey), 'lora');
      expect(
        find.descendant(of: row, matching: find.text('Lora')),
        findsOneWidget,
      );

      // Dismissing the sheet keeps the font.
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('app-font-lora')))
            .selected,
        isTrue,
      );
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(preferences.appFont.id, 'lora');
    });

    testWidgets('the whole app switches font at once', (tester) async {
      SharedPreferences.setMockInitialValues({_appFontKey: 'bitter'});
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
      String? appFamily() => tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .theme!
          .textTheme
          .bodyMedium!
          .fontFamily;
      expect(appFamily(), 'Bitter');
      await preferences.setAppFont('caveat');
      await tester.pumpAndSettle();
      expect(appFamily(), 'Caveat');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('every screen in every font', () {
    setUpAll(() async {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final font in appFonts.where((font) => !font.isSystem)) {
        await _loadFont(font.family!, _declaredAssets(pubspec, font.family!));
      }
      final shots = _shots;
      if (shots != null) Directory(shots).createSync(recursive: true);
      // The system font in tests is Android's Roboto; the SDK ships it
      // with the Material icons.
      final root = Platform.environment['FLUTTER_ROOT'];
      if (root != null) {
        final fonts = '$root/bin/cache/artifacts/material_fonts';
        final icons = File('$fonts/MaterialIcons-Regular.otf');
        if (icons.existsSync()) {
          await _loadFont('MaterialIcons', [icons.path]);
        }
        final roboto = [
          for (final weight in ['Regular', 'Medium', 'Bold'])
            '$fonts/Roboto-$weight.ttf',
        ];
        if (roboto.every((path) => File(path).existsSync())) {
          await _loadFont('Roboto', roboto);
        }
      }
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> frame(WidgetTester tester, Size size, Widget child) async {
      tester.view
        ..physicalSize = size * 3
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: _boundary, child: child));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    Widget app(AppFont font, AppearancePreferences prefs, Widget home) =>
        FeatureSettingsScope(
          preferences: prefs,
          draftStore: Drafts(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: themeFor(VisualTheme.parallax, font),
            home: home,
          ),
        );

    final palette = paletteFor(VisualTheme.parallax);
    // A typical phone and a small one.
    const sizes = {'phone': Size(393, 830), 'small': Size(320, 640)};

    for (final font in appFonts) {
      final family = font.family ?? 'Roboto';
      for (final MapEntry(key: sizeName, value: size) in sizes.entries) {
        testWidgets('${font.id} on a $sizeName screen', (tester) async {
          final prefs = AppearancePreferences();
          addTearDown(prefs.dispose);
          await prefs.setExpandedHome(true);
          await prefs.setAppFont(font.id);
          final shot = '${font.id}_$sizeName';

          await frame(
            tester,
            size,
            app(
              font,
              prefs,
              InboxScreen(
                backend: _homeBackend(),
                palette: palette,
                style: VisualTheme.parallax,
                onThemeChanged: (_) {},
              ),
            ),
          );
          expect(find.text('Weekend plans'), findsOneWidget);
          _expectDrawnIn(tester, family, 'home');
          await _capture(tester, '${shot}_home');

          await frame(
            tester,
            size,
            app(
              font,
              prefs,
              RoomScreen(
                backend: _roomBackend(),
                palette: palette,
                roomId: '!room:x',
                draftStore: Drafts(),
                backgroundStore: FakeBackgroundStore(),
              ),
            ),
          );
          expect(find.text('Perfect, see you there'), findsOneWidget);
          await tester.enterText(find.byType(TextField).last, 'On my way');
          await tester.pump();
          _expectDrawnIn(tester, family, 'room');
          await _capture(tester, '${shot}_room');

          await frame(
            tester,
            size,
            app(
              font,
              prefs,
              SettingsScreen(
                backend: HomeFakeBackend(),
                palette: palette,
                style: VisualTheme.parallax,
                onThemeChanged: (_) {},
                setSecureWindow: (_) async {},
              ),
            ),
          );
          _expectDrawnIn(tester, family, 'settings');
          await _capture(tester, '${shot}_settings');

          await frame(
            tester,
            size,
            app(
              font,
              prefs,
              AppearanceSettingsScreen(
                preferences: prefs,
                onThemeChanged: (_) {},
              ),
            ),
          );
          _expectDrawnIn(tester, family, 'appearance');
          final fontRow = find.byKey(const ValueKey('appearance.app_font'));
          await tester.scrollUntilVisible(
            fontRow,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await _capture(tester, '${shot}_appearance');
          await tester.tap(fontRow);
          await tester.pumpAndSettle();
          await _capture(tester, '${shot}_picker');
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 11));
        });
      }
    }
  });
}
