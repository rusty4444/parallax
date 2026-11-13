import 'package:flutter/material.dart';

import '../app_theme.dart';

/// A right-swipe reply affordance. The message always springs back: swiping
/// never dismisses or deletes it. Long-press actions remain available too.
class SwipeReply extends StatelessWidget {
  const SwipeReply({
    required super.key,
    required this.palette,
    required this.onReply,
    required this.child,
  });

  final AppPalette palette;
  final VoidCallback? onReply;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reply = onReply;
    if (reply == null) return child;
    return Dismissible(
      key: key!,
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {DismissDirection.startToEnd: 0.3},
      background: Container(
        color: palette.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.only(left: 20),
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: 'Reply to message',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.reply_rounded, color: palette.accent),
              const SizedBox(width: 7),
              Text(
                'Reply',
                style: TextStyle(
                  color: palette.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
      confirmDismiss: (_) async {
        reply();
        return false;
      },
      child: child,
    );
  }
}
