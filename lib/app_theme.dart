import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Visual themes. [parallax] is the brand default; the others are alternatives.
enum VisualTheme { parallax, parallaxDay, ultraviolet, ember, daylight }

/// The theme used before any preference is loaded or when none is saved.
const defaultVisualTheme = VisualTheme.parallax;

/// Stored theme preference value meaning "Match system".
const systemThemePreference = 'system';

/// The Parallax palette that matches the platform's light/dark setting.
VisualTheme visualThemeForBrightness(Brightness brightness) =>
    brightness == Brightness.dark
    ? VisualTheme.parallax
    : VisualTheme.parallaxDay;

/// Fixed brand colours for the Parallax mark (independent of the active theme).
abstract final class ParallaxBrand {
  static const crimson = Color(0xFFD7263D);
  static const vermilion = Color(0xFFFF5A36);
  static const amber = Color(0xFFFFB238);
  static const ink = Color(0xFF130A0B);

  /// Back-to-front layer gradients used by the logo.
  static const layers = <List<Color>>[
    [Color(0xFF8E1230), Color(0xFFC41E3E)],
    [Color(0xFFE42C22), Color(0xFFFF4E2E)],
    [Color(0xFFFF8428), Color(0xFFFFC84C)],
  ];
}

extension VisualThemeName on VisualTheme {
  String get label => switch (this) {
    VisualTheme.parallax => 'Parallax',
    VisualTheme.parallaxDay => 'Parallax Day',
    VisualTheme.ultraviolet => 'Ultraviolet',
    VisualTheme.ember => 'Afterglow',
    VisualTheme.daylight => 'Daybreak',
  };

  String get caption => switch (this) {
    VisualTheme.parallax => 'Ember ink · vermilion · amber',
    VisualTheme.parallaxDay => 'Warm paper · vermilion · rust',
    VisualTheme.ultraviolet => 'Electric violet · mint',
    VisualTheme.ember => 'Midnight ink · warm coral',
    VisualTheme.daylight => 'Soft ivory · cobalt',
  };
}

@immutable
class AppPalette {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.raised,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.accentOn,
    required this.secondary,
    required this.stroke,
    required this.bubble,
    required this.bubbleText,
  });

  final Color background;
  final Color surface;
  final Color raised;
  final Color foreground;
  final Color muted;
  final Color accent;
  final Color accentOn;
  final Color secondary;
  final Color stroke;
  final Color bubble;
  final Color bubbleText;

  bool get isDark => background.computeLuminance() < 0.4;

  AppPalette copyWith({
    Color? surface,
    Color? foreground,
    Color? muted,
    Color? accent,
    Color? accentOn,
    Color? secondary,
    Color? bubble,
    Color? bubbleText,
  }) => AppPalette(
    background: background,
    surface: surface ?? this.surface,
    raised: raised,
    foreground: foreground ?? this.foreground,
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    accentOn: accentOn ?? this.accentOn,
    secondary: secondary ?? this.secondary,
    stroke: stroke,
    bubble: bubble ?? this.bubble,
    bubbleText: bubbleText ?? this.bubbleText,
  );

  /// This palette for content drawn on [fill] (a message bubble whose text
  /// is [text]), whatever colours the room chose: accent marks keep 3:1
  /// there, and secondary and muted text 4.5:1 (or as close as the bubble's
  /// own text gets), darkening or lightening the way [text] does. The fill
  /// colours themselves are unchanged.
  AppPalette inkOn(Color fill, {Color? text}) {
    final mark = legibleOn(fill, accent, minRatio: 3, toward: text);
    return copyWith(
      accent: mark,
      accentOn: legibleOn(mark, accentOn),
      secondary: legibleOn(fill, secondary, toward: text),
      muted: legibleOn(fill, muted, toward: text),
    );
  }

  // Value equality: derived palettes (per-room bubble colours) must compare
  // equal across rebuilds so rendered message text stays cached.
  @override
  bool operator ==(Object other) =>
      other is AppPalette &&
      other.background == background &&
      other.surface == surface &&
      other.raised == raised &&
      other.foreground == foreground &&
      other.muted == muted &&
      other.accent == accent &&
      other.accentOn == accentOn &&
      other.secondary == secondary &&
      other.stroke == stroke &&
      other.bubble == bubble &&
      other.bubbleText == bubbleText;

  @override
  int get hashCode => Object.hash(
    background,
    surface,
    raised,
    foreground,
    muted,
    accent,
    accentOn,
    secondary,
    stroke,
    bubble,
    bubbleText,
  );
}

