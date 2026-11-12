import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../media_player_owner.dart';

/// Plays an animated GIF/WebP frame by frame from a bounded, owned codec.
///
/// Header dimensions are validated before any frame is decoded and each frame
/// is decoded at the same capped size as the poster. Exactly one decoded frame
/// is held at a time; frames are disposed as they are replaced. Animation stops
/// when tickers are muted (route hidden) or the platform asks to reduce motion,
/// leaving [poster] (the first frame) on screen. The widget never takes
/// ownership of [poster].
class AnimatedMediaImage extends StatefulWidget {
  const AnimatedMediaImage({
    super.key,
    required this.bytes,
    required this.poster,
    this.fit = BoxFit.contain,
    this.semanticLabel,
  });

  final Uint8List bytes;
  final ui.Image poster;
  final BoxFit fit;
  final String? semanticLabel;

  @override
  State<AnimatedMediaImage> createState() => _AnimatedMediaImageState();
}

class _AnimatedMediaImageState extends State<AnimatedMediaImage> {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  int _generation = 0;
  bool _active = false;
  bool _animating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active =
        TickerMode.valuesOf(context).enabled &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (active == _active) return;
    _active = active;
    if (active) {
      unawaited(_start());
    } else {
      _stop(rebuild: false);
    }
  }

  @override
  void didUpdateWidget(AnimatedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _stop(rebuild: false);
      if (_active) unawaited(_start());
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    final bytes = widget.bytes;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final size = mediaImageDecodeSize(descriptor.width, descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth: size.width,
        targetHeight: size.height,
      );
      if (!mounted || generation != _generation || codec.frameCount <= 1) {
        codec.dispose();
        return;
      }
      _codec = codec;
      codec = null;
      _animating = true;
      await _nextFrame(generation);
    } catch (_) {
      // Corrupt or unsupported animation: the poster stays visible.
      codec?.dispose();
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _nextFrame(int generation) async {
    final codec = _codec;
    if (codec == null || !mounted || generation != _generation) return;
    final ui.FrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } catch (_) {
      if (generation == _generation) _stop();
      return;
    }
    if (!mounted || generation != _generation) {
      frame.image.dispose();
      return;
    }
    final previous = _frame;
    setState(() => _frame = frame.image);
    previous?.dispose();
    // Browsers treat 0–10 ms frame delays as 100 ms; so do we.
    var delay = frame.duration;
    if (delay <= const Duration(milliseconds: 10)) {
      delay = const Duration(milliseconds: 100);
    }
    _timer = Timer(delay, () => unawaited(_nextFrame(generation)));
  }

  /// [rebuild] is false when a build follows anyway (dependency/widget
  /// updates), where calling setState is not allowed.
  void _stop({bool rebuild = true}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _codec?.dispose();
    _codec = null;
    _animating = false;
    final frame = _frame;
    _frame = null;
    frame?.dispose();
    if (rebuild && mounted) setState(() {});
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _codec?.dispose();
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.semanticLabel,
    image: true,
    child: RawImage(
      image: _animating ? (_frame ?? widget.poster) : widget.poster,
      fit: widget.fit,
    ),
  );
}
