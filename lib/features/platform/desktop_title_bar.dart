// Custom title bar that blends with the app (Windows). The native caption
// is hidden via window_manager; this strip draws the brand, drags the window
// with the system move loop, and provides minimize / maximize / close.
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_theme.dart';
import '../../widgets.dart';

class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key, required this.palette});

  final AppPalette palette;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager
        .isMaximized()
        .then((value) {
          if (mounted) setState(() => _maximized = value);
        })
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // Window ops are best effort; the bar keeps working.
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return SizedBox(
      key: const ValueKey('desktop-title-bar'),
      height: 36,
      // Transparent: the shell GlowBackdrop gradient runs continuously
      // behind the bar, so it blends with whatever theme is active.
      child: Row(
        children: [
          // Brand mark + empty space form the drag region.
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: _toggleMaximize,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(
                      painter: const ParallaxMarkPainter(scale: 0.92),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _CaptionButton(
            palette: p,
            tooltip: 'Minimize',
            icon: Icons.remove_rounded,
            onTap: () => windowManager.minimize(),
          ),
          _CaptionButton(
            palette: p,
            tooltip: _maximized ? 'Restore' : 'Maximize',
            icon: _maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            onTap: _toggleMaximize,
          ),
          _CaptionButton(
            palette: p,
            tooltip: 'Close',
            icon: Icons.close_rounded,
            onTap: () => windowManager.close(),
            closeStyle: true,
          ),
        ],
      ),
    );
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.palette,
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.closeStyle = false,
  });

  final AppPalette palette;
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool closeStyle;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: SizedBox(
        width: 46,
        height: 36,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            hoverColor: closeStyle
                ? const Color(0xFFE81123)
                : p.foreground.withValues(alpha: 0.08),
            splashColor: closeStyle
                ? const Color(0xFFC50F1F)
                : p.foreground.withValues(alpha: 0.12),
            highlightColor: Colors.transparent,
            child: Icon(icon, size: 16, color: p.muted),
          ),
        ),
      ),
    );
  }
}
