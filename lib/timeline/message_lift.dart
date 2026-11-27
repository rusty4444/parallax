import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// The lifted copy of a pressed message (tests and visual QA).
const messageLiftSnapshotKey = ValueKey('message-lift-snapshot');

/// The copy's soft shadow.
const messageLiftShadowKey = ValueKey('message-lift-shadow');

/// The dim over the room behind a lifted message.
const messageLiftDimKey = ValueKey('message-lift-dim');

/// How much a lifted message grows.
const _liftScale = 1.05;

/// Room a lifted message keeps above the action sheet.
const _sheetGap = 14.0;

/// Room it keeps below the top safe area when it has to move up.
const _topMargin = 8.0;

/// The room behind a lifted message: black at this opacity, lightly blurred.
const _dimAlpha = 0.45;
const _blurSigma = 3.0;

/// Snapshot budget, so a very long message does not allocate a huge texture.
const _maxSnapshotPixels = 8 * 1024 * 1024;
const _maxSnapshotSide = 8192.0;

/// Wraps a message so a long press or right-click can lift it off the
/// screen (as in Facebook Messenger) while its action sheet is open.
///
/// Gesture handlers below this widget call [liftMessage] with their own
/// context. The message itself is hidden while its lifted copy is on
/// screen, so the copy can move clear of the sheet without leaving a double
/// behind; it reappears the moment the copy has settled back in place.
class MessageLiftTarget extends StatefulWidget {
  const MessageLiftTarget({super.key, required this.child});

  final Widget child;

  @override
  State<MessageLiftTarget> createState() => _MessageLiftTargetState();
}

class _MessageLiftTargetState extends State<MessageLiftTarget> {
  /// The action sheet's [MessageLiftRoute] while the message is hidden.
  Object? _lift;

  void _lifted(Object owner) {
    if (mounted) setState(() => _lift = owner);
  }

  void _landed(Object owner) {
    if (mounted && identical(_lift, owner)) setState(() => _lift = null);
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Opacity(
      opacity: _lift == null ? 1 : 0,
      // The message stays where it is for screen readers.
      alwaysIncludeSemantics: true,
      child: widget.child,
    ),
  );
}

/// Runs [action], a message's long-press or right-click handler, after
/// capturing the message around [context] (inside a [MessageLiftTarget]).
///
/// The capture is offered to the action sheet the handler opens with
/// [showMessageActionSheet], which lifts the message behind the sheet. It
/// must be claimed while the handler runs (or in a microtask it queued); a
/// handler that opens no sheet pushes nothing and the capture is dropped.
void liftMessage(BuildContext context, VoidCallback action) {
  final capture = _LiftCapture.take(context);
  if (capture == null) {
    action();
    return;
  }
  _LiftCapture._pending?._discard();
  _LiftCapture._pending = capture;
  try {
    action();
  } finally {
    scheduleMicrotask(() {
      if (identical(_LiftCapture._pending, capture)) {
        _LiftCapture._pending = null;
        capture._discard();
      }
    });
  }
}

/// Shows a message's action sheet.
///
/// When the long press or right-click that opened it captured the message
/// ([liftMessage]), a [MessageLiftRoute] is pushed just below the sheet: the
/// room dims and blurs, and the message pops out with a shadow, moving up
/// only as far as it needs to stay visible above the sheet. The sheet's own
/// barrier is then transparent (the lift already dims) but still closes the
/// sheet when tapped. However the sheet closes (a choice, the barrier, back,
/// a drag), the message settles back into the timeline with it.
///
/// Without a capture (e.g. the desktop hover bar's "More actions") this is a
/// plain [showModalBottomSheet].
Future<T?> showMessageActionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
}) async {
  final navigator = Navigator.of(context);
  final capture = _LiftCapture._claim(navigator);
  if (capture == null) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      builder: builder,
    );
  }
  final localizations = MaterialLocalizations.of(context);
  final handle = showDragHandle ? kMinInteractiveDimension : 0.0;
  MessageLiftRoute? lift;
  // Mirrors showModalBottomSheet, keeping a handle on the route so the lift
  // can follow the sheet's animation.
  final sheet = ModalBottomSheetRoute<T>(
    builder: (sheetContext) => _SheetMeasure(
      onLaidOut: (box) => lift?._measureSheet(box, handle),
      child: builder(sheetContext),
    ),
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: isScrollControlled,
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(
      localizations.bottomSheetLabel,
    ),
    modalBarrierColor: Colors.transparent,
    showDragHandle: showDragHandle,
  );
  final route = lift = MessageLiftRoute._(capture, sheet);
  unawaited(navigator.push<void>(route));
  capture.target._lifted(route);
  try {
    return await navigator.push<T>(sheet);
  } finally {
    route._close();
  }
}

