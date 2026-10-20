import 'package:flutter/material.dart';
import 'app_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.palette, this.size = 46});
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.31),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [palette.accent, palette.secondary],
      ),
      boxShadow: [
        BoxShadow(
          color: palette.accent.withValues(alpha: 0.25),
          blurRadius: 22,
          offset: const Offset(0, 6),
        ),
      ],
    ),
    alignment: Alignment.center,
    child: Text(
      '×',
      style: TextStyle(
        color: palette.accentOn,
        fontSize: size * 0.72,
        fontWeight: FontWeight.w700,
        height: 1,
      ),
    ),
  );
}

class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.palette,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final AppPalette palette;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 54,
    child: FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon ?? Icons.arrow_forward_rounded, size: 20),
      label: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          fontSize: 16,
        ),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.accentOn,
        disabledBackgroundColor: palette.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      ),
    ),
  );
}

class InitialAvatar extends StatelessWidget {
  const InitialAvatar({
    super.key,
    required this.name,
    required this.palette,
    this.size = 52,
  });
  final String name;
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          palette.accent.withValues(alpha: 0.47),
          palette.secondary.withValues(alpha: 0.27),
        ],
      ),
      border: Border.all(color: palette.accent.withValues(alpha: 0.4)),
    ),
    alignment: Alignment.center,
    child: Text(
      name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
      style: TextStyle(
        color: palette.foreground,
        fontSize: size * 0.38,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, required this.palette});
  final String text;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      color: palette.secondary,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 2.3,
    ),
  );
}
