import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'message_lift.dart';

/// A swipe-to-reply affordance: right swipe on others' messages, left swipe on
/// your own. The message always springs back and never dismisses; with a
/// [MessageReplyLift] around the timeline it springs back popped out and
/// stays lifted while the reply is written.
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
      background: _SwipeReplyBackground(palette: palette, mine: mine),
      confirmDismiss: (_) async {
        liftForReply(context, reply);
        return false;
      },
      child: child,
    );
  }
}

/// Logical pixels of accent tint that fade out at each edge of the swipe bar.
const swipeReplyEdgeFade = 18.0;

double _swipeReplyFadeStop(double height) {
  if (!height.isFinite || height <= 0) return 0.22;
  return (swipeReplyEdgeFade / height).clamp(0.08, 0.4).toDouble();
}

/// Accent wash for the revealed swipe strip: solid through the middle,
/// transparent at the top and bottom so the edge does not cut a hard line.
LinearGradient swipeReplyGradient(Color accent, double height) {
  final fade = _swipeReplyFadeStop(height);
  final tint = accent.withValues(alpha: 0.12);
  final clear = tint.withValues(alpha: 0);
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [clear, tint, tint, clear],
    stops: [0, fade, 1 - fade, 1],
  );
}

class _SwipeReplyBackground extends StatelessWidget {
  const _SwipeReplyBackground({required this.palette, required this.mine});

  final AppPalette palette;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: swipeReplyGradient(palette.accent, constraints.maxHeight),
          ),
          child: Padding(
            padding: EdgeInsets.only(left: mine ? 0 : 20, right: mine ? 20 : 0),
            child: Align(
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
          ),
        );
      },
    );
  }
}