/// A snapshot of a pressed message and where it sits on screen.
class _LiftCapture {
  _LiftCapture._({
    required this.target,
    required this.navigator,
    required this.boundary,
    required this.overlay,
    required this.size,
    required this.rect,
    required this.image,
    required this.pixelRatio,
    required this.reduceMotion,
  });

  /// The capture offered to the next [showMessageActionSheet].
  static _LiftCapture? _pending;

  final _MessageLiftTargetState target;
  final NavigatorState navigator;
  final RenderRepaintBoundary boundary;

  /// The navigator's overlay: the lift draws in its coordinate space.
  final RenderBox overlay;
  final Size size;
  final Rect rect;
  final ui.Image image;
  final double pixelRatio;
  final bool reduceMotion;
  bool _released = false;

  static _LiftCapture? take(BuildContext context) {
    final target = context.findAncestorStateOfType<_MessageLiftTargetState>();
    if (target == null) return null;
    return from(target, context);
  }

  /// Captures [target]; [context] supplies the pixel ratio and motion
  /// settings.
  static _LiftCapture? from(
    _MessageLiftTargetState target,
    BuildContext context,
  ) {
    if (!target.mounted || target._lift != null) return null;
    final boundary = target.context.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.size.isEmpty) {
      return null;
    }
    final navigator = Navigator.maybeOf(target.context);
    final overlay = navigator?.overlay?.context.findRenderObject();
    if (navigator == null || overlay is! RenderBox || !overlay.attached) {
      return null;
    }
    // A boundary waiting for its next paint cannot be captured (debug only;
    // release builds capture the last frame). Skip the lift rather than show
    // a stale copy.
    var dirty = false;
    assert(() {
      dirty = boundary.debugNeedsPaint;
      return true;
    }());
    if (dirty) return null;
    final size = boundary.size;
    final Rect rect;
    final ui.Image image;
    final pixelRatio = math.max(
      0.1,
      [
        MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0,
        math.sqrt(_maxSnapshotPixels / (size.width * size.height)),
        _maxSnapshotSide / size.longestSide,
      ].reduce(math.min),
    );
    try {
      rect = MatrixUtils.transformRect(
        boundary.getTransformTo(overlay),
        Offset.zero & size,
      );
      image = boundary.toImageSync(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
    return _LiftCapture._(
      target: target,
      navigator: navigator,
      boundary: boundary,
      overlay: overlay,
      size: size,
      rect: rect,
      image: image,
      pixelRatio: pixelRatio,
      reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    );
  }

  /// Takes the pending capture for a sheet about to open on [navigator].
  static _LiftCapture? _claim(NavigatorState navigator) {
    final capture = _pending;
    _pending = null;
    if (capture == null) return null;
    if (!identical(capture.navigator, navigator) ||
        !navigator.mounted ||
        !capture.target.mounted ||
        capture.target._lift != null) {
      capture._discard();
      return null;
    }
    return capture;
  }

  /// Where the message is now: it follows its message if the room moves
  /// underneath (the keyboard closing, a new message arriving).
  Rect get home {
    if (boundary.attached &&
        overlay.attached &&
        boundary.hasSize &&
        boundary.size == size) {
      try {
        return MatrixUtils.transformRect(
          boundary.getTransformTo(overlay),
          Offset.zero & size,
        );
      } catch (_) {
        // Fall back to where it was pressed.
      }
    }
    return rect;
  }

  void _discard() {
    if (_released) return;
    _released = true;
    image.dispose();
  }
}

/// The action sheet's final extent in the overlay.
typedef _SheetBounds = ({double left, double width, double height});

/// A pressed message lifted off a dimmed, lightly blurred room. Pushed just
/// below the message's action sheet by [showMessageActionSheet] and closed
/// with it.
class MessageLiftRoute extends PopupRoute<void> {
  MessageLiftRoute._(this._capture, this._sheet);

