import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'overlap_up.dart';

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
