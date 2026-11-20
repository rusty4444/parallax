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

/// The copy of the message being replied to, kept lifted over the timeline
/// while the reply is written ([MessageReplyLift]).
const messageReplyLiftKey = ValueKey('message-reply-lift');

/// The dim over the timeline while a reply's message stays lifted.
const messageReplyLiftDimKey = ValueKey('message-reply-lift-dim');

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
  /// What shows the lifted copy while the message itself is hidden: the
  /// action sheet's [MessageLiftRoute], or a [MessageReplyLift] while the
  /// message is being replied to.
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

/// Runs [reply], a completed swipe-to-reply, after capturing the message
/// inside [swipeContext] (the swipe's own context, above the message's
/// [MessageLiftTarget]). A [MessageReplyLift] around the timeline picks the
/// capture up when the reply starts, so the message springs back from the
/// swipe straight into its lifted, popped-out place.
void liftForReply(BuildContext swipeContext, VoidCallback reply) {
  final target = _findTarget(swipeContext);
  final capture = target == null
      ? null
      : _LiftCapture.from(target, swipeContext);
  if (capture != null) {
    _ReplyHandoff.offer(_ReplyHandoff(capture, fromSwipe: true));
  }
  reply();
}

_MessageLiftTargetState? _findTarget(BuildContext context) {
  _MessageLiftTargetState? found;
  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement &&
        element.state is _MessageLiftTargetState) {
      found = element.state as _MessageLiftTargetState;
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildElements(visit);
  return found;
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
///
/// When [keepLiftedWhen] accepts the sheet's result (its Reply action), the
/// message does not settle back: a [MessageReplyLift] around the timeline
/// takes the lifted copy over and keeps it popped out while the reply is
/// written.
Future<T?> showMessageActionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  bool Function(T? result)? keepLiftedWhen,
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
  final sheet = _LiftSheetRoute<T>(
    onPopped: (result) {
      if (keepLiftedWhen?.call(result) ?? false) lift?._handOff();
    },
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

  /// Where the message is now in [box]'s coordinates, or null once it has
  /// left the screen (its message scrolled away or was rebuilt).
  Rect? homeIn(RenderBox box) {
    if (!boundary.attached ||
        !box.attached ||
        !boundary.hasSize ||
        boundary.size != size) {
      return null;
    }
    try {
      return MatrixUtils.transformRect(
        boundary.getTransformTo(box),
        Offset.zero & size,
      );
    } catch (_) {
      return null;
    }
  }

  /// A [MessageReplyLift] took the copy over: it now owns the image.
  bool adopted = false;

  void _discard() {
    if (_released || adopted) return;
    _released = true;
    image.dispose();
  }

  /// Releases the image after an adopter is done with it.
  void _release() {
    if (_released) return;
    _released = true;
    image.dispose();
  }
}

/// A lifted message offered to the timeline's [MessageReplyLift] when a
/// reply starts: from a completed swipe, or from the action sheet's Reply.
class _ReplyHandoff {
  _ReplyHandoff(
    this.capture, {
    this.fromSwipe = false,
    this.offset = Offset.zero,
    this.scale = 1,
    this.route,
  });

  /// The handoff waiting for the reply to start.
  static _ReplyHandoff? _pending;

  final _LiftCapture capture;
  final bool fromSwipe;

  /// Where the sheet's copy was drawn relative to the message (it moves up
  /// to clear the sheet) and how large, so the takeover is seamless.
  final Offset offset;
  final double scale;

  /// The sheet's lift handing over, if any.
  final MessageLiftRoute? route;

  static void offer(_ReplyHandoff handoff) {
    _pending?._drop();
    _pending = handoff;
    // The reply rebuilds the timeline in the next frame, where its
    // MessageReplyLift claims this. Unclaimed (no lift around the timeline,
    // or no reply started), it is dropped after that frame.
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (identical(_pending, handoff)) {
          _pending = null;
          handoff._drop();
        }
      })
      ..scheduleFrame();
  }

  static _ReplyHandoff? claim() {
    final handoff = _pending;
    _pending = null;
    return handoff;
  }

  void _drop() {
    final route = this.route;
    if (route != null) {
      // The sheet's lift settles the message back as usual.
      route._handedOff = false;
    } else {
      capture._discard();
    }
  }
}

/// The action sheet's route, reporting its result the moment it is popped
/// (before the lift below it hears about the pop).
class _LiftSheetRoute<T> extends ModalBottomSheetRoute<T> {
  _LiftSheetRoute({
    required this.onPopped,
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.showDragHandle,
  });

  final ValueChanged<T?> onPopped;

