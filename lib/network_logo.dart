import 'package:flutter/widgets.dart';

import 'app_theme.dart';
import 'chat_network.dart';

part 'network_logo_paths.dart';

/// Brand colours (Simple Icons). Matrix and X are black marks, drawn in the
/// theme's foreground instead so they show on dark themes.
const _brandColours = <ChatNetwork, Color>{
  ChatNetwork.whatsapp: Color(0xFF25D366),
  ChatNetwork.googleMessages: Color(0xFF1A73E8),
  ChatNetwork.messenger: Color(0xFF0866FF),
  ChatNetwork.instagram: Color(0xFFFF0069),
  ChatNetwork.discord: Color(0xFF5865F2),
  ChatNetwork.linkedin: Color(0xFF0A66C2),
  ChatNetwork.xbox: Color(0xFF107C10),
};

/// A chat's app logo: the white mark on a brand-coloured circle. Drawn from
/// vector paths built into the app (parsed once), so nothing is downloaded
/// or decoded.
class NetworkLogo extends StatelessWidget {
  const NetworkLogo({
    super.key,
    required this.network,
    required this.palette,
    this.size = 52,
    this.semanticLabel,
  }) : assert(network != ChatNetwork.otherBridge);

  final ChatNetwork network;
  final AppPalette palette;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final brand = _brandColours[network];
    return Semantics(
      label: semanticLabel ?? network.label,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _LogoPainter(
          glyph: networkLogoPath(network),
          background: brand ?? palette.foreground,
          foreground: brand == null
              ? palette.background
              : const Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

final _parsed = <ChatNetwork, Path>{};

/// [network]'s logo in a 24 x 24 box.
Path networkLogoPath(ChatNetwork network) => _parsed[network] ??= parseSvgPath(
  _logoPaths[network] ?? _logoPaths[ChatNetwork.matrix]!,
);

class _LogoPainter extends CustomPainter {
  _LogoPainter({
    required this.glyph,
    required this.background,
    required this.foreground,
  });

  final Path glyph;
  final Color background;
  final Color foreground;

  /// Share of the circle's diameter the mark fills.
  static const _glyphScale = 0.56;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final centre = size.center(Offset.zero);
    canvas.drawCircle(centre, radius, Paint()..color = background);
    final scale = size.shortestSide * _glyphScale / 24;
    canvas
      ..save()
      ..translate(centre.dx - 12 * scale, centre.dy - 12 * scale)
      ..scale(scale)
      ..drawPath(glyph, Paint()..color = foreground)
      ..restore();
  }

  @override
  bool shouldRepaint(_LogoPainter old) =>
      !identical(glyph, old.glyph) ||
      background != old.background ||
      foreground != old.foreground;
}

/// Parses SVG path data (`d`): M L H V C S Q T A Z, absolute and relative,
/// with SVG's compact number syntax ("1.5.5", "-1-1", packed arc flags).
/// Fill rule non-zero, as SVG's default. Throws [FormatException] on bad
/// data.
Path parseSvgPath(String data) {
  final scanner = _PathScanner(data);
  final path = Path();
  var command = '';
  var x = 0.0, y = 0.0;
  var startX = 0.0, startY = 0.0;
  // Last control point, for the smooth curve commands.
  double? cubicX, cubicY, quadX, quadY;
  while (!scanner.atEnd) {
    if (scanner.atCommand) {
      command = scanner.command();
    } else if (command.isEmpty || command == 'Z' || command == 'z') {
      throw FormatException('Path data without a command', data, scanner.i);
    }
    final relative = command == command.toLowerCase();
    final dx = relative ? x : 0.0;
    final dy = relative ? y : 0.0;
    double? nextCubicX, nextCubicY, nextQuadX, nextQuadY;
    switch (command.toUpperCase()) {
      case 'M':
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // Further pairs are line segments.
        command = relative ? 'l' : 'L';
      case 'L':
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.lineTo(x, y);
      case 'H':
        x = dx + scanner.number();
        path.lineTo(x, y);
      case 'V':
        y = dy + scanner.number();
        path.lineTo(x, y);
      case 'C':
        final x1 = dx + scanner.number(), y1 = dy + scanner.number();
        final x2 = dx + scanner.number(), y2 = dy + scanner.number();
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        nextCubicX = x2;
        nextCubicY = y2;
      case 'S':
        final x1 = cubicX == null ? x : 2 * x - cubicX;
        final y1 = cubicY == null ? y : 2 * y - cubicY;
        final x2 = dx + scanner.number(), y2 = dy + scanner.number();
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.cubicTo(x1, y1, x2, y2, x, y);
        nextCubicX = x2;
        nextCubicY = y2;
      case 'Q':
        final x1 = dx + scanner.number(), y1 = dy + scanner.number();
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.quadraticBezierTo(x1, y1, x, y);
        nextQuadX = x1;
        nextQuadY = y1;
      case 'T':
        final x1 = quadX == null ? x : 2 * x - quadX;
        final y1 = quadY == null ? y : 2 * y - quadY;
        x = dx + scanner.number();
        y = dy + scanner.number();
        path.quadraticBezierTo(x1, y1, x, y);
        nextQuadX = x1;
        nextQuadY = y1;
      case 'A':
        final rx = scanner.number().abs(), ry = scanner.number().abs();
        final rotation = scanner.number();
        final largeArc = scanner.flag();
        final sweep = scanner.flag();
        x = dx + scanner.number();
        y = dy + scanner.number();
        // SVG's sweep flag 1 is clockwise on screen (y grows downwards).
        path.arcToPoint(
          Offset(x, y),
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: largeArc,
          clockwise: sweep,
        );
      case 'Z':
        path.close();
        x = startX;
        y = startY;
      default:
        throw FormatException('Unknown path command $command', data, scanner.i);
    }
    cubicX = nextCubicX;
    cubicY = nextCubicY;
    quadX = nextQuadX;
    quadY = nextQuadY;
  }
  return path;
}

class _PathScanner {
  _PathScanner(this.data);
  final String data;
  int i = 0;

  static const _commands = 'MmLlHhVvCcSsQqTtAaZz';
  static final _number = RegExp(r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');

  void _skip() {
    while (i < data.length && ' ,\t\n\r'.contains(data[i])) {
      i++;
    }
  }

  bool get atEnd {
    _skip();
    return i >= data.length;
  }

  bool get atCommand {
    _skip();
    return i < data.length && _commands.contains(data[i]);
  }

  String command() {
    _skip();
    return data[i++];
  }

  double number() {
    _skip();
    final match = _number.matchAsPrefix(data, i);
    if (match == null) throw FormatException('Expected a number', data, i);
    i = match.end;
    return double.parse(match[0]!);
  }

  /// An arc flag: a single 0 or 1, possibly packed against what follows.
  bool flag() {
    _skip();
    if (i >= data.length) throw FormatException('Expected a flag', data, i);
    final char = data[i++];
    if (char == '0') return false;
    if (char == '1') return true;
    throw FormatException('Expected an arc flag', data, i - 1);
  }
}