/// WCAG 2 contrast ratio of two colours (alpha ignored): 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

const _darkInk = Color(0xFF141414);
const _lightInk = Color(0xFFFFFFFF);

/// Text colour for [background]: white while it reads at 3:1 or better (so
/// saturated bubbles keep white text), otherwise near-black, which is then
/// at least 6:1.
Color readableOn(Color background) =>
    contrastRatio(_lightInk, background) >= 3 ? _lightInk : _darkInk;

/// [colour] when it reads at [minRatio] on [background] (translucent
/// colours are judged as drawn). Otherwise the same hue moved just far
/// enough towards [toward] (the text colour beside it, so accents match the
/// text; default [readableOn]), or towards [readableOn] when [toward] cannot
/// get there, or all the way to the better of the two when neither can.
Color legibleOn(
  Color background,
  Color colour, {
  double minRatio = 4.5,
  Color? toward,
}) {
  final drawn = Color.alphaBlend(colour, background);
  if (contrastRatio(drawn, background) >= minRatio) return colour;
  final fallback = readableOn(background);
  var target = toward == null ? fallback : Color.alphaBlend(toward, background);
  if (contrastRatio(target, background) < minRatio &&
      contrastRatio(fallback, background) > contrastRatio(target, background)) {
    target = fallback;
  }
  if (contrastRatio(target, background) <= minRatio) return target;
  // Contrast only grows past the background's luminance on the way to
  // [target], so the colours that pass form one range ending at [target].
  var low = 0.0;
  var high = 1.0;
  for (var i = 0; i < 16; i++) {
    final mid = (low + high) / 2;
    final candidate = Color.lerp(drawn, target, mid)!;
    if (contrastRatio(candidate, background) >= minRatio) {
      high = mid;
    } else {
      low = mid;
    }
  }
  return Color.lerp(drawn, target, high)!;
}

AppPalette paletteFor(VisualTheme style) => switch (style) {
  VisualTheme.parallax => const AppPalette(
    background: Color(0xFF130A0B),
    surface: Color(0xFF1F1214),
    raised: Color(0xFF2C1A1C),
    foreground: Color(0xFFFFF3EE),
    muted: Color(0xFFD4BCB5),
    accent: Color(0xFFFF5A36),
    accentOn: Color(0xFF2B0700),
    secondary: Color(0xFFFFB238),
    stroke: Color(0xFF4D2D2C),
    bubble: Color(0xFFB02A1A),
    bubbleText: Color(0xFFFFFFFF),
  ),
  VisualTheme.parallaxDay => const AppPalette(
    background: Color(0xFFFFF7F2),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFFBE7DF),
    foreground: Color(0xFF2A0F0A),
    muted: Color(0xFF6E4B44),
    accent: Color(0xFFC4321A),
    accentOn: Color(0xFFFFFFFF),
    secondary: Color(0xFF9A4500),
    stroke: Color(0xFFEBCFC5),
    bubble: Color(0xFFBF3A20),
    bubbleText: Color(0xFFFFFFFF),
  ),
  VisualTheme.ultraviolet => const AppPalette(
    background: Color(0xFF0C0A18),
    surface: Color(0xFF171426),
    raised: Color(0xFF211D35),
    foreground: Color(0xFFF5F2FF),
    muted: Color(0xFFB8B1CC),
    accent: Color(0xFFB895FF),
    accentOn: Color(0xFF1A0C38),
    secondary: Color(0xFF9EF2D8),
    stroke: Color(0xFF423951),
    bubble: Color(0xFF503378),
    bubbleText: Color(0xFFFFFFFF),
  ),
  VisualTheme.ember => const AppPalette(
    background: Color(0xFF11121B),
    surface: Color(0xFF1B1E2B),
    raised: Color(0xFF282C3C),
    foreground: Color(0xFFF8F2F0),
    muted: Color(0xFFC3BFCB),
    accent: Color(0xFFFFB095),
    accentOn: Color(0xFF39170E),
    secondary: Color(0xFF82DCED),
    stroke: Color(0xFF444557),
    bubble: Color(0xFF713E3A),
    bubbleText: Color(0xFFFFFFFF),
  ),
  VisualTheme.daylight => const AppPalette(
    background: Color(0xFFF8F5EE),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFECEAF9),
    foreground: Color(0xFF14132E),
    muted: Color(0xFF565472),
    accent: Color(0xFF3126B1),
    accentOn: Color(0xFFFFFFFF),
    secondary: Color(0xFF065B5C),
    stroke: Color(0xFFD4D0E5),
    bubble: Color(0xFF342BB3),
    bubbleText: Color(0xFFFFFFFF),
  ),
};

