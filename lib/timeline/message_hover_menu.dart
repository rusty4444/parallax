import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../hooks/hook_types.dart';

/// Height of the floating bar: 28px buttons + 4px padding + 1px border,
/// top and bottom.
const _barHeight = 38.0;

/// Gap between the bar's bottom edge and the message's top edge.
const _barGap = 6.0;

/// Grace period for moving the pointer from the message onto the bar.
const _hideGrace = Duration(milliseconds: 200);

/// Desktop-only quick-action bar that floats over a message while the pointer
/// rests on it (Discord's hover menu): react, reply, thread, edit, pin, more.
///
/// The bar lives in the route's [Overlay], anchored to the message's top-right
/// corner with a [CompositedTransformFollower], so it never shifts the timeline
/// layout, follows the message while scrolling, and stays tappable even though
/// it paints outside the message's own bounds. Actions are resolved lazily on
/// hover, so idle timeline builds pay nothing.
///
/// Touch platforms keep the long-press action sheet; right-click still opens
/// the full sheet on desktop (the bar's "more" button does the same).
class MessageHoverMenu extends StatefulWidget {
  const MessageHoverMenu({
    super.key,
    required this.actionsBuilder,
    required this.palette,
    required this.child,
  });

  /// Resolved when the pointer enters the message, not on every build.
  final List<MessageActionItem> Function() actionsBuilder;
  final AppPalette palette;
  final Widget child;

  /// Hover is a mouse affordance: desktop platforms only.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  State<MessageHoverMenu> createState() => _MessageHoverMenuState();
}

class _MessageHoverMenuState extends State<MessageHoverMenu> {
  final _link = LayerLink();
  final _targetKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _hideTimer;
  ScrollPosition? _scrollPosition;
  List<MessageActionItem> _actions = const [];
  bool _overMessage = false;
  bool _overBar = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A sheet, dialog or pushed route covering this one hides the bar.
    final route = ModalRoute.of(context);
    if (_entry != null && route != null && !route.isCurrent) _hideNow();
  }

  @override
  void didUpdateWidget(MessageHoverMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_entry != null && oldWidget.actionsBuilder != widget.actionsBuilder) {
      _refreshActions();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _removeEntry();
    super.dispose();
  }

  void _onMessageEnter(PointerEnterEvent _) {
    _overMessage = true;
    _show();
  }

  void _onMessageExit(PointerExitEvent _) {
    _overMessage = false;
    _scheduleHide();
  }

  void _onBarEnter(PointerEnterEvent _) {
    _overBar = true;
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _onBarExit(PointerExitEvent _) {
    _overBar = false;
    _scheduleHide();
  }

  void _show() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!mounted || !MessageHoverMenu.supported) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    if (!_refreshActions()) return;
    if (_entry == null) {
      final overlay = Overlay.maybeOf(context);
      if (overlay == null) return;
      _entry = OverlayEntry(builder: _buildBar);
      overlay.insert(_entry!);
      _attachScroll();
    } else {
      _entry!.markNeedsBuild();
    }
  }

  /// Resolves the current actions; hides the bar when there are none left.
  bool _refreshActions() {
    final actions = widget.actionsBuilder();
    if (actions.isEmpty) {
      _hideNow();
      return false;
    }
    _actions = actions;
    return true;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideGrace, () {
      _hideTimer = null;
      if (!_overMessage && !_overBar) _hideNow();
    });
  }

  void _hideNow() {
    _hideTimer?.cancel();
    _hideTimer = null;
    _overMessage = false;
    _overBar = false;
    _removeEntry();
  }

  void _removeEntry() {
    _detachScroll();
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }

  void _attachScroll() {
    final position = Scrollable.maybeOf(context)?.position;
    if (position == _scrollPosition) return;
    _detachScroll();
    _scrollPosition = position;
    position?.addListener(_checkVisible);
  }

  void _detachScroll() {
    _scrollPosition?.removeListener(_checkVisible);
    _scrollPosition = null;
  }

  /// Keeps the bar inside the timeline viewport: it hides when the message
  /// scrolls far enough that the bar would paint over the header or composer.
  void _checkVisible() {
    if (_entry == null || !mounted) return;
    final target = _targetKey.currentContext?.findRenderObject();
    if (target is! RenderBox || !target.attached) {
      _hideNow();
      return;
    }
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (viewport is RenderBox && viewport.attached) {
      final top = target.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top < _barHeight + _barGap ||
          top + target.size.height > viewport.size.height) {
        _hideNow();
        return;
      }
    }
    _entry!.markNeedsBuild();
  }

  Future<void> _select(MessageActionItem item) async {
    _hideNow();
    if (!mounted) return;
    try {
      await item.onSelected(context);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Couldn’t ${item.label.toLowerCase()}.')),
      );
    }
  }

  Widget _buildBar(BuildContext context) => Stack(
    // The overlay hands entries tight constraints; a loose Stack lets the
    // follower size itself to the bar instead of filling the whole screen.
    // The follower's own hit test ignores its layout bounds and applies the
    // leader transform, so the bar stays tappable wherever it paints.
    clipBehavior: Clip.none,
    children: [
      CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(0, -_barGap),
        child: MouseRegion(
          onEnter: _onBarEnter,
          onExit: _onBarExit,
          child: _HoverBar(
            actions: _actions,
            palette: widget.palette,
            onSelected: _select,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!MessageHoverMenu.supported) return widget.child;
    return MouseRegion(
      onEnter: _onMessageEnter,
      onExit: _onMessageExit,
      child: CompositedTransformTarget(
        link: _link,
        child: KeyedSubtree(key: _targetKey, child: widget.child),
      ),
    );
  }
}

/// The floating rounded bar: one icon button per quick action.
class _HoverBar extends StatelessWidget {
  const _HoverBar({
    required this.actions,
    required this.palette,
    required this.onSelected,
  });

  final List<MessageActionItem> actions;
  final AppPalette palette;
  final ValueChanged<MessageActionItem> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('message-hover-bar'),
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: Color.alphaBlend(
        palette.foreground.withValues(alpha: 0.05),
        palette.raised,
      ),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: palette.stroke),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in actions)
          _HoverButton(
            key: ValueKey('hover-action-${action.id}'),
            action: action,
            palette: palette,
            onSelected: onSelected,
          ),
      ],
    ),
  );
}

/// One icon button: muted until hovered, then brightens with a soft highlight.
class _HoverButton extends StatefulWidget {
  const _HoverButton({
    super.key,
    required this.action,
    required this.palette,
    required this.onSelected,
  });

  final MessageActionItem action;
  final AppPalette palette;
  final ValueChanged<MessageActionItem> onSelected;

  @override
  State<_HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<_HoverButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final palette = widget.palette;
    final color = action.destructive
        ? Colors.redAccent
        : _hovered
        ? palette.foreground
        : palette.secondary;
    return Tooltip(
      message: action.label,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelected(action),
          child: Container(
            width: 30,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered
                  ? palette.foreground.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(action.icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
