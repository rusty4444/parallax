import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../appearance_preferences.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';

/// One row of the home room list (Element X RoomSummaryRow): avatar, name,
/// last message with sender, timestamp, unread/mention badges, muted state and
/// inline invite actions.
class RoomListTile extends StatelessWidget {
  const RoomListTile({
    super.key,
    required this.room,
    required this.backend,
    required this.palette,
    required this.onTap,
    this.onLongPress,
    this.onAccept,
    this.onDecline,
    this.onCopyCode,
    this.favourite = false,
    this.failedSend = false,
    this.compact = false,
    this.hideInviteAvatar = false,
    this.busy = false,
    this.style = HomeRowStyle.cards,
    this.preview = HomePreview.long,
    this.selected = false,
  });

  final ChatRoom room;
  final ChatBackend backend;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  /// Copies the one-time code of an unread last message. Without it the
  /// row offers no Copy button.
  final ValueChanged<String>? onCopyCode;
  final bool favourite;
  final bool failedSend;
  final bool compact;
  final bool hideInviteAvatar;
  final bool busy;

  /// Open in the tablet/foldable detail pane: the row carries a tint.
  final bool selected;

  /// Cards, flat list rows or compact rows (Settings → Appearance).
  final HomeRowStyle style;

  /// Lines of last-message preview: none, one or two. Invitations always
  /// say what they are.
  final HomePreview preview;

  static String timeLabel(
    BuildContext context,
    DateTime? value, {
    DateTime? now,
  }) {
    if (value == null) return '';
    final current = now ?? DateTime.now();
    final local = value.toLocal();
    final today = DateTime(current.year, current.month, current.day);
    final day = DateTime(local.year, local.month, local.day);
    final age = today.difference(day).inDays;
    if (age == 0) return TimeOfDay.fromDateTime(local).format(context);
    if (age == 1) return 'Yesterday';
    if (age > 1 && age < 7) {
      return const [
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun',
      ][local.weekday - 1];
    }
    if (local.year == current.year) return '${local.day}/${local.month}';
    return '${local.day}/${local.month}/${local.year % 100}';
  }

