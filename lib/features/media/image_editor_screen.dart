import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../messaging_features.dart';

/// One freehand markup stroke in rotated, full-image coordinates (0…1).
@immutable
class MarkupStroke {
  const MarkupStroke({required this.color, required this.points});
  final int color;
  final List<Offset> points;
}

@immutable
class ImageEditSpec {
  const ImageEditSpec({
    required this.bytes,
    required this.name,
    required this.rotation,
    required this.crop,
    required this.strokes,
  });
  final Uint8List bytes;
  final String name;

  /// Clockwise quarter turns.
  final int rotation;
  final Rect crop;
  final List<MarkupStroke> strokes;
}

/// Opens the crop/rotate/markup editor. Null means the edit was cancelled.
Future<MediaSelection?> showImageEditor(
  BuildContext context,
  MediaSelection source,
) => Navigator.of(context).push<MediaSelection>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ImageEditorScreen(source: source),
  ),
);

/// Applies an edit off the UI thread. The original attachment is never changed.
MediaSelection processImageEdit(ImageEditSpec spec) {
  final decoder = img.findDecoderForData(spec.bytes);
  final decoded = decoder?.decode(spec.bytes, frame: 0);
  if (decoded == null) throw const FormatException('Unsupported image data');
  var source = img.bakeOrientation(decoded);
  const maxEdge = 4096;
  if (math.max(source.width, source.height) > maxEdge) {
    source = img.copyResize(
      source,
      width: source.width >= source.height ? maxEdge : null,
      height: source.height > source.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }
  final turns = spec.rotation % 4;
  final rotated = turns == 0
      ? source
      : img.copyRotate(source, angle: -90 * turns);
  final width = rotated.width;
  final height = rotated.height;
  final crop = spec.crop;
  final x = (crop.left * width).round().clamp(0, width - 1);
  final y = (crop.top * height).round().clamp(0, height - 1);
  final right = (crop.right * width).round().clamp(x + 1, width);
  final bottom = (crop.bottom * height).round().clamp(y + 1, height);
  final output = img.copyCrop(
    rotated,
    x: x,
    y: y,
    width: right - x,
    height: bottom - y,
  );
  for (final stroke in spec.strokes) {
    if (stroke.points.isEmpty) continue;
    final color = _rgb(stroke.color);
    final thickness = math.max(1, (0.006 * math.max(width, height)).round());
    final first = stroke.points.first;
    var previous = Offset(first.dx * width - x, first.dy * height - y);
    for (final point in stroke.points.skip(1)) {
      final next = Offset(point.dx * width - x, point.dy * height - y);
      img.drawLine(
        output,
        x1: previous.dx.round(),
        y1: previous.dy.round(),
        x2: next.dx.round(),
        y2: next.dy.round(),
        color: color,
        thickness: thickness,
        antialias: true,
      );
      previous = next;
    }
    if (stroke.points.length == 1) {
      img.drawLine(
        output,
        x1: previous.dx.round(),
        y1: previous.dy.round(),
        x2: previous.dx.round(),
        y2: previous.dy.round(),
        color: color,
        thickness: thickness,
        antialias: true,
      );
    }
  }
  final dot = spec.name.lastIndexOf('.');
  final base = (dot > 0 ? spec.name.substring(0, dot) : spec.name).trim();
  return MediaSelection(
    bytes: img.encodeJpg(output, quality: 90),
    name: '${base.isEmpty ? 'image' : base}-edited.jpg',
    mimeType: 'image/jpeg',
  );
}

img.ColorRgb8 _rgb(int value) =>
    img.ColorRgb8((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff);

class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.source});
  final MediaSelection source;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _EditorMode { crop, markup }

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  static const _minCrop = 0.08;
  static const _colors = [
    Color(0xFFFF5252),
    Color(0xFFFFD740),
    Color(0xFF69F0AE),
    Color(0xFF40C4FF),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
  ];

  late final img.DecodeInfo? _header = img
      .findDecoderForData(widget.source.bytes)
      ?.startDecode(widget.source.bytes);
  _EditorMode _mode = _EditorMode.crop;
  int _rotation = 0;
  Rect _crop = const Rect.fromLTWH(0, 0, 1, 1);
  final _strokes = <MarkupStroke>[];
  List<Offset>? _current;
  int _color = _colors.first.toARGB32();
  int? _cropCorner;
  Offset? _panLast;
  Rect _cropAtStart = const Rect.fromLTWH(0, 0, 1, 1);
  bool _busy = false;

  double get _aspect {
    final header = _header;
    if (header == null) return 1;
    return _rotation.isEven
        ? header.width / header.height
        : header.height / header.width;
  }

  void _rotate() {
    Offset rotate(Offset point) => Offset(1 - point.dy, point.dx);
    setState(() {
      _rotation = (_rotation + 1) % 4;
      _crop = Rect.fromLTRB(
        1 - _crop.bottom,
        _crop.left,
        1 - _crop.top,
        _crop.right,
      );
      for (var i = 0; i < _strokes.length; i++) {
        _strokes[i] = MarkupStroke(
          color: _strokes[i].color,
          points: [for (final point in _strokes[i].points) rotate(point)],
        );
      }
      _current = null;
      _cropCorner = null;
    });
  }

  void _start(Offset local, Size size) {
    _panLast = local;
    _cropAtStart = _crop;
    final point = _normal(local, size);
    if (_mode == _EditorMode.markup) {
      if (!_crop.contains(point)) return;
      setState(() => _current = [point]);
      return;
    }
    final rect = _pixels(_crop, size);
    final handles = _handles(rect);
    const radius = 30.0;
    for (var i = 0; i < handles.length; i++) {
      if ((local - handles[i]).distance <= radius) {
        _cropCorner = i;
        return;
      }
    }
    _cropCorner = rect.contains(local) ? -1 : null;
  }

  void _update(Offset local, Size size) {
    if (_mode == _EditorMode.markup) {
      final current = _current;
      if (current == null) return;
      final point = _normal(local, size);
      if (!_crop.contains(point)) return;
      if ((point - current.last).distance < 0.002) return;
      setState(() => current.add(point));
      return;
    }
    final corner = _cropCorner;
    if (corner == null) return;
    final previous = _panLast;
    if (previous == null) return;
    final delta = Offset(
      (local.dx - previous.dx) / size.width,
      (local.dy - previous.dy) / size.height,
    );
    final start = _cropAtStart;
    if (corner == -1) {
      final left = (start.left + delta.dx).clamp(0.0, 1 - start.width);
      final top = (start.top + delta.dy).clamp(0.0, 1 - start.height);
      setState(
        () => _crop = Rect.fromLTWH(left, top, start.width, start.height),
      );
      return;
    }
    var left = start.left, top = start.top;
    var right = start.right, bottom = start.bottom;
    final point = _normal(local, size);
    if (corner == 0 || corner == 2) {
      left = point.dx.clamp(0.0, right - _minCrop);
    }
    if (corner == 0 || corner == 1) {
      top = point.dy.clamp(0.0, bottom - _minCrop);
    }
    if (corner == 1 || corner == 3) {
      right = point.dx.clamp(left + _minCrop, 1.0);
    }
    if (corner == 2 || corner == 3) {
      bottom = point.dy.clamp(top + _minCrop, 1.0);
    }
    setState(() => _crop = Rect.fromLTRB(left, top, right, bottom));
  }

  void _end() {
    final current = _current;
    if (current != null && current.isNotEmpty) {
      _strokes.add(MarkupStroke(color: _color, points: List.of(current)));
    }
    _current = null;
    _cropCorner = null;
    _panLast = null;
    setState(() {});
  }

  Future<void> _done() async {
    if (_busy || _header == null) return;
    _end();
    setState(() => _busy = true);
    try {
      final edited = await compute(
        processImageEdit,
        ImageEditSpec(
          bytes: widget.source.bytes,
          name: widget.source.name,
          rotation: _rotation,
          crop: _crop,
          strokes: List.of(_strokes),
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, edited);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t edit this image.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: 'Cancel image edit',
          onPressed: _busy ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Edit image'),
        actions: [
          TextButton(
            onPressed: _busy || _header == null ? null : _done,
            child: Text(
              _busy ? 'Saving…' : 'Done',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _header == null
                  ? const Center(
                      child: Text(
                        'This image format can’t be edited.',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final scale = math.min(
                          constraints.maxWidth / _aspect,
                          constraints.maxHeight,
                        );
                        final width = _aspect * scale;
                        final size = Size(width, scale);
                        return Center(
                          child: SizedBox(
                            key: const ValueKey('image-editor-canvas'),
                            width: width,
                            height: scale,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (details) =>
                                  _start(details.localPosition, size),
                              onPanUpdate: (details) =>
                                  _update(details.localPosition, size),
                              onPanEnd: (_) => _end(),
                              onPanCancel: _end,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  RotatedBox(
                                    quarterTurns: _rotation,
                                    child: Image.memory(
                                      widget.source.bytes,
                                      fit: BoxFit.fill,
                                    ),
                                  ),
                                  CustomPaint(
                                    painter: _EditorPainter(
                                      crop: _crop,
                                      strokes: _strokes,
                                      current: _current,
                                      currentColor: _color,
                                      cropping: _mode == _EditorMode.crop,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_mode == _EditorMode.markup)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final color in _colors)
                      IconButton(
                        tooltip:
                            'Markup colour ${color.toARGB32().toRadixString(16)}',
                        onPressed: () =>
                            setState(() => _color = color.toARGB32()),
                        icon: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _color == color.toARGB32()
                                  ? Colors.white
                                  : Colors.white54,
                              width: _color == color.toARGB32() ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Crop image',
                    onPressed: () => setState(() => _mode = _EditorMode.crop),
                    icon: Icon(
                      Icons.crop,
                      color: _mode == _EditorMode.crop
                          ? Colors.orange
                          : Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Draw on image',
                    onPressed: () => setState(() => _mode = _EditorMode.markup),
                    icon: Icon(
                      Icons.draw_outlined,
                      color: _mode == _EditorMode.markup
                          ? Colors.orange
                          : Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Rotate image',
                    onPressed: _rotate,
                    icon: const Icon(
                      Icons.rotate_90_degrees_cw,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Undo markup',
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() => _strokes.removeLast()),
                    icon: const Icon(Icons.undo, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Reset crop',
                    onPressed: () =>
                        setState(() => _crop = const Rect.fromLTWH(0, 0, 1, 1)),
                    icon: const Icon(Icons.crop_free, color: Colors.white),
                  ),
                ],
              ),
            ),
            Text(
              _mode == _EditorMode.crop
                  ? 'Drag the crop corners or move the selection'
                  : 'Draw inside the selected crop',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

Offset _normal(Offset local, Size size) => Offset(
  (local.dx / size.width).clamp(0.0, 1.0),
  (local.dy / size.height).clamp(0.0, 1.0),
);

Rect _pixels(Rect rect, Size size) => Rect.fromLTRB(
  rect.left * size.width,
  rect.top * size.height,
  rect.right * size.width,
  rect.bottom * size.height,
);

List<Offset> _handles(Rect rect) => [
  rect.topLeft,
  rect.topRight,
  rect.bottomLeft,
  rect.bottomRight,
];

class _EditorPainter extends CustomPainter {
  const _EditorPainter({
    required this.crop,
    required this.strokes,
    required this.current,
    required this.currentColor,
    required this.cropping,
  });
  final Rect crop;
  final List<MarkupStroke> strokes;
  final List<Offset>? current;
  final int currentColor;
  final bool cropping;

  @override
  void paint(Canvas canvas, Size size) {
    final pixels = _pixels(crop, size);
    canvas.save();
    canvas.clipRect(pixels);
    for (final stroke in strokes) {
      _stroke(canvas, size, stroke.color, stroke.points);
    }
    if (current case final points?) {
      _stroke(canvas, size, currentColor, points);
    }
    canvas.restore();
    final overlay = Paint()..color = Colors.black.withValues(alpha: 0.62);
    if (cropping) {
      canvas.saveLayer(Offset.zero & size, Paint());
      canvas.drawRect(Offset.zero & size, overlay);
      canvas.drawRect(pixels, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }
    canvas.drawRect(
      pixels,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    if (cropping) {
      final handlePaint = Paint()..color = Colors.white;
      for (final point in _handles(pixels)) {
        canvas.drawCircle(point, 8, handlePaint);
      }
    }
  }

  void _stroke(Canvas canvas, Size size, int color, List<Offset> points) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = Color(color)
      ..strokeWidth = math.max(1, 0.006 * math.max(size.width, size.height))
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (points.length == 1) {
      canvas.drawCircle(
        Offset(points.first.dx * size.width, points.first.dy * size.height),
        paint.strokeWidth / 2,
        Paint()..color = Color(color),
      );
      return;
    }
    final path = Path()
      ..moveTo(points.first.dx * size.width, points.first.dy * size.height);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx * size.width, point.dy * size.height);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_EditorPainter oldDelegate) => true;
}
