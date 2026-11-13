import 'package:flutter/material.dart';

import '../app_theme.dart';

/// A swipe-to-reply affordance: right swipe on others' messages, left swipe on
/// your own. The message always springs back and never dismisses.
class SwipeReply extends StatelessWidget {
  const SwipeReply({
    required super.key,
    required this.palette,
    required this.onReply,
    required this.child,
    this.mine = false,
  });

  final AppPalette palette;
  final VoidCallback? onReply;
  final Widget child;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final reply = onReply;
    if (reply == null) return child;
    final direction = mine
        ? DismissDirection.endToStart
        : DismissDirection.startToEnd;
    return Dismissible(
      key: key!,
      direction: direction,
      dismissThresholds: {direction: 0.3},
      background: Container(
        color: palette.accent.withValues(alpha: 0.12),
        padding: EdgeInsets.only(left: mine ? 0 : 20, right: mine ? 20 : 0),
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
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
