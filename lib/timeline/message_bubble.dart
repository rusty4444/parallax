import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../chat_backend.dart';
import '../feature_settings_scope.dart';
import '../features/rich_timeline/rich_timeline_features.dart';
import '../features/rich_timeline/rich_timeline_hooks.dart';
import '../features/media/media_hooks.dart';
import '../features/packs/pack_image.dart';
import '../features/reactions/reaction_hooks.dart';
import '../features/rich_timeline/timeline_widgets.dart';
import '../features/rooms_admin/rooms_admin_hooks.dart';
import '../hooks/registry.dart';
import '../media_viewer.dart';
import '../message_image.dart';
import '../room_avatar.dart';
import 'bubble_column.dart';
import 'double_tap_react.dart';
import 'message_hover_menu.dart';
import 'reaction_pills.dart';
import 'reply_quote.dart';
import '../features/appearance/bubble_colours.dart';

/// Width of the sender-avatar column beside others' messages.
const senderAvatarSize = 32.0;
const _avatarGap = 8.0;

/// Widest a message bubble gets, so lines stay readable on tablets.
const _maxBubbleWidth = 520.0;

/// Widest bubble for a screen [screenWidth] wide. Own messages are capped
/// like others' messages next to an avatar, so a long message of yours
/// never reaches further left than theirs reach right.
double bubbleMaxWidth(
  double screenWidth, {
  required bool mine,
  required bool avatars,
}) => math.min(
  _maxBubbleWidth,
  screenWidth * 0.83 - (mine || avatars ? senderAvatarSize + _avatarGap : 0),
);

