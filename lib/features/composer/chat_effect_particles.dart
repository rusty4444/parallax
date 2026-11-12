import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'chat_effects.dart';

/// Lightweight particle systems ported from Element Web's canvas effects
/// (`src/effects/*/index.ts`). Physics run in fixed 60 Hz steps, matching
/// the per-frame constants of the originals.
abstract class EffectParticles {
  EffectParticles(this.random);
  final math.Random random;

  /// While true, systems that respawn particles keep doing so.
  bool spawning = true;

  /// Creates the initial particles for [size].
  void start(Size size);

  /// Advances one 60 Hz frame.
  void step(Size size);
  void paint(Canvas canvas, Size size, double opacity);

  /// No particles remain.
  bool get finished;

  static EffectParticles create(ChatEffectKind kind, math.Random random) =>
      switch (kind) {
        ChatEffectKind.confetti => ConfettiParticles(random),
        ChatEffectKind.fireworks => FireworksParticles(random),
        ChatEffectKind.rainfall => RainfallParticles(random),
        ChatEffectKind.snowfall => SnowfallParticles(random),
        ChatEffectKind.spaceInvaders => SpaceInvaderParticles(random),
        ChatEffectKind.hearts => HeartParticles(random),
      };
}

Color _withOpacity(Color colour, double opacity) =>
    colour.withValues(alpha: colour.a * opacity.clamp(0.0, 1.0));

class _Confetto {
  late Color colour;
  late double x, y, diameter, tilt, tiltAngleIncrement, tiltAngle;
}

/// Confetti: 150 tilting strips falling in a gentle wave; respawned until
/// stopped.
class ConfettiParticles extends EffectParticles {
  ConfettiParticles(super.random);

  static const maxCount = 150;
  static const speed = 3.0;
  static const _colours = [
    Color.fromRGBO(30, 144, 255, 1),
    Color.fromRGBO(107, 142, 35, 1),
    Color.fromRGBO(255, 215, 0, 1),
    Color.fromRGBO(255, 192, 203, 1),
    Color.fromRGBO(106, 90, 205, 1),
    Color.fromRGBO(173, 216, 230, 1),
    Color.fromRGBO(238, 130, 238, 1),
    Color.fromRGBO(152, 251, 152, 1),
    Color.fromRGBO(70, 130, 180, 1),
    Color.fromRGBO(244, 164, 96, 1),
    Color.fromRGBO(210, 105, 30, 1),
    Color.fromRGBO(220, 20, 60, 1),
  ];

  final particles = <_Confetto>[];
  double _waveAngle = 0;

  _Confetto _reset(_Confetto p, Size size) => p
    ..colour = _colours[random.nextInt(_colours.length)]
    ..x = random.nextDouble() * size.width
    ..y = random.nextDouble() * -size.height
    ..diameter = random.nextDouble() * 10 + 5
    ..tilt = random.nextDouble() * -10
    ..tiltAngleIncrement = random.nextDouble() * 0.07 + 0.05
    ..tiltAngle = random.nextDouble() * math.pi;

  @override
  void start(Size size) {
    particles
      ..clear()
      ..addAll([for (var i = 0; i < maxCount; i++) _reset(_Confetto(), size)]);
  }

