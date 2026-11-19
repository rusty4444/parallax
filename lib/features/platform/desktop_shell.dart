// Windows desktop shell for the frameless window: the gradient backdrop,
// the content, the title-bar drag strip and the caption buttons. Extracted
// from main.dart so the drag behaviour is widget-testable.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_theme.dart';
import 'desktop_title_bar.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.palette, required this.child});

  final AppPalette palette;
  final Widget child;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final GlobalKey _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return GlowBackdrop(
      palette: p,
      child: Stack(
        children: [
          Positioned.fill(
            child: KeyedSubtree(key: _contentKey, child: widget.child),
          ),
          // Drag strip ABOVE the content: the inbox brand sits flush at the
          // top-left, and dragging the header's empty space moves the
          // window. A strip behind the content never receives events — the
          // screens' Scaffold Material is opaque to hit testing and stops
          // the Stack's top-down hit test.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: kDesktopTitleBarHeight,
            child: _DragStrip(contentKey: _contentKey),
          ),
          Positioned(
            top: 0,
            right: 0,
            // The caption buttons live outside the Navigator, so their
            // tooltips need their own Overlay.
            child: SizedBox(
              width: 3 * kDesktopCaptionButtonWidth,
              height: kDesktopTitleBarHeight,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(builder: (_) => DesktopTitleBar(palette: p)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Moves the window when the user drags empty title-bar space, and
/// maximizes/restores on double-click.
///
/// Translucent hit testing lets taps pass through to the header buttons
/// underneath. Drag and double-click are detected from raw pointer events
/// instead of gesture recognizers: a pan recognizer wins the arena sweep on
/// a plain click (starting a drag on mouse-up), and a double-tap recognizer
/// holds the arena after the first tap and swallows single taps on the
/// buttons below. Raw events leave the arena to the content's own gestures.
class _DragStrip extends StatefulWidget {
  const _DragStrip({required this.contentKey});

  /// Marks the app content's root so the interactive-below check can stop
  /// there: route/navigator infrastructure above the content also registers
  /// pointer listeners, which must not count as interactive content.
  final GlobalKey contentKey;

  @override
  State<_DragStrip> createState() => _DragStripState();
}

class _DragStripState extends State<_DragStrip> {
  final GlobalKey _stripKey = GlobalKey();
  PointerDownEvent? _firstDown;
  bool _minTimeElapsed = false;
  Timer? _minTimer;
  Timer? _maxTimer;
  int? _dragPointer;
  Offset? _dragStart;
  bool _dragStarted = false;

  @override
  void dispose() {
    _resetDoubleTap();
    super.dispose();
  }

  void _resetDoubleTap() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
    _minTimer = null;
    _maxTimer = null;
    _firstDown = null;
    _minTimeElapsed = false;
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // Window ops are best effort; the strip keeps working.
    }
  }

  /// Whether the hit path below the strip contains a pointer listener
  /// inside the app content (a header button, the pane divider, tappable
  /// text). Gestures there belong to that widget, so they must not drag or
  /// double-click the window. The scan stops at the content root: the
  /// route's own barrier listeners sit above it and are always present,
  /// even over empty header space.
  bool _interactiveBelow(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      position,
      View.of(context).viewId,
    );
    final strip = _stripKey.currentContext?.findRenderObject();
    final contentRoot = widget.contentKey.currentContext?.findRenderObject();
    var belowStrip = false;
    for (final entry in result.path) {
      final target = entry.target;
      if (belowStrip && target is RenderPointerListener) return true;
      if (target == contentRoot) return false;
      if (target == strip) belowStrip = true;
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton || _interactiveBelow(event.position)) {
      _resetDoubleTap();
      _dragPointer = null;
      return;
    }
    final first = _firstDown;
    if (first != null &&
        _minTimeElapsed &&
        (event.position - first.position).distance <= kDoubleTapSlop) {
      _resetDoubleTap();
      unawaited(_toggleMaximize());
      return;
    }
    // A fresh first tap: arm the min/max double-click window. Zone timers
    // (not event.timeStamp) so the interval is measurable in widget tests.
    _resetDoubleTap();
    _firstDown = event;
    _minTimer = Timer(kDoubleTapMinTime, () => _minTimeElapsed = true);
    _maxTimer = Timer(kDoubleTapTimeout, _resetDoubleTap);
    _dragPointer = event.pointer;
    _dragStart = event.position;
    _dragStarted = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragPointer != event.pointer || _dragStarted || _dragStart == null) {
      return;
    }
    final slop = event.kind == PointerDeviceKind.mouse
        ? kPrecisePointerPanSlop
        : kPanSlop;
    if ((event.position - _dragStart!).distance >= slop) {
      _dragStarted = true;
      // Past the slop this is a drag, not a tap; stop the double-click wait.
      _resetDoubleTap();
      unawaited(windowManager.startDragging().catchError((Object _) {}));
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_dragPointer == event.pointer) _dragPointer = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_dragPointer == event.pointer) _dragPointer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: _stripKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: const SizedBox.expand(),
    );
  }
}
