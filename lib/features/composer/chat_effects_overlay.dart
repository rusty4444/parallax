import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../chat_backend.dart';
import 'chat_effect_particles.dart';
import 'chat_effects.dart';
import 'chat_effects_preferences.dart';

/// Plays chat effects above the room timeline when a new message (arriving
/// after the room was opened, including your own) carries an effect
/// `msgtype` or trigger emoji. Never for history, never while "Show chat
/// effects" is off or the system asks to reduce motion. Ignores pointers.
class ChatEffectsOverlay extends StatefulWidget {
  const ChatEffectsOverlay({
    super.key,
    required this.backend,
    required this.roomId,
    this.preferences,
    this.random,
    this.openedAt,
  });

  final ChatBackend backend;
  final String roomId;

  /// Defaults to [ChatEffectsPreferences.shared].
  final ChatEffectsPreferences? preferences;

  /// For deterministic tests.
  final math.Random? random;
  final DateTime? openedAt;

  /// Effects stop spawning after this (Element Web's 3 s timeout) …
  static const spawnDuration = Duration(seconds: 3);

  /// … and are cleared, fading out, by this.
  static const maxDuration = Duration(seconds: 5);
  static const _fade = Duration(milliseconds: 600);

  /// At most this many effects play at once.
  static const maxConcurrent = 3;

  @override
  State<ChatEffectsOverlay> createState() => _ChatEffectsOverlayState();
}

class _PlayingEffect {
  _PlayingEffect(this.kind, this.particles, this.startedAt);
  final ChatEffectKind kind;
  final EffectParticles particles;
  final Duration startedAt;
  double steps = 0;
}

