import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../chat_backend.dart';
import '../gallery_bubble.dart';
import '../message_groups.dart';
import 'message_bubble.dart';

/// The scrolling room timeline (newest at the bottom).
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.entries,
    required this.compact,
    required this.onHeart,
    required this.onAction,
    required this.onReaction,
    required this.onLoadOlder,
    this.room,
  });

  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  /// Loaded entries, oldest first.
  final List<ChatEntry> entries;
  final bool compact;
  final ValueChanged<ChatEntry> onHeart;
  final ValueChanged<ChatEntry> onAction;
  final void Function(ChatEntry entry, String emoji) onReaction;
  final VoidCallback onLoadOlder;
  final ChatRoom? room;

  @override
  Widget build(BuildContext context) {
    final rows = groupTimeline(entries);
    return ListView.builder(
      reverse: true,
      padding: EdgeInsets.fromLTRB(16, compact ? 8 : 20, 16, compact ? 8 : 18),
      itemCount: rows.length + (backend.canLoadOlder ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Center(
            child: TextButton(
              onPressed: backend.loadingHistory ? null : onLoadOlder,
              child: Text(
                backend.loadingHistory ? 'Loading…' : 'Load earlier messages',
              ),
            ),
          );
        }
        final row = rows[rows.length - index - 1];
        if (row.isGallery) {
          return GalleryBubble(
            key: ValueKey(row.entries.first.id),
            entries: row.entries,
            backend: backend,
            roomId: roomId,
            palette: palette,
            onHeart: onHeart,
            onAction: onAction,
            onReaction: onReaction,
          );
        }
        final entry = row.entries.single;
        final previous = rows.length - index - 2 >= 0
            ? rows[rows.length - index - 2].entries.last
            : null;
        final group =
            previous != null &&
            previous.kind != EntryKind.state &&
            previous.sender == entry.sender &&
            entry.time.difference(previous.time).inMinutes < 5;
        return MessageBubble(
          key: ValueKey(entry.id),
          entry: entry,
          backend: backend,
          roomId: roomId,
          palette: palette,
          group: group,
          room: room,
          entries: entries,
          onHeart: () => onHeart(entry),
          onAction: () => onAction(entry),
          onReaction: (emoji) => onReaction(entry, emoji),
          replyPreview: entry.replyToId == null
              ? null
              : entries.where((item) => item.id == entry.replyToId).firstOrNull,
        );
      },
    );
  }
}
