import 'package:flutter/material.dart';

import '../../app_theme.dart';
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
    this.favourite = false,
    this.failedSend = false,
    this.compact = false,
    this.hideInviteAvatar = false,
    this.busy = false,
  });

  final ChatRoom room;
  final ChatBackend backend;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final bool favourite;
  final bool failedSend;
  final bool compact;
  final bool hideInviteAvatar;
  final bool busy;

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
    final preview = room.invited
        ? (room.isDirect ? 'Invited you to chat' : 'Invited you to join')
        : room.preview.isEmpty
        ? 'No messages yet'
        : room.previewSender == null
        ? room.preview
        : '${room.previewSender}: ${room.preview}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: room.invited
            ? Color.alphaBlend(p.secondary.withValues(alpha: 0.08), p.surface)
            : p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: room.invited
              ? BorderSide(color: p.secondary.withValues(alpha: 0.5))
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: EdgeInsets.all(compact ? 9 : 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                room.invited && hideInviteAvatar
                    ? InitialAvatar(name: room.name, palette: p)
                    : RoomAvatar(room: room, backend: backend, palette: p),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              room.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.foreground,
                                fontWeight: emphasised
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          if (favourite)
                            Icon(Icons.star_rounded, size: 16, color: p.accent),
                          if (failedSend)
                            Tooltip(
                              message: 'Message not sent',
                              child: Icon(
                                Icons.error_outline,
                                size: 16,
                                color: p.accent,
                              ),
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
                              color: emphasised && !room.muted
                                  ? p.accent
                                  : p.muted,
                              fontSize: 11,
                              fontWeight: emphasised
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (room.encrypted) ...[
                            Icon(
                              Icons.lock_outline,
                              size: 13,
                              color: p.secondary,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: emphasised ? p.foreground : p.muted,
                                fontSize: 13,
                                height: 1.25,
                              ),
                            ),
                          ),
                          if (room.invited) ...[
                            const SizedBox(width: 8),
                            Text(
                              'INVITE',
                              style: TextStyle(
                                color: p.secondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ] else ...[
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
                                    color: room.muted
                                        ? p.background
                                        : p.accentOn,
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
                                    color: room.muted
                                        ? p.background
                                        : p.accentOn,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                      if (room.invited &&
                          (onAccept != null || onDecline != null)) ...[
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
            ),
          ),
        ),
      ),
    );
  }
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