/// One timeline entry. State events render as a centred line; everything
/// else is a bubble whose body comes from a feature hook when one claims the
/// entry's kind, otherwise the core image/attachment/text rendering.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.entry,
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.group,
    required this.onHeart,
    required this.onAction,
    required this.onReaction,
    this.replyPreview,
    this.room,
    this.entries = const [],
    this.showSender,
    this.showAvatars,
    this.receipts = const [],
    this.sent = false,
    this.onReceipts,
    this.hoverActionsBuilder,
  });
  final ChatEntry entry;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  /// Continues a group of messages from the same sender.
  final bool group;
  final VoidCallback onHeart;
  final VoidCallback onAction;
  final ValueChanged<String> onReaction;
  final ChatEntry? replyPreview;
  final ChatRoom? room;
  final List<ChatEntry> entries;

  /// Show the sender's avatar and name. Defaults to the first message of a
  /// group from someone else.
  final bool? showSender;

  /// Reserve an avatar column for others' messages (default true).
  final bool? showAvatars;

  /// Users whose latest read receipt is on this event.
  final List<ReceiptReader> receipts;

  /// Show the "Sent" tick (own latest message without receipts).
  final bool sent;
  final VoidCallback? onReceipts;

  /// Desktop hover quick actions (react, reply, thread, edit, pin, more).
  /// Resolved on hover, so idle timeline builds stay cheap. Null keeps the
  /// message free of the floating bar (touch platforms ignore it anyway).
  final List<MessageActionItem> Function()? hoverActionsBuilder;

  @override
  Widget build(BuildContext context) {
    // Inside the bubble the room's bubble colours apply; the avatar, read
    // receipts and reactions outside it keep the theme ([outer]).
    final outer = this.palette;
    if (entry.kind == EntryKind.state) {
      return StateEventLine(
        entry: entry,
        palette: outer,
        backend: backend,
        roomId: roomId,
      );
    }
    final palette = bubblePaletteOf(context, outer);
    final mine = entry.mine;
    final compact =
        FeatureSettingsScope.maybeOf(context)?.preferences.compact ?? false;
    final hook = EntryHookContext(
      backend: backend,
      roomId: roomId,
      palette: palette,
      entry: entry,
      room: room,
      entries: entries,
    );
    final special = entryBodyFor(context, hook);
    final footers = entryFootersFor(context, hook);
    final textColor = mine ? palette.bubbleText : palette.foreground;
    final avatars = !mine && (showAvatars ?? true);
    final sender = showSender ?? (!mine && !group);
    final highlighted = entry.highlight && !mine && !entry.redacted;
    final maxWidth = bubbleMaxWidth(
      MediaQuery.sizeOf(context).width,
      mine: mine,
      avatars: avatars,
    );
    // Stickers render without bubble chrome, as in Element X.
    final standalone = mediaEntryStandalone(
      context,
      hook,
      onLongPress: onAction,
    );
    final bubble = standalone != null
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: standalone,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: mine
                    ? palette.bubble
                    : highlighted
                    ? Color.alphaBlend(
                        palette.accent.withValues(alpha: 0.12),
                        palette.surface,
                      )
                    : palette.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(19),
                  topRight: const Radius.circular(19),
                  bottomLeft: Radius.circular(mine ? 19 : 5),
                  bottomRight: Radius.circular(mine ? 5 : 19),
                ),
                border: mine
                    ? null
                    : Border.all(
                        color: highlighted
                            ? palette.accent.withValues(alpha: 0.75)
                            : palette.stroke,
                        width: highlighted ? 1.5 : 1,
                      ),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: compact ? 5 : 8),
                // Wrapped lines hug the longest one, and the bubble is as
                // wide as its content (short messages, short bubbles).
                child: DefaultTextStyle.merge(
                  textWidthBasis: TextWidthBasis.longestLine,
                  child: BubbleColumn(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          14,
                          compact ? 6 : 10,
                          14,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!mine && sender) ...[
                              Text(
                                entry.senderLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.secondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 5),
                            ],
                            if (entry.replyToId != null) ...[
                              ReplyQuote(
                                backend: backend,
                                roomId: roomId,
                                replyToId: entry.replyToId!,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      left: BorderSide(
                                        color: palette.secondary,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    replyPreview == null
                                        ? 'In reply to an earlier message'
                                        : '${replyPreview!.senderLabel}: ${replyPreview!.body}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: mine
                                          ? palette.bubbleText
                                          : palette.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 5),
                            ],
                            if (special != null)
                              special
                            else ...[
                              if (entry.isImage) ...[
                                MessageImage(
                                  backend: backend,
                                  palette: palette,
                                  roomId: roomId,
                                  eventId: entry.id,
                                ),
                                const SizedBox(height: 4),
                              ],
                              if (entry.isAttachment)
                                _AttachmentRow(
                                  entry: entry,
                                  backend: backend,
                                  roomId: roomId,
                                  palette: palette,
                                )
                              else if (entry.body.isNotEmpty)
                                buildMessageText(
                                  context,
                                  hook,
                                  style: TextStyle(
                                    color: textColor,
                                    fontSize: 15,
                                    height: 1.35,
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      for (final footer in footers)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: footer,
                        ),
                      BubbleEnd(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                          child: Text(
                            [
                              if (entry.edited && !entry.redacted) '(edited)',
                              TimeOfDay.fromDateTime(
                                entry.time.toLocal(),
                              ).format(context),
                            ].join('  '),
                            style: TextStyle(
                              fontSize: 10,
                              color: mine
                                  ? palette.bubbleText.withValues(alpha: 0.77)
                                  : palette.muted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
    // Reactions hang on the bubble's bottom edge (Messenger), outside the
    // double-tap area so tapping a reaction toggles it at once.
    final reactions = entry.reactions.isEmpty || standalone != null
        ? null
        : BubbleReactions(
            mine: mine,
            maxWidth: maxWidth,
            pills: [
              for (final reaction in entry.reactions)
                ReactionPill(
                  key: ValueKey('reaction-${entry.id}-${reaction.emoji}'),
                  palette: outer,
                  mine: reaction.mine,
                  tooltip: reaction.mine
                      ? 'Remove your ${reactionKeyLabel(backend, roomId, reaction.emoji)} reaction'
                      : 'React with ${reactionKeyLabel(backend, roomId, reaction.emoji)}',
                  // Custom emoji reactions (MSC4027) show the pack image;
                  // others keep the emoji text.
                  label:
                      customReactionChipLabel(
                        backend: backend,
                        roomId: roomId,
                        reactionKey: reaction.emoji,
                        count: reaction.count,
                      ) ??
                      Text('${reaction.emoji} ${reaction.count}'),
                  onTap: () => onReaction(reaction.emoji),
                  // Element X: long-press a reaction to see who reacted.
                  onLongPress: () => showReactionSummaryForEntry(
                    context,
                    hook,
                    emoji: reaction.emoji,
                  ),
                ),
            ],
          );
    // The entire padded bubble is a reply/reaction target, not just its text.
    // Reaction pills deliberately stay outside this gesture area so one tap
    // toggles them without also triggering a double-tap or long-press action.
    final gestureBubble = DoubleTapReact(
      onDoubleTap: onHeart,
      onLongPress: onAction,
      child: bubble,
    );
    // Desktop: drag to select message text and Ctrl+C (Cmd+C on macOS) to
    // copy. The inner DoubleTapReact keeps long-press / right-click for the
    // full action menu (reply, edit, react, copy, forward, …), so the
    // selection toolbar is suppressed to avoid a competing right-click menu.
    final Widget selectableBubble =
        (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.linux))
        ? SelectionArea(
            contextMenuBuilder: (context, state) => const SizedBox.shrink(),
            child: gestureBubble,
          )
        : gestureBubble;
    final reacted = reactions == null
        ? selectableBubble
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [selectableBubble, reactions],
          );
    // Desktop: the quick-action bar floats over the hovered message without
    // touching the timeline's layout (it lives in the route's overlay).
    final hoverable = hoverActionsBuilder == null
        ? reacted
        : MessageHoverMenu(
            actionsBuilder: hoverActionsBuilder!,
            palette: outer,
            child: reacted,
          );
    final row = avatars
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: senderAvatarSize,
                // The sender's picture starts each run of their messages,
                // in direct chats too (where the name stays hidden).
                child: !group
                    ? GestureDetector(
                        onTap: () => openUserProfile(
                          context,
                          backend,
                          outer,
                          entry.sender,
                          roomId: roomId,
                        ),
                        child: UserAvatar(
                          key: ValueKey('avatar-${entry.id}'),
                          name: entry.senderLabel,
                          url: entry.senderAvatar,
                          backend: backend,
                          palette: outer,
                          size: senderAvatarSize,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: _avatarGap),
              Flexible(child: hoverable),
            ],
          )
        : hoverable;
    return Padding(
      padding: EdgeInsets.only(top: group ? 3 : (compact ? 7 : 14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: row,
          ),
          if (receipts.isNotEmpty || sent)
            ReadReceiptsRow(
              readers: receipts,
              backend: backend,
              palette: outer,
              sent: sent,
              onTap: onReceipts ?? () {},
            ),
        ],
      ),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.entry,
    required this.backend,
    required this.roomId,
    required this.palette,
  });
  final ChatEntry entry;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final mine = entry.mine;
    return InkWell(
      onTap: () => openMediaViewer(
        context,
        backend: backend,
        roomId: roomId,
        eventId: entry.id,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              color: mine ? palette.bubbleText : palette.secondary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                entry.body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: mine ? palette.bubbleText : palette.foreground,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.download_rounded,
              size: 18,
              color: mine ? palette.bubbleText : palette.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// A room state change (membership, name, topic …) as a centred line, in
/// Element X wording when the backend can describe it.
class StateEventLine extends StatelessWidget {
  const StateEventLine({
    super.key,
    required this.entry,
    required this.palette,
    this.backend,
    this.roomId,
  });
  final ChatEntry entry;
  final AppPalette palette;
  final ChatBackend? backend;
  final String? roomId;

  @override
  Widget build(BuildContext context) => StateChangeLine(
    entry: entry,
    palette: palette,
    backend: backend,
    roomId: roomId,
  );
}
