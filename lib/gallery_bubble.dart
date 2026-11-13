import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'message_image.dart';
import 'timeline/double_tap_react.dart';
import 'timeline/reaction_pills.dart';
import 'timeline/swipe_reply.dart';
import 'features/appearance/bubble_colours.dart';

class GalleryBubble extends StatelessWidget {
  const GalleryBubble({
    super.key,
    required this.entries,
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.onHeart,
    required this.onAction,
    required this.onReaction,
    this.onReply,
  });

  final List<ChatEntry> entries;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final ValueChanged<ChatEntry> onHeart;
  final ValueChanged<ChatEntry> onAction;
  final void Function(ChatEntry, String) onReaction;
  final ValueChanged<ChatEntry>? onReply;

  Widget _photo(ChatEntry entry, double width, double height) => SwipeReply(
    key: ValueKey('swipe-photo-${entry.id}'),
    palette: palette,
    onReply: entry.redacted || onReply == null ? null : () => onReply!(entry),
    child: DoubleTapReact(
      onDoubleTap: () => onHeart(entry),
      onLongPress: () => onAction(entry),
      child: MessageImage(
        key: ValueKey(entry.id),
        backend: backend,
        palette: palette,
        roomId: roomId,
        eventId: entry.id,
        entry: entry,
        width: width,
        height: height,
      ),
    ),
  );

  Widget _layout(double width) {
    final half = (width - 4) / 2;
    if (entries.length == 2) {
      return Row(
        children: [
          _photo(entries[0], half, 170),
          const SizedBox(width: 4),
          _photo(entries[1], half, 170),
        ],
      );
    }
    if (entries.length == 3) {
      return Row(
        children: [
          _photo(entries[0], half, 204),
          const SizedBox(width: 4),
          Column(
            children: [
              _photo(entries[1], half, 100),
              const SizedBox(height: 4),
              _photo(entries[2], half, 100),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        Row(
          children: [
            _photo(entries[0], half, 120),
            const SizedBox(width: 4),
            _photo(entries[1], half, 120),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _photo(entries[2], half, 120),
            const SizedBox(width: 4),
            _photo(entries[3], half, 120),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final mine = entries.first.mine;
    final width = math.min(320.0, MediaQuery.sizeOf(context).width * 0.84);
    // The room's bubble colours apply inside the bubble.
    final outer = this.palette;
    final palette = bubblePaletteOf(context, outer);
    final pills = [
      for (var i = 0; i < entries.length; i++)
        for (final reaction in entries[i].reactions)
          ReactionPill(
            key: ValueKey('reaction-${entries[i].id}-${reaction.emoji}'),
            palette: outer,
            mine: reaction.mine,
            tooltip: reaction.mine
                ? 'Remove your ${reaction.emoji} reaction on photo ${i + 1}'
                : 'React with ${reaction.emoji} on photo ${i + 1}',
            label: Text('${i + 1}: ${reaction.emoji} ${reaction.count}'),
            onTap: () => onReaction(entries[i], reaction.emoji),
          ),
    ];
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: mine
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              width: width,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: mine ? palette.bubble : palette.surface,
                borderRadius: BorderRadius.circular(19),
                border: mine ? null : Border.all(color: palette.stroke),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!mine) ...[
                    Text(
                      entries.first.senderLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.secondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 7),
                  ],
                  LayoutBuilder(
                    builder: (_, constraints) => _layout(constraints.maxWidth),
                  ),
                  const SizedBox(height: 5),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      TimeOfDay.fromDateTime(
                        entries.last.time.toLocal(),
                      ).format(context),
                      style: TextStyle(
                        fontSize: 10,
                        color: mine
                            ? palette.bubbleText.withValues(alpha: 0.77)
                            : palette.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (pills.isNotEmpty)
              BubbleReactions(mine: mine, maxWidth: width, pills: pills),
          ],
        ),
      ),
    );
  }
}