  @override
  bool didPop(T? result) {
    onPopped(result);
    return super.didPop(result);
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

  /// The sheet's Reply handed the copy to the timeline's MessageReplyLift.
  bool _handedOff = false;

  /// What the copy looked like in the last frame, for a seamless handoff.
  double _lastShift = 0;
  double _lastScale = 1;

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

  /// Offers the copy, as drawn now, to the timeline's MessageReplyLift.
  void _handOff() {
    if (_disposed || _handedOff || _capture._released) return;
    _handedOff = true;
    _ReplyHandoff.offer(
      _ReplyHandoff(
        _capture,
        offset: Offset(0, _lastShift),
        scale: _lastScale,
        route: this,
      ),
    );
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
        route
          .._lastShift = shift
          .._lastScale = scale;
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
              // Once the timeline's reply lift has the copy, only the dim
              // fades out here.
              if (!capture.adopted)
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

/// Keeps the message being replied to popped out over the timeline while
/// the reply is written.
///
/// Wrap the timeline (not the composer) in it and pass the ID of the message
/// being replied to. When a reply starts from a swipe ([liftForReply]) or
/// from the action sheet's Reply ([showMessageActionSheet] with
/// `keepLiftedWhen`), this takes the lifted copy over: the timeline dims and
/// the message stays raised with its shadow, following it as the keyboard
/// opens or the timeline scrolls. The composer stays usable, and so does the
/// timeline underneath (the dim ignores touches). It settles back when
/// [replyingTo] changes (sent, cancelled, an edit started) or when the
/// message leaves the screen.
class MessageReplyLift extends StatefulWidget {
  const MessageReplyLift({
    super.key,
    required this.replyingTo,
    required this.child,
  });

  /// The message being replied to, or null.
  final String? replyingTo;
  final Widget child;

  @override
  State<MessageReplyLift> createState() => _MessageReplyLiftState();
}

class _MessageReplyLiftState extends State<MessageReplyLift>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  _ReplyLift? _lift;

  /// Lifts landing after their reply ended (one at most in practice).
  final _leaving = <_ReplyLift>[];
  late final Ticker _follow;

  /// Frames in a row the message stayed put; following pauses after a few
  /// so a long reply doesn't keep the screen redrawing.
  int _stillFrames = 0;
  static const _pauseAfterStillFrames = 12;

  @override
  void initState() {
    super.initState();
    // Created up front: a ticker can't be created once the element is
    // deactivated (dispose).
    _follow = createTicker(_tick);
    WidgetsBinding.instance.addObserver(this);
  }

  /// Something may have moved the message: follow it again for a while.
  void _wake() {
    _stillFrames = 0;
    if ((_lift != null || _leaving.isNotEmpty) && !_follow.isActive) {
      _follow.start();
    }
  }

  @override
  void didChangeMetrics() => _wake(); // keyboard, rotation, window size

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wake();
  }

  @override
  void didUpdateWidget(MessageReplyLift oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The room rebuilt (a new message, a reaction …): follow again.
    _wake();
    final current = _lift;
    if (current != null && widget.replyingTo != current.eventId) {
      _settle(current);
    }
    final replyingTo = widget.replyingTo;
    if (replyingTo != null && _lift == null) {
      final handoff = _ReplyHandoff.claim();
      if (handoff != null) _adopt(handoff, replyingTo);
    }
  }

  void _adopt(_ReplyHandoff handoff, String eventId) {
    final capture = handoff.capture;
    if (!capture.target.mounted || capture._released) {
      handoff._drop();
      return;
    }
    final reduceMotion = capture.reduceMotion;
    final lift = _ReplyLift(
      eventId: eventId,
      capture: capture,
      fromSwipe: handoff.fromSwipe,
      fromOffset: handoff.offset,
      fromScale: handoff.scale,
      controller: AnimationController(
        vsync: this,
        duration: reduceMotion
            ? Duration.zero
            : Duration(milliseconds: handoff.fromSwipe ? 320 : 240),
        reverseDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 200),
      ),
    );
    capture.adopted = true;
    capture.target._lifted(lift);
    final box = context.findRenderObject();
    // Measured now (last frame's layout), so the copy is drawn in the same
    // frame that hides the message.
    lift.home = box is RenderBox ? capture.homeIn(box) : null;
    _lift = lift;
    lift.controller
      ..addListener(_changed)
      ..forward();
    _wake();
  }

  /// Settles [lift] back into the timeline, then shows the message again.
  void _settle(_ReplyLift lift) {
    if (identical(_lift, lift)) _lift = null;
    if (lift.leaving) return;
    lift.leaving = true;
    _leaving.add(lift);
    lift.controller.reverse().whenCompleteOrCancel(() => _finish(lift));
  }