final _themes = <VisualTheme, ThemeData>{};

/// The app theme for [style], built once: `ColorScheme.fromSeed` is costly,
/// and a new (equal) theme on each app rebuild made every route compare
/// whole themes.
ThemeData themeFor(VisualTheme style) => _themes[style] ??= _buildTheme(style);

ThemeData _buildTheme(VisualTheme style) {
  final palette = paletteFor(style);
  final brightness = palette.isDark ? Brightness.dark : Brightness.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: palette.accent,
        brightness: brightness,
        surface: palette.background,
      ).copyWith(
        primary: palette.accent,
        onPrimary: palette.accentOn,
        secondary: palette.secondary,
        onSecondary: palette.background,
        onSurface: palette.foreground,
        outline: palette.stroke,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'SpaceGrotesk',
    scaffoldBackgroundColor: palette.background,
    colorScheme: scheme,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      hintStyle: TextStyle(color: palette.muted),
      labelStyle: TextStyle(color: palette.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: palette.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: palette.stroke),
      ),
    ),
    textTheme: Typography.material2021(platform: TargetPlatform.android).white
        .apply(
          fontFamily: 'SpaceGrotesk',
          bodyColor: palette.foreground,
          displayColor: palette.foreground,
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.foreground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.accent,
      foregroundColor: palette.accentOn,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.raised,
      contentTextStyle: TextStyle(color: palette.foreground),
      actionTextColor: palette.secondary,
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.surface,
      selectedColor: palette.accent.withValues(alpha: 0.22),
      side: BorderSide(color: palette.stroke),
      labelStyle: TextStyle(
        color: palette.foreground,
        fontFamily: 'SpaceGrotesk',
      ),
    ),
    dividerTheme: DividerThemeData(color: palette.stroke),
  );
}

/// Brand gradient for primary surfaces (buttons, outgoing highlights).
LinearGradient accentGradient(AppPalette palette) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color.lerp(palette.accent, palette.bubble, 0.25)!,
    palette.accent,
    Color.lerp(palette.accent, palette.secondary, 0.45)!,
  ],
);

class GlowBackdrop extends StatelessWidget {
  const GlowBackdrop({
    super.key,
    required this.palette,
    this.child,
    this.imageLayer,
  });
  final AppPalette palette;
  final Widget? child;
  final Widget? imageLayer;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ColoredBox(color: palette.background),
      IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(1.15, -0.95),
              radius: 1.1,
              colors: [
                palette.accent.withValues(alpha: 0.22),
                palette.background.withValues(alpha: 0),
              ],
              stops: const [0, 1],
            ),
          ),
        ),
      ),
      IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-1.1, 1.2),
              radius: 1,
              colors: [
                palette.secondary.withValues(alpha: 0.11),
                palette.background.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
      ?imageLayer,
      ?child,
    ],
  );
}
