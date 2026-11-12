import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays [child] out normally but draws it [overlap] pixels higher, over
/// whatever sits above it, and takes that much less height. Reactions use it
/// to sit on the bottom edge of their message bubble, as in Messenger. The
/// raised part stays tappable.
class OverlapUp extends SingleChildRenderObjectWidget {
  const OverlapUp({super.key, required this.overlap, super.child});

  final double overlap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderOverlapUp(overlap);

  @override
  void updateRenderObject(BuildContext context, RenderOverlapUp renderObject) {
    renderObject.overlap = overlap;
  }
}

class RenderOverlapUp extends RenderShiftedBox {
  RenderOverlapUp(this._overlap) : super(null);

  double _overlap;
  double get overlap => _overlap;
  set overlap(double value) {
    if (value == _overlap) return;
    _overlap = value;
    markNeedsLayout();
  }

  double _raise(double childHeight) => math.min(_overlap, childHeight);

  @override
  double computeMinIntrinsicHeight(double width) {
    final h = child?.getMinIntrinsicHeight(width) ?? 0;
    return h - _raise(h);
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final h = child?.getMaxIntrinsicHeight(width) ?? 0;
    return h - _raise(h);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final size = child.getDryLayout(constraints.loosen());
    return constraints.constrain(
      Size(size.width, size.height - _raise(size.height)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    final raise = _raise(child.size.height);
    (child.parentData! as BoxParentData).offset = Offset(0, -raise);
    size = constraints.constrain(
      Size(child.size.width, child.size.height - raise),
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    final raise = _raise(child.size.height);
    final bounds = Rect.fromLTWH(0, -raise, size.width, size.height + raise);
    if (!bounds.contains(position)) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
