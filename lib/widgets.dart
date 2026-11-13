import 'package:flutter/material.dart';
import 'app_theme.dart';

/// The Parallax app mark on its ember tile, matching the launcher icon.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.palette, this.size = 46});
  // Retained for API compatibility; the brand mark uses fixed brand colours.
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Parallax',
    image: true,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2E0C0C), Color(0xFF100608)],
        ),
        boxShadow: [
          BoxShadow(
            color: ParallaxBrand.vermilion.withValues(alpha: 0.28),
            blurRadius: size * 0.42,
            offset: Offset(0, size * 0.1),
          ),
        ],
      ),
      child: CustomPaint(painter: const ParallaxMarkPainter(scale: 0.62)),
    ),
  );
}

/// Three offset message bubbles (crimson, vermilion, amber) separated by
/// transparent gaps. Geometry mirrors tools/generate_icon.py.
class ParallaxMarkPainter extends CustomPainter {
  const ParallaxMarkPainter({this.scale = 0.82});

  /// Mark width as a fraction of the shortest side.
  final double scale;

  static const _offsets = [
    Offset(-0.14, 0.14),
    Offset.zero,
    Offset(0.14, -0.14),
  ];
  static const _lift = 0.045;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide * scale;
    final centre = size.center(Offset.zero);
    final gap = unit * 0.026;
    canvas.saveLayer(Offset.zero & size, Paint());
    for (var i = 0; i < _offsets.length; i++) {
      final offset = _offsets[i];
      final c = centre + Offset(offset.dx * unit, (offset.dy - _lift) * unit);
      final body = _bubble(c, unit);
      // Cut a gap around this layer from everything already painted behind it.
      final halo = Paint()
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.stroke
        ..strokeWidth = gap * 2
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(body, halo);
      canvas.drawPath(body, Paint()..blendMode = BlendMode.clear);
      final colors = ParallaxBrand.layers[i];
      final bounds = body.getBounds();
      canvas.drawPath(
        body,
        Paint()
          ..isAntiAlias = true
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ).createShader(bounds),
      );
    }
    canvas.restore();
  }

  static Path _bubble(Offset c, double unit) {
    final w = unit * 0.62, h = unit * 0.48, r = unit * 0.17;
    final left = c.dx - w / 2, top = c.dy - h / 2;
    final body = Path()
      ..addRRect(
        RRect.fromLTRBR(left, top, left + w, top + h, Radius.circular(r)),
      );
    final tail = Path()
      ..moveTo(left + w * 0.56, top + h * 0.80)
      ..lineTo(left + w * 0.82, top + h * 0.80)
      ..lineTo(left + w * 0.90, top + h * 1.17)
      ..lineTo(left + w * 0.85, top + h * 1.19)
      ..close();
    return Path.combine(PathOperation.union, body, tail);
  }

  @override
  bool shouldRepaint(ParallaxMarkPainter oldDelegate) =>
      oldDelegate.scale != scale;
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
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(17),
        gradient: onPressed == null ? null : accentGradient(palette),
      ),
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
          backgroundColor: Colors.transparent,
          foregroundColor: palette.accentOn,
          disabledBackgroundColor: palette.raised,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(17),
          ),
        ),
      ),
    ),
  );
}

/// Picks a single initial for [name], skipping a leading Matrix `@` sigil so
/// unresolved user IDs show the localpart's letter instead of `@`.
String avatarInitial(String name) {
  var trimmed = name.trim();
  if (trimmed.startsWith('@') && trimmed.length > 1) {
    trimmed = trimmed.substring(1).trimLeft();
  }
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
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
      avatarInitial(name),
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