  @override
  Widget build(BuildContext context) {
    // The people named in this row are checked with the server once.
    if (!room.invited) backend.roomShown(room.id);
    final p = palette;
    final unread = room.unread > 0 || room.manuallyUnread || failedSend;
    final mentioned = room.highlightCount > 0;
    final emphasised = !room.invited && (unread || mentioned);
    final badgeColour = room.muted ? p.muted : p.accent;
    final cards = style == HomeRowStyle.cards;
    final dense = compact || style == HomeRowStyle.compact;
    final avatarSize = style == HomeRowStyle.compact ? 40.0 : 52.0;
    // Invitations always say what they are; otherwise the setting decides.
    final previewLines = room.invited ? 2 : preview.maxLines;
    // As in Google Messages: an unread code can be copied from the list.
    final code =
        onCopyCode != null &&
            !room.invited &&
            (room.unread > 0 || room.manuallyUnread)
        ? room.previewCode
        : null;
    final previewText = room.invited
        ? (room.isDirect ? 'Invited you to chat' : 'Invited you to join')
        : room.preview.isEmpty
        ? 'No messages yet'
        : room.previewIncludesSender
        ? room.preview
        : room.previewSender == null
        ? room.preview
        : '${room.previewSender}: ${room.preview}';
    final lock = room.encrypted
        ? [
            Icon(Icons.lock_outline, size: 13, color: p.secondary),
            const SizedBox(width: 4),
          ]
        : const <Widget>[];
    final badges = room.invited
        ? [
            const SizedBox(width: 8),
            Text(
              'INVITE',
              style: TextStyle(
                color: p.secondary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ]
        : [
            if (mentioned) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Mentioned',
                child: _Badge(
                  colour: badgeColour,
                  palette: p,
                  child: Icon(
                    Icons.alternate_email_rounded,
                    size: 12,
                    color: room.muted ? p.background : p.accentOn,
                  ),
                ),
              ),
            ],
            if (room.unread > 0 || room.manuallyUnread) ...[
              const SizedBox(width: 6),
              _Badge(
                colour: badgeColour,
                palette: p,
                child: Text(
                  room.unread == 0
                      ? '•'
                      : room.unread > 99
                      ? '99+'
                      : '${room.unread}',
                  style: TextStyle(
                    color: room.muted ? p.background : p.accentOn,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ];
    final nameRow = Row(
      children: [
        // Without a preview line, the lock and badges join the name.
        if (previewLines == 0) ...lock,
        Expanded(
          child: Text(
            room.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.foreground,
              fontWeight: emphasised ? FontWeight.w800 : FontWeight.w700,
              fontSize: dense ? 15 : 16,
            ),
          ),
        ),
        if (favourite) Icon(Icons.star_rounded, size: 16, color: p.accent),
        if (failedSend)
          Tooltip(
            message: 'Message not sent',
            child: Icon(Icons.error_outline, size: 16, color: p.accent),
          ),
        if (room.muted)
          Tooltip(
            message: 'Notifications muted',
            child: Icon(
              Icons.notifications_off_outlined,
              size: 15,
              color: p.muted,
            ),
          ),
        const SizedBox(width: 6),
        Text(
          timeLabel(context, room.lastActivity),
          style: TextStyle(
            color: emphasised && !room.muted ? p.accent : p.muted,
            fontSize: 11,
            fontWeight: emphasised ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        if (previewLines == 0) ...badges,
      ],
    );
    final content = Row(
      crossAxisAlignment: previewLines == 0
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        room.invited && hideInviteAvatar
            ? InitialAvatar(name: room.name, palette: p, size: avatarSize)
            : RoomAvatar(
                room: room,
                backend: backend,
                palette: p,
                size: avatarSize,
              ),
        SizedBox(width: dense ? 11 : 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              nameRow,
              if (previewLines > 0) ...[
                SizedBox(height: dense ? 3 : 5),
                Row(
                  children: [
                    ...lock,
                    Expanded(
                      child: Text(
                        previewText,
                        maxLines: previewLines,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: emphasised ? p.foreground : p.muted,
                          fontSize: 13,
                          height: 1.25,
                        ),
                      ),
                    ),
                    ...badges,
                  ],
                ),
              ],
              if (code != null) ...[
                SizedBox(height: dense ? 6 : 8),
                _CopyCodeButton(
                  key: ValueKey('copy-code-${room.id}'),
                  code: code,
                  palette: p,
                  onPressed: () => onCopyCode!(code),
                ),
              ],
              if (room.invited && (onAccept != null || onDecline != null)) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: busy ? null : onDecline,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.foreground,
                          side: BorderSide(color: p.stroke),
                        ),
                        child: const Text('Decline'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: busy ? null : onAccept,
                        child: const Text('Accept'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final inviteTint = Color.alphaBlend(
      p.secondary.withValues(alpha: 0.08),
      p.surface,
    );
    final selectedTint = Color.alphaBlend(
      p.accent.withValues(alpha: 0.16),
      p.surface,
    );
    if (cards) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected
              ? selectedTint
              : room.invited
              ? inviteTint
              : p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: selected
                ? BorderSide(color: p.accent.withValues(alpha: 0.5))
                : room.invited
                ? BorderSide(color: p.secondary.withValues(alpha: 0.5))
                : BorderSide.none,
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: EdgeInsets.all(dense ? 9 : 14),
              child: content,
            ),
          ),
        ),
      );
    }
    // List and compact: flat rows divided by a line under the text.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: selected
              ? selectedTint
              : room.invited
              ? inviteTint
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 4,
                vertical: dense ? 7 : 11,
              ),
              child: content,
            ),
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          indent: avatarSize + (dense ? 15 : 17),
          color: p.stroke.withValues(alpha: 0.6),
        ),
      ],
    );
  }
}

/// "Copy ‘123456’" under an unread row whose last message has a one-time
/// code, so the code can be copied without opening the chat.
class _CopyCodeButton extends StatelessWidget {
  const _CopyCodeButton({
    super.key,
    required this.code,
    required this.palette,
    required this.onPressed,
  });
  final String code;
  final AppPalette palette;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Copy code $code',
    excludeSemantics: true,
    child: Material(
      color: palette.accent.withValues(alpha: 0.14),
      shape: StadiumBorder(
        side: BorderSide(color: palette.accent.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.content_copy_rounded,
                  size: 15,
                  color: palette.accent,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    'Copy ‘$code’',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.colour,
    required this.palette,
    required this.child,
  });
  final Color colour;
  final AppPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: colour,
      borderRadius: BorderRadius.circular(11),
    ),
    child: child,
  );
}
