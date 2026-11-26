import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'hooks/hook_types.dart';
import 'message_image.dart';
import 'room_avatar.dart';
import 'timeline/double_tap_react.dart';
import 'timeline/message_bubble.dart';
import 'timeline/message_hover_menu.dart';
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
    this.hoverActionsBuilder,
    this.showSender = false,
  });

  final List<ChatEntry> entries;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final ValueChanged<ChatEntry> onHeart;
  final ValueChanged<ChatEntry> onAction;
  final void Function(ChatEntry, String) onReaction;
  final ValueChanged<ChatEntry>? onReply;

  /// Desktop hover quick actions, per photo (as long-press is per photo).
  final List<MessageActionItem> Function(ChatEntry entry)? hoverActionsBuilder;

  /// Show the sender's avatar beside the gallery (first of a run, others'
  /// messages, outside direct chats).
  final bool showSender;

  Widget _photo(ChatEntry entry, double width, double height) {
    final photo = DoubleTapReact(
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
        // Mosaic cells keep their fixed grid shape.
        autoAspect: false,
      ),
    );
    final builder = hoverActionsBuilder;
    return SwipeReply(
      key: ValueKey('swipe-photo-${entry.id}'),
      palette: palette,
      mine: entry.mine,
      onReply: entry.redacted || onReply == null ? null : () => onReply!(entry),
      child: builder == null
          ? photo
          : MessageHoverMenu(
              actionsBuilder: () => builder(entry),
              palette: palette,
              child: photo,
            ),
    );
  }

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
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Match single-message bubbles: reserve the avatar column for others'
    // messages and cap the width the same way, so a gallery lines up with
    // the text and single-image bubbles above and below it.
    final avatars = !mine;
    final maxWidth = bubbleMaxWidth(screenWidth, mine: mine, avatars: avatars);
    final width = math.min(320.0, maxWidth);
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
            tooltip: reactionSendersTooltip(
              reaction,
              reaction.emoji,
              ownUserId: backend.userId,
              suffix: ' to photo ${i + 1}',
            ),
            label: Text('${i + 1}: ${reaction.emoji} ${reaction.count}'),
            onTap: () => onReaction(entries[i], reaction.emoji),
          ),
    ];
    final gallery = Column(
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
    );
    final row = avatars
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: senderAvatarSize,
                child: showSender
                    ? UserAvatar(
                        key: ValueKey('avatar-${entries.first.id}'),
                        name: entries.first.senderLabel,
                        url: entries.first.senderAvatar,
                        backend: backend,
                        palette: outer,
                        size: senderAvatarSize,
                      )
                    : null,
              ),
              const SizedBox(width: 8),
              Flexible(child: gallery),
            ],
          )
        : gallery;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(padding: const EdgeInsets.only(top: 14), child: row),
    );
  }
}