  final _LiftCapture _capture;
  final TransitionRoute<dynamic> _sheet;
  final _sheetBounds = ValueNotifier<_SheetBounds?>(null);
  CurvedAnimation? _pop;
  bool _sheetShown = false;
  bool _closing = false;
  bool _landed = false;
  bool _disposed = false;

  bool get _reduceMotion => _capture.reduceMotion;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close message actions';

  @override
  Duration get transitionDuration =>
      _reduceMotion ? Duration.zero : const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration =>
      _reduceMotion ? Duration.zero : const Duration(milliseconds: 200);

  @override
  void install() {
    super.install();
    _pop = CurvedAnimation(
      parent: animation!,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    animation!.addStatusListener(_statusChanged);
  }

  void _statusChanged(AnimationStatus status) {
    if (status.isDismissed) _land();
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (identical(nextRoute, _sheet)) {
      _sheetShown = true;
    } else if (_sheetShown && nextRoute == null) {
      // The sheet went without a pop (removed): go with it.
      scheduleMicrotask(_close);
    }
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    super.didPopNext(nextRoute);
    // The navigator is locked while it reports a pop: close once it is free.
    if (identical(nextRoute, _sheet)) scheduleMicrotask(_close);
  }

  /// Settles the message back (reverse animation) unless already closing.
  void _close() {
    if (_closing || _disposed) return;
    _closing = true;
    final navigator = this.navigator;
    if (navigator == null || !isActive) return;
    if (isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(this);
    }
  }

  /// Shows the message again once its copy is back in place (or gone).
  void _land() {
    if (_landed) return;
    _landed = true;
    final target = _capture.target;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => target._landed(this),
      );
    } else {
      target._landed(this);
    }
  }

  void _measureSheet(RenderBox content, double handle) {
    final overlay = _capture.overlay;
    if (_disposed || !content.attached || !overlay.attached) return;
    final double left;
    try {
      left = content.localToGlobal(Offset.zero, ancestor: overlay).dx;
    } catch (_) {
      return;
    }
    _sheetBounds.value = (
      left: left,
      width: content.size.width,
      height: content.size.height + handle,
    );
  }

  /// How far the copy moves up (negative) so it stays visible above the
  /// sheet once the sheet is fully open. Zero when the sheet does not cover
  /// it (wide windows); never above the top safe area, so a very tall
  /// message can stay partly covered.
  double _shiftFor(Rect home, Size screen, EdgeInsets padding, double scale) {
    final sheet = _sheetBounds.value;
    if (sheet == null) return 0;
    final grownX = home.width * (scale - 1) / 2;
    final grownY = home.height * (scale - 1) / 2;
    if (home.right + grownX <= sheet.left ||
        home.left - grownX >= sheet.left + sheet.width) {
      return 0;
    }
    final sheetTop = screen.height - sheet.height;
    final need = sheetTop - _sheetGap - (home.bottom + grownY);
    if (need >= 0) return 0;
    final headroom = padding.top + _topMargin - (home.top - grownY);
    return math.max(need, math.min(0.0, headroom));
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _MessageLiftView(route: this);

  @override
  void dispose() {
    _disposed = true;
    animation?.removeStatusListener(_statusChanged);
    _pop?.dispose();
    _sheetBounds.dispose();
    _land();
    _capture._discard();
    super.dispose();
  }
}

class _MessageLiftView extends StatelessWidget {
  const _MessageLiftView({required this.route});