  void _finish(_ReplyLift lift) {
    if (lift.finished) return;
    lift.finished = true;
    _leaving.remove(lift);
    lift.capture.target._landed(lift);
    lift.controller.dispose();
    lift.capture._release();
    if (mounted) setState(() {});
    if (_lift == null && _leaving.isEmpty && _follow.isActive) _follow.stop();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Follows the message every frame (keyboard, scrolling, new messages);
  /// rebuilds only when it moved, and lets go once it has left the screen.
  void _tick(Duration _) {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    if (_lift == null && _leaving.isEmpty) {
      _follow.stop();
      return;
    }
    var moved = false;
    for (final lift in [?_lift, ..._leaving]) {
      final home = lift.capture.homeIn(box);
      if (home == null) {
        if (identical(lift, _lift)) _settle(lift);
        continue;
      }
      if (home != lift.home) {
        lift.home = home;
        moved = true;
      }
    }
    if (moved && mounted) setState(() {});
    final animating = [
      ?_lift,
      ..._leaving,
    ].any((lift) => lift.controller.isAnimating);
    _stillFrames = moved || animating ? 0 : _stillFrames + 1;
    if (_stillFrames >= _pauseAfterStillFrames) _follow.stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _follow.dispose();
    final lifts = [?_lift, ..._leaving];
    _lift = null;
    _leaving.clear();
    for (final lift in lifts) {
      if (lift.finished) continue;
      lift.finished = true;
      lift.controller.dispose();
      lift.capture.target._landed(lift);
      lift.capture._release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lifts = [..._leaving, ?_lift];
    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrolling or resizing underneath moves the message: follow it.
        NotificationListener<Notification>(
          onNotification: (notification) {
            if (notification is ScrollNotification ||
                notification is ScrollMetricsNotification ||
                notification is SizeChangedLayoutNotification) {
              _wake();
            }
            return false;
          },
          child: widget.child,
        ),
        for (final lift in lifts)
          if (lift.home != null)
            Positioned.fill(
              child: IgnorePointer(child: _ReplyLiftView(lift: lift)),
            ),
      ],
    );
  }
}

/// One message kept lifted for a reply.
class _ReplyLift {
  _ReplyLift({
    required this.eventId,
    required this.capture,
    required this.fromSwipe,
    required this.fromOffset,
    required this.fromScale,
    required this.controller,
  }) : home = null;

  final String eventId;
  final _LiftCapture capture;
  final bool fromSwipe;
  final Offset fromOffset;
  final double fromScale;
  final AnimationController controller;
  bool leaving = false;
  bool finished = false;

  /// The message's current place in the lift's box (null until measured).
  Rect? home;
}

class _ReplyLiftView extends StatelessWidget {
  const _ReplyLiftView({required this.lift});

  final _ReplyLift lift;

  @override
  Widget build(BuildContext context) {
    final home = lift.home!;
    final capture = lift.capture;
    final reduceMotion = capture.reduceMotion;
    final t = lift.controller.value;
    final double scale;
    final double shadow;
    final Offset offset;
    if (lift.leaving) {
      // Settling back: shrink, lose the shadow and the dim together.
      final out = Curves.easeInCubic.transform(t);
      scale = reduceMotion ? 1 : 1 + (_liftScale - 1) * out;
      shadow = out;
      offset = Offset.zero;
    } else if (lift.fromSwipe) {
      // The swipe springs back (the live home follows it) while the message
      // pops up.
      scale = reduceMotion
          ? 1
          : 1 + (_liftScale - 1) * Curves.easeOutBack.transform(t);
      shadow = Curves.easeOut.transform(t);
      offset = Offset.zero;
    } else {
      // From the sheet: already lifted; drop back down beside its place as
      // the sheet slides away.
      final ease = Curves.easeOutCubic.transform(t);
      scale = reduceMotion
          ? 1
          : lift.fromScale + (_liftScale - lift.fromScale) * ease;
      shadow = 1;
      offset = Offset.lerp(lift.fromOffset, Offset.zero, ease)!;
    }
    final dim = lift.leaving ? t : Curves.easeOut.transform(t);
    return Stack(
      key: messageReplyLiftKey,
      children: [
        Positioned.fill(
          child: ColoredBox(
            key: messageReplyLiftDimKey,
            color: Colors.black.withValues(alpha: _dimAlpha * dim),
          ),
        ),
        Positioned.fromRect(
          rect: home.shift(offset),
          child: Transform.scale(
            scale: scale,
            child: _LiftedCopy(capture: capture, shadow: shadow),
          ),
        ),
      ],
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
