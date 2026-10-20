import 'package:flutter/material.dart';

enum VisualTheme { ultraviolet, ember, daylight }

extension VisualThemeName on VisualTheme {
  String get label => switch (this) {
    VisualTheme.ultraviolet => 'Ultraviolet',
    VisualTheme.ember => 'Afterglow',
    VisualTheme.daylight => 'Daybreak',
  };

  String get caption => switch (this) {
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
}

AppPalette paletteFor(VisualTheme style) => switch (style) {
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

ThemeData themeFor(VisualTheme style) {
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
  );
}

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