  final MessageLiftRoute route;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    // Rebuild while the keyboard closes, so the copy follows its message.
    MediaQuery.viewInsetsOf(context);
    final screenSize = MediaQuery.sizeOf(context);
    final sheet = route._sheet.animation ?? kAlwaysDismissedAnimation;
    return AnimatedBuilder(
      animation: Listenable.merge([route.animation, sheet, route._sheetBounds]),
      builder: (context, _) {
        final capture = route._capture;
        final reduceMotion = capture.reduceMotion;
        final fade = Curves.easeOut.transform(route.animation!.value);
        final scale = reduceMotion
            ? 1.0
            : 1 + (_liftScale - 1) * (route._pop?.value ?? 0);
        final sigma = reduceMotion ? 0.0 : _blurSigma * fade;
        final screen = capture.overlay.attached
            ? capture.overlay.size
            : screenSize;
        final home = capture.home;
        // Same curve as the sheet, so the message rises and falls with it.
        final shift =
            route._shiftFor(
              home,
              screen,
              padding,
              reduceMotion ? 1.0 : _liftScale,
            ) *
            Easing.legacyDecelerate.transform(sheet.value.clamp(0.0, 1.0));
        final dim = ColoredBox(
          key: messageLiftDimKey,
          color: Colors.black.withValues(alpha: _dimAlpha * fade),
        );
        return IgnorePointer(
          child: Stack(
            children: [
              Positioned.fill(
                child: sigma > 0.01
                    ? BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: sigma,
                          sigmaY: sigma,
                        ),
                        child: dim,
                      )
                    : dim,
              ),
              Positioned.fromRect(
                rect: home.translate(0, shift),
                child: Transform.scale(
                  scale: scale,
                  child: _LiftedCopy(capture: capture, shadow: fade),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The snapshot with a shadow cast from its own shape (rounded corners, the
/// bubble's tail, a sticker's outline).
class _LiftedCopy extends StatelessWidget {
  const _LiftedCopy({required this.capture, required this.shadow});

  final _LiftCapture capture;

  /// 0–1: how far the shadow has come in.
  final double shadow;

  RawImage _image({Key? key}) => RawImage(
    key: key,
    image: capture.image,
    scale: capture.pixelRatio,
    width: capture.size.width,
    height: capture.size.height,
    fit: BoxFit.fill,
  );

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    fit: StackFit.expand,
    children: [
      if (shadow > 0)
        Transform.translate(
          offset: Offset(0, 8 * shadow),
          child: ImageFiltered(
            key: messageLiftShadowKey,
            imageFilter: ui.ImageFilter.blur(
              sigmaX: 12,
              sigmaY: 12,
              tileMode: TileMode.decal,
            ),
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: 0.4 * shadow),
                BlendMode.srcIn,
              ),
              child: _image(),
            ),
          ),
        ),
      _image(key: messageLiftSnapshotKey),
    ],
  );
}

/// Reports the sheet content's laid-out box (after the frame) so the lift
/// knows how much of the screen the sheet will cover. The content fills the
/// sheet's width, so its box spans the sheet horizontally.
class _SheetMeasure extends SingleChildRenderObjectWidget {
  const _SheetMeasure({required this.onLaidOut, super.child});

  final ValueChanged<RenderBox> onLaidOut;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSheetMeasure(onLaidOut);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSheetMeasure renderObject,
  ) => renderObject.onLaidOut = onLaidOut;
}

class _RenderSheetMeasure extends RenderProxyBox {
  _RenderSheetMeasure(this.onLaidOut);

  ValueChanged<RenderBox> onLaidOut;
  bool _scheduled = false;

  static BoxConstraints _fullWidth(BoxConstraints constraints) =>
      constraints.hasBoundedWidth
      ? constraints.tighten(width: constraints.maxWidth)
      : constraints;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(_fullWidth(constraints)) ?? Size.zero,
  );

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child.layout(_fullWidth(constraints), parentUsesSize: true);
      size = constraints.constrain(child.size);
    }
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (attached && hasSize) onLaidOut(this);
    });
  }
}
