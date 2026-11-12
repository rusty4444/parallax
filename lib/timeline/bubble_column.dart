import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A column as wide as its widest child, so a message bubble hugs its
/// content: short messages get short bubbles. Children keep their natural
/// width (up to the incoming maximum) and start at the leading edge, except
/// those wrapped in [BubbleEnd], which sit at the trailing edge (the
/// timestamp).
///
/// A plain [Column] can't do this: right-aligning one child needs an
/// [Align], which expands to the full available width and so stretches
/// every bubble to its maximum. [IntrinsicWidth] could, but bubble bodies
/// built with [LayoutBuilder] (images, video, voice) can't report intrinsic
/// sizes. This lays out in one pass with no intrinsic queries.
class BubbleColumn extends MultiChildRenderObjectWidget {
  const BubbleColumn({super.key, required super.children});

  @override
  RenderBubbleColumn createRenderObject(BuildContext context) =>
      RenderBubbleColumn(Directionality.maybeOf(context));

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBubbleColumn renderObject,
  ) => renderObject.textDirection = Directionality.maybeOf(context);
}

/// Places [child] at the trailing edge of its [BubbleColumn].
class BubbleEnd extends ParentDataWidget<BubbleColumnParentData> {
  const BubbleEnd({super.key, required super.child});

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as BubbleColumnParentData;
    if (!data.alignEnd) {
      data.alignEnd = true;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => BubbleColumn;
}

class BubbleColumnParentData extends ContainerBoxParentData<RenderBox> {
  /// Laid out against the trailing edge.
  bool alignEnd = false;
}

class RenderBubbleColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, BubbleColumnParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, BubbleColumnParentData> {
  RenderBubbleColumn([this._textDirection]);

  TextDirection? _textDirection;
  set textDirection(TextDirection? value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BubbleColumnParentData) {
      child.parentData = BubbleColumnParentData();
    }
  }

  /// Children may be as wide as the column may be, and as tall as they like.
  static BoxConstraints _childConstraints(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  Size _size(BoxConstraints constraints, Size Function(RenderBox) sizeOf) {
    var width = 0.0;
    var height = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final size = sizeOf(child);
      width = math.max(width, size.width);
      height += size.height;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final childConstraints = _childConstraints(constraints);
    return _size(constraints, (child) => child.getDryLayout(childConstraints));
  }

  @override
  void performLayout() {
    final childConstraints = _childConstraints(constraints);
    size = _size(constraints, (child) {
      child.layout(childConstraints, parentUsesSize: true);
      return child.size;
    });
    final rtl = _textDirection == TextDirection.rtl;
    var y = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as BubbleColumnParentData;
      final spare = size.width - child.size.width;
      data.offset = Offset(data.alignEnd != rtl ? spare : 0, y);
      y += child.size.height;
    }
  }

  double _maxOf(double Function(RenderBox) measure) {
    var result = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      result = math.max(result, measure(child));
    }
    return result;
  }

  double _sumOf(double Function(RenderBox) measure) {
    var result = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      result += measure(child);
    }
    return result;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _maxOf((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _maxOf((child) => child.getMaxIntrinsicWidth(double.infinity));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _sumOf((child) => child.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _sumOf((child) => child.getMaxIntrinsicHeight(width));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
