import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../chat_backend.dart';
import 'overlap_up.dart';

/// Hover text for a reaction pill: who reacted, as in Element
/// ("You, Alice and 3 others reacted with 👍"). [keyLabel] is the emoji or a
/// custom emoji's shortcode; [suffix] (for example " to photo 2") follows it.
/// Names come from [ChatReaction.senders]; anyone the backend did not name
/// is counted as "N others", so the total always matches the pill.
String reactionSendersTooltip(
  ChatReaction reaction,
  String keyLabel, {
  String? ownUserId,
  String suffix = '',
  int maxNames = 6,
}) {
  final names = <String>[
    if (reaction.mine) 'You',
    for (final sender in reaction.senders)
      if (!(reaction.mine && sender.userId == ownUserId)) sender.label,
  ];
  final total = names.length > reaction.count ? names.length : reaction.count;
  final shown = names.take(maxNames).toList();
  final others = total - shown.length;
  final what = 'reacted with $keyLabel$suffix';
  if (shown.isEmpty) {
    return '$total ${total == 1 ? 'person' : 'people'} $what';
  }
  final parts = [
    ...shown,
    if (others > 0) '$others ${others == 1 ? 'other' : 'others'}',
  ];
  final who = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  return '$who $what';
}

/// One reaction as a small pill (emoji and count). Mine are outlined in the
/// accent colour; tap toggles it, long press shows who reacted.
class ReactionPill extends StatelessWidget {
  const ReactionPill({
    super.key,
    required this.label,
    required this.tooltip,
    required this.mine,
    required this.palette,
    required this.onTap,
    this.onLongPress,
  });

  final Widget label;
  final String tooltip;
  final bool mine;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final fill = mine
        ? Color.alphaBlend(
            palette.accent.withValues(alpha: 0.24),
            palette.raised,
          )
        : palette.raised;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        selected: mine,
        child: Material(
          color: fill,
          elevation: 1.5,
          shadowColor: Colors.black54,
          shape: StadiumBorder(
            // A ring that separates the pill from both the bubble and the
            // room background (Messenger's hairline).
            side: BorderSide(
              color: mine ? palette.accent : palette.stroke,
              width: 1.5,
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.foreground,
                ),
                child: label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reactions hung on the bottom edge of their bubble, toward its outer
/// corner, as in Messenger.
class BubbleReactions extends StatelessWidget {
  const BubbleReactions({
    super.key,
    required this.mine,
    required this.pills,
    this.maxWidth,
  });

  /// Overlap with the bubble above.
  static const overlap = 9.0;

  final bool mine;
  final List<Widget> pills;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) => OverlapUp(
    overlap: overlap,
    child: Padding(
      // Room below so the next message isn't crowded.
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
        child: Wrap(
          key: const ValueKey('bubble-reactions'),
          alignment: mine ? WrapAlignment.end : WrapAlignment.start,
          spacing: 4,
          runSpacing: 4,
          children: pills,
        ),
      ),
    ),
  );
}
