import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'message_image.dart';

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
  });

  final List<ChatEntry> entries;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final ValueChanged<ChatEntry> onHeart;
  final ValueChanged<ChatEntry> onAction;
  final void Function(ChatEntry, String) onReaction;

  Widget _photo(ChatEntry entry, double width, double height) =>
      GestureDetector(
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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Container(
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
              for (var i = 0; i < entries.length; i++)
                if (entries[i].reactions.isNotEmpty)
                  Wrap(
                    spacing: 5,
                    children: [
                      for (final reaction in entries[i].reactions)
                        ActionChip(
                          tooltip: reaction.mine
                              ? 'Remove your ${reaction.emoji} reaction on photo ${i + 1}'
                              : 'React with ${reaction.emoji} on photo ${i + 1}',
                          label: Text(
                            '${i + 1}: ${reaction.emoji} ${reaction.count}',
                          ),
                          onPressed: () =>
                              onReaction(entries[i], reaction.emoji),
                        ),
                    ],
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
      ),
    );
  }
}