  @override
  void step(Size size) {
    _waveAngle += 0.01;
    for (var i = 0; i < particles.length; i++) {
      final p = particles[i];
      if (!spawning && p.y < -15) {
        p.y = size.height + 100;
      } else {
        p.tiltAngle += p.tiltAngleIncrement;
        p.x += math.sin(_waveAngle) - 0.5;
        p.y += (math.cos(_waveAngle) + p.diameter + speed) * 0.5;
        p.tilt = math.sin(p.tiltAngle) * 15;
      }
      if (p.x > size.width + 20 || p.x < -20 || p.y > size.height) {
        if (spawning) {
          _reset(p, size);
        } else {
          particles.removeAt(i--);
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final paint = Paint()..strokeCap = StrokeCap.butt;
    for (final p in particles) {
      final x2 = p.x + p.tilt;
      final x = x2 + p.diameter / 2;
      final y2 = p.y + p.tilt + p.diameter / 2;
      paint
        ..strokeWidth = p.diameter
        ..color = _withOpacity(p.colour, opacity);
      canvas.drawLine(Offset(x, p.y), Offset(x2, y2), paint);
    }
  }

  @override
  bool get finished => particles.isEmpty;
}

class _Spark {
  late Color colour;
  late double x, y, vx, vy, w, alpha;
}

/// Fireworks: bursts of 100–150 sparks at random points, with gravity and
/// fading; new bursts until stopped.
class FireworksParticles extends EffectParticles {
  FireworksParticles(super.random);

  static const maxCount = 500;
  static const gravity = 0.05;
  final particles = <_Spark>[];

  @override
  void start(Size size) => particles.clear();

  void _burst(Size size) {
    final width = math.max(size.width - 200, 1.0);
    final height = math.max(size.height - 200, 1.0);
    final cx = random.nextDouble() * width + math.min(100, size.width / 2);
    final cy = random.nextDouble() * height + math.min(100, size.height / 2);
    final count = (random.nextDouble() * 50 + 100).floor();
    final colour = Color.fromRGBO(
      (random.nextDouble() * 200 + 55).floor(),
      (random.nextDouble() * 200 + 55).floor(),
      (random.nextDouble() * 200 + 55).floor(),
      1,
    );
    for (var i = 0; i < count; i++) {
      final w = random.nextDouble() * 4 + 1;
      final p = _Spark()
        ..colour = colour
        ..w = w
        ..x = cx - w / 2
        ..y = cy - w / 2
        ..vx = (random.nextDouble() - 0.5) * 10
        ..vy = (random.nextDouble() - 0.5) * 10
        ..alpha = random.nextDouble() * 0.5 + 0.5;
      final limit = math.sqrt(math.max(0, 25 - p.vx * p.vx));
      if (p.vy.abs() > limit) p.vy = p.vy > 0 ? limit : -limit;
      particles.add(p);
    }
  }

  @override
  void step(Size size) {
    if (spawning && particles.length < maxCount) _burst(size);
    particles.removeWhere((p) {
      p.x += p.vx;
      p.vy += gravity;
      p.y += p.vy;
      p.alpha -= 0.01;
      return p.x <= -p.w ||
          p.x >= size.width ||
          p.y >= size.height ||
          p.alpha <= 0;
    });
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final paint = Paint();
    for (final p in particles) {
      paint.color = _withOpacity(p.colour, p.alpha * opacity);
      canvas.drawCircle(Offset(p.x + p.w / 2, p.y + p.w / 2), p.w, paint);
    }
  }

  @override
  bool get finished => particles.isEmpty && !spawning;
}

class _Drop {
  late double x, y, width, height, speed;
}

/// Rainfall: 600 light-blue streaks.
class RainfallParticles extends EffectParticles {
  RainfallParticles(super.random);

  static const maxCount = 600;
  static const speed = 10.0;
  static const colour = Color(0xFF5DADEC);
  final particles = <_Drop>[];

  @override
  void start(Size size) {
    particles
      ..clear()
      ..addAll([
        for (var i = 0; i < maxCount; i++)
          () {
            final width = random.nextDouble() * 1.5;
            return _Drop()
              ..x = random.nextDouble() * size.width
              ..y = random.nextDouble() * -size.height
              ..width = width
              ..height = width * 15 + 4
              ..speed = random.nextDouble() * speed * 4 / 5 + speed;
          }(),
      ]);
  }

  @override
  void step(Size size) {
    particles.removeWhere((p) {
      p.y += p.speed;
      return p.y > size.height;
    });
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final paint = Paint()..color = _withOpacity(colour, opacity);
    for (final p in particles) {
      canvas.drawRect(Rect.fromLTWH(p.x, p.y, p.width, p.height), paint);
    }
  }

  @override
  bool get finished => particles.isEmpty;
}

class _Flake {
  late double x, xCol, y, diameter, drift, gravity;
}

/// Snowfall: 200 drifting flakes (grey so they show on light themes).
class SnowfallParticles extends EffectParticles {
  SnowfallParticles(super.random);

  static const maxCount = 200;
  static const gravity = 0.05;
  static const maxDrift = 5.0;
  static const colour = Color(0xFFEAEAEA);
  final particles = <_Flake>[];

  @override
  void start(Size size) {
    particles
      ..clear()
      ..addAll([
        for (var i = 0; i < maxCount; i++)
          () {
            final x = random.nextDouble() * size.width;
            return _Flake()
              ..x = x
              ..xCol = x
              ..y = random.nextDouble() * -size.height
              ..diameter = random.nextDouble() * 7 + 4
              ..drift = random.nextDouble() * maxDrift + 3.5
              ..gravity = gravity + random.nextDouble() * 6 + 4;
          }(),
      ]);
  }

  @override
  void step(Size size) {
    particles.removeWhere((p) {
      p.y += p.gravity;
      final peak = 75 * p.drift;
      p.x = p.drift * math.sin((math.pi * 2 / peak) * p.y) + p.xCol;
      return p.y > size.height + p.diameter * 2;
    });
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final fill = Paint()..color = _withOpacity(colour, opacity);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = _withOpacity(const Color(0xFFB8C4CC), opacity);
    for (final p in particles) {
      canvas
        ..drawCircle(Offset(p.x, p.y), p.diameter / 2, fill)
        ..drawCircle(Offset(p.x, p.y), p.diameter / 2, edge);
    }
  }

  @override
  bool get finished => particles.isEmpty;
}

class _Invader {
  late double x, y, gravity;
}

/// Space invaders: 50 falling pixel invaders (Element Web draws 👾).
class SpaceInvaderParticles extends EffectParticles {
  SpaceInvaderParticles(super.random);

  static const maxCount = 50;
  static const gravity = 0.01;
  static const colour = Color(0xFF9B5DE5);

  /// The classic 11×8 invader sprite.
  static const _sprite = [
    '..X.....X..',
    '...X...X...',
    '..XXXXXXX..',
    '.XX.XXX.XX.',
    'XXXXXXXXXXX',
    'X.XXXXXXX.X',
    'X.X.....X.X',
    '...XX.XX...',
  ];
  static const _pixel = 4.0;
  static final ui.Path _shape = () {
    final path = ui.Path();
    for (var row = 0; row < _sprite.length; row++) {
      for (var column = 0; column < _sprite[row].length; column++) {
        if (_sprite[row][column] == 'X') {
          path.addRect(
            Rect.fromLTWH(column * _pixel, row * _pixel, _pixel, _pixel),
          );
        }
      }
    }
    return path;
  }();

  final particles = <_Invader>[];

  @override
  void start(Size size) {
    particles
      ..clear()
      ..addAll([
        for (var i = 0; i < maxCount; i++)
          _Invader()
            ..x = random.nextDouble() * size.width
            ..y = random.nextDouble() * -size.height
            ..gravity = gravity + random.nextDouble() * 6 + 4,
      ]);
  }

  @override
  void step(Size size) {
    particles.removeWhere((p) {
      p.y += p.gravity;
      return p.y > size.height + 40;
    });
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final paint = Paint()..color = _withOpacity(colour, opacity);
    for (final p in particles) {
      canvas
        ..save()
        ..translate(p.x, p.y)
        ..drawPath(_shape, paint)
        ..restore();
    }
  }

  @override
  bool get finished => particles.isEmpty;
}

class _Heart {
  late Color colour;
  late double x, xCol, y, scale, drift, rotation, gravity;
}

/// Hearts: 120 hearts rising from below, swaying and rotating.
class HeartParticles extends EffectParticles {
  HeartParticles(super.random);

  static const maxCount = 120;
  static const gravity = 3.2;
  static const maxDrift = 5.0;
  static const maxRot = 5.0;
  static const _colours = [
    Color.fromRGBO(194, 210, 224, 1),
    Color.fromRGBO(235, 214, 219, 1),
    Color.fromRGBO(255, 211, 45, 1),
    Color.fromRGBO(255, 190, 174, 1),
    Color.fromRGBO(255, 173, 226, 1),
    Color.fromRGBO(242, 114, 171, 1),
    Color.fromRGBO(228, 55, 116, 1),
    Color.fromRGBO(255, 86, 130, 1),
    Color.fromRGBO(244, 36, 57, 1),
    Color.fromRGBO(247, 126, 157, 1),
    Color.fromRGBO(243, 142, 140, 1),
    Color.fromRGBO(252, 116, 183, 1),
  ];

  /// Element Web's heart outline, centred at (248, 215).
  static final ui.Path _shape = ui.Path()
    ..moveTo(140, 20)
    ..cubicTo(73, 20, 20, 74, 20, 140)
    ..cubicTo(20, 275, 156, 310, 248, 443)
    ..cubicTo(336, 311, 477, 270, 477, 140)
    ..cubicTo(477, 74, 423, 20, 357, 20)
    ..cubicTo(309, 20, 267, 48, 248, 89)
    ..cubicTo(229, 48, 188, 20, 140, 20)
    ..close();

  final particles = <_Heart>[];

  @override
  void start(Size size) {
    particles
      ..clear()
      ..addAll([
        for (var i = 0; i < maxCount; i++)
          () {
            final x = random.nextDouble() * size.width;
            return _Heart()
              ..colour = _colours[random.nextInt(_colours.length)]
              ..x = x
              ..xCol = x
              ..y = random.nextDouble() * size.height + size.height
              ..scale = random.nextDouble() * 0.07 + 0.04
              ..drift = random.nextDouble() * maxDrift + 3.5
              ..rotation = random.nextDouble() * maxRot + 3.5
              ..gravity = gravity + random.nextDouble() * 4.8;
          }(),
      ]);
  }

  @override
  void step(Size size) {
    particles.removeWhere((p) {
      p.y -= p.gravity;
      final peak = 75 * p.drift;
      p.x = 6 * p.drift * math.sin(0.7 * (math.pi * 2 / peak) * p.y) + p.xCol;
      return p.y < -100;
    });
  }

  @override
  void paint(Canvas canvas, Size size, double opacity) {
    final paint = Paint();
    for (final p in particles) {
      final peak = 75 * p.drift;
      final angle =
          0.1 * p.rotation * math.sin((math.pi * 2 / peak) * p.y * 0.8);
      paint.color = _withOpacity(p.colour, opacity);
      canvas
        ..save()
        ..translate(p.x, p.y)
        ..scale(p.scale)
        ..translate(248, 215)
        ..rotate(angle)
        ..translate(-248, -215)
        ..drawPath(_shape, paint)
        ..restore();
    }
  }

  @override
  bool get finished => particles.isEmpty;
}
