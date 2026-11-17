// Pinch-zoom for one picture in the media viewer.
//
// InteractiveViewer limits panning to its child's box and clips to its own.
// With the picture alone as its child, the viewer was only as big as the
// letterboxed picture, so a zoomed picture stayed inside that frame. Here the
// viewer fills the space it is given and the picture sits centred in it. The
// controller then corrects every pan and zoom so that the picture's own edges
// are the limit: it grows from the centre until it fills an axis, and can then
// be dragged along that axis only as far as its edge. The empty bars around
// it can never be dragged into view.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// [natural] shrunk to fit [viewport] at its own aspect ratio. A picture
/// smaller than the viewport keeps its size.
Size fittedPictureSize(Size natural, Size viewport) => BoxConstraints.loose(
  viewport,
).constrainSizeAndAttemptToPreserveAspectRatio(natural);

/// The zoom at which a centred [picture] covers all of [viewport].
double pictureCoverScale(Size picture, Size viewport) {
  if (picture.isEmpty || viewport.isEmpty) return 1;
  return math.max(
    1,
    math.max(viewport.width / picture.width, viewport.height / picture.height),
  );
}

/// [value] (a zoom and an offset, as [InteractiveViewer] produces) moved so
/// that a [picture] centred in [viewport] stays centred along an axis it does
/// not fill, and along the other shows no gap between its edge and the
/// viewport's. Returns [value] itself when it is already within bounds.
Matrix4 boundPictureTransform(
  Matrix4 value, {
  required Size viewport,
  required Size picture,
}) {
  if (picture.isEmpty || viewport.isEmpty) return value;
  final scale = value.getMaxScaleOnAxis();
  final offset = value.getTranslation();

  double bound(double current, double view, double extent) {
    if (extent * scale <= view) return view * (1 - scale) / 2;
    // The picture's leading edge at the viewport's, then its trailing edge.
    final max = -scale * (view - extent) / 2;
    final min = view - scale * (view + extent) / 2;
    return current.clamp(min, max);
  }

  final x = bound(offset.x, viewport.width, picture.width);
  final y = bound(offset.y, viewport.height, picture.height);
  if ((x - offset.x).abs() < 1e-9 && (y - offset.y).abs() < 1e-9) return value;
  return value.clone()..setTranslationRaw(x, y, offset.z);
}

/// Keeps a picture within [boundPictureTransform] whatever sets [value]: a
/// pinch, a drag, the fling after either, or code.
class PictureTransformationController extends TransformationController {
  Size _viewport = Size.zero;
  Size _picture = Size.zero;

  /// The space the picture is shown in and its size there at rest. Returns
  /// whether the current [value] is now out of bounds; call [rebound] once the
  /// frame is over (setting [value] notifies listeners, so not during build).
  bool setBounds({required Size viewport, required Size picture}) {
    _viewport = viewport;
    _picture = picture;
    final current = super.value;
    return !identical(
      boundPictureTransform(current, viewport: viewport, picture: picture),
      current,
    );
  }

  /// Brings [value] back within the bounds given to [setBounds].
  void rebound() => value = super.value;

  @override
  set value(Matrix4 newValue) => super.value = boundPictureTransform(
    newValue,
    viewport: _viewport,
    picture: _picture,
  );
}

/// [child] (a picture of [naturalSize]) fitted and centred in the available
/// space, zoomable until it fills that space and beyond.
class ZoomablePicture extends StatefulWidget {
  const ZoomablePicture({
    super.key,
    required this.controller,
    required this.naturalSize,
    required this.child,
  });

  final PictureTransformationController controller;

  /// The picture's size before fitting (its pixel size).
  final Size naturalSize;

  /// The picture. It is laid out at exactly the fitted size.
  final Widget child;

  /// Zoom allowed for any picture; a long, thin one may go further, to twice
  /// the zoom that fills the space, up to [zoomLimit].
  static const usualMaxScale = 8.0;
  static const zoomLimit = 32.0;

  @override
  State<ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<ZoomablePicture> {
  bool _reboundScheduled = false;

  /// The space changed (rotation, split screen) under a zoomed picture.
  void _reboundAfterFrame() {
    if (_reboundScheduled) return;
    _reboundScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reboundScheduled = false;
      if (mounted) widget.controller.rebound();
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      if (!viewport.isFinite || viewport.isEmpty) {
        return Center(child: widget.child);
      }
      final picture = fittedPictureSize(widget.naturalSize, viewport);
      if (widget.controller.setBounds(viewport: viewport, picture: picture)) {
        _reboundAfterFrame();
      }
      return InteractiveViewer(
        transformationController: widget.controller,
        minScale: 1,
        maxScale: (pictureCoverScale(picture, viewport) * 2).clamp(
          ZoomablePicture.usualMaxScale,
          ZoomablePicture.zoomLimit,
        ),
        child: SizedBox.fromSize(
          size: viewport,
          child: Center(
            child: SizedBox.fromSize(size: picture, child: widget.child),
          ),
        ),
      );
    },
  );
}