class _ChatEffectsOverlayState extends State<ChatEffectsOverlay>
    with SingleTickerProviderStateMixin {
  late ChatEffectTracker _tracker;
  late final Ticker _ticker;
  late final math.Random _random = widget.random ?? math.Random();
  final _repaint = _Repaint();
  final _playing = <_PlayingEffect>[];
  final _pending = <ChatEffectKind>[];
  Duration _elapsed = Duration.zero;
  Size _size = Size.zero;
  bool _reduceMotion = false;

  ChatEffectsPreferences get _prefs =>
      widget.preferences ?? ChatEffectsPreferences.shared;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _tracker = ChatEffectTracker(openedAt: widget.openedAt);
    widget.backend.addListener(_observe);
    _prefs.addListener(_preferenceChanged);
    unawaited(_prefs.ensureLoaded());
    _observe();
  }

  @override
  void didUpdateWidget(ChatEffectsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend) ||
        oldWidget.roomId != widget.roomId) {
      oldWidget.backend.removeListener(_observe);
      widget.backend.addListener(_observe);
      _tracker = ChatEffectTracker(openedAt: widget.openedAt);
      _lastMessages = null;
      _stopAll();
      _observe();
    }
    final previous = oldWidget.preferences ?? ChatEffectsPreferences.shared;
    if (!identical(previous, _prefs)) {
      previous.removeListener(_preferenceChanged);
      _prefs.addListener(_preferenceChanged);
      unawaited(_prefs.ensureLoaded());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduceMotion) _stopAll();
  }

  @override
  void dispose() {
    widget.backend.removeListener(_observe);
    _prefs.removeListener(_preferenceChanged);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _preferenceChanged() {
    if (!_prefs.showChatEffects) _stopAll();
  }

  bool get _allowed => _prefs.showChatEffects && !_reduceMotion;

  /// Messages last given to the tracker.
  List<ChatEntry>? _lastMessages;

  void _observe() {
    if (!mounted) return;
    final backend = widget.backend;
    // Only this room's timeline: another room's (or an empty) projection
    // must not prime the tracker.
    if (backend.activeRoomId != widget.roomId) return;
    // Most notifications aren't new messages (sync, sending, progress);
    // the projection keeps its identity until the timeline changes.
    final messages = backend.messages;
    if (identical(messages, _lastMessages)) return;
    _lastMessages = messages;
    final List<ChatEffect> effects;
    try {
      effects = _tracker.observe(messages);
    } catch (_) {
      return;
    }
    if (effects.isEmpty || !_allowed) return;
    _pending.addAll(effects.map((effect) => effect.kind));
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _startPending());
    } else {
      _startPending();
    }
  }

  void _startPending() {
    if (!mounted || _pending.isEmpty) return;
    final kinds = [..._pending];
    _pending.clear();
    if (!_allowed) return;
    setState(() {
      for (final kind in kinds) {
        // Restart an effect already playing rather than doubling it.
        _playing.removeWhere((effect) => effect.kind == kind);
        while (_playing.length >= ChatEffectsOverlay.maxConcurrent) {
          _playing.removeAt(0);
        }
        final particles = EffectParticles.create(kind, _random);
        if (!_size.isEmpty) particles.start(_size);
        _playing.add(_PlayingEffect(kind, particles, _elapsed));
      }
    });
    if (!_ticker.isActive) {
      _elapsed = Duration.zero;
      for (final effect in _playing) {
        effect.steps = 0;
      }
      _restartTimes();
      _ticker.start();
    }
  }

  void _restartTimes() {
    for (var i = 0; i < _playing.length; i++) {
      final effect = _playing[i];
      _playing[i] = _PlayingEffect(effect.kind, effect.particles, _elapsed);
    }
  }

  void _stopAll() {
    _pending.clear();
    if (_playing.isEmpty && !_ticker.isActive) return;
    _playing.clear();
    if (_ticker.isActive) _ticker.stop();
    if (mounted &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks) {
      setState(() {});
    }
  }

  void _tick(Duration elapsed) {
    _elapsed = elapsed;
    final size = _size;
    for (final effect in _playing) {
      final age = elapsed - effect.startedAt;
      if (age >= ChatEffectsOverlay.spawnDuration) {
        effect.particles.spawning = false;
      }
      if (size.isEmpty) continue;
      // Fixed 60 Hz physics steps; never more than 4 per frame after a stall.
      final target = age.inMicroseconds / Duration.microsecondsPerSecond * 60;
      var budget = 4;
      while (effect.steps < target && budget-- > 0) {
        effect.particles.step(size);
        effect.steps++;
      }
      if (effect.steps < target) effect.steps = target.floorToDouble();
    }
    final before = _playing.length;
    _playing.removeWhere(
      (effect) =>
          effect.particles.finished ||
          elapsed - effect.startedAt >= ChatEffectsOverlay.maxDuration,
    );
    if (_playing.isEmpty) {
      _ticker.stop();
      setState(() {});
      return;
    }
    if (_playing.length != before) setState(() {});
    _repaint.notify();
  }

  double _opacity(_PlayingEffect effect) {
    final remaining =
        ChatEffectsOverlay.maxDuration - (_elapsed - effect.startedAt);
    if (remaining >= ChatEffectsOverlay._fade) return 1;
    return remaining.inMicroseconds / ChatEffectsOverlay._fade.inMicroseconds;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size.isFinite && size != _size) {
            final wasEmpty = _size.isEmpty;
            _size = size;
            if (wasEmpty) {
              for (final effect in _playing) {
                effect.particles.start(size);
              }
            }
          }
          if (_playing.isEmpty) return const SizedBox.expand();
          // Own layer: each animation frame repaints only the particles,
          // not the room header, composer and background beneath.
          return RepaintBoundary(
            child: CustomPaint(
              key: const ValueKey('chat-effects-canvas'),
              size: Size.infinite,
              painter: _EffectsPainter(this),
            ),
          );
        },
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _EffectsPainter extends CustomPainter {
  _EffectsPainter(this.state) : super(repaint: state._repaint);
  final _ChatEffectsOverlayState state;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final effect in state._playing) {
      effect.particles.paint(canvas, size, state._opacity(effect));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EffectsPainter oldDelegate) => true;
}

/// Kinds currently playing in [element]'s overlay (for tests).
@visibleForTesting
List<ChatEffectKind> playingChatEffects(Element element) {
  final state = (element as StatefulElement).state;
  return state is _ChatEffectsOverlayState
      ? [for (final effect in state._playing) effect.kind]
      : const [];
}
