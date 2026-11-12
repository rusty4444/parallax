import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'event_projection.dart';
import 'timeline_navigation.dart';

/// The palette of the active app theme, for screens pushed without one.
AppPalette paletteFromTheme(BuildContext context, [AppPalette? explicit]) {
  if (explicit != null) return explicit;
  final theme = Theme.of(context);
  for (final style in VisualTheme.values) {
    final palette = paletteFor(style);
    if (palette.accent == theme.colorScheme.primary &&
        palette.background == theme.scaffoldBackgroundColor) {
      return palette;
    }
  }
  return paletteFor(defaultVisualTheme);
}

/// Whether read receipts may be public (Settings → Privacy → Send read
/// receipts).
bool publicReceiptsAllowed(BuildContext context) =>
    FeatureSettingsScope.maybeOf(context)?.preferences.sendReadReceipts ?? true;

String replyCountLabel(int count) => count == 1 ? '1 reply' : '$count replies';

/// Compact time or date label: time today, weekday this week, else date.
String activityLabel(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final age = today.difference(day).inDays;
  if (age == 0) {
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
  }
  if (age == 1) return 'Yesterday';
  if (age > 1 && age < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[local.weekday - 1];
  }
  return local.year == now.year
      ? '${local.day}/${local.month}'
      : '${local.day}/${local.month}/${local.year}';
}

/// Thread summary under a thread root in the main timeline (Element X's
/// thread summary row): reply count, latest reply preview, opens the thread.
class ThreadSummaryChip extends StatelessWidget {
  const ThreadSummaryChip({
    super.key,
    required this.entry,
    required this.palette,
    required this.onBubble,
    required this.onOpen,
  });
  final ChatEntry entry;
  final AppPalette palette;
  final Color onBubble;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final latest = entry.threadLatestBody?.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final count = replyCountLabel(entry.threadReplyCount);
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Semantics(
        button: true,
        label: 'Open thread, $count',
        child: Material(
          color: palette.background.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey('thread-summary-${entry.id}'),
            borderRadius: BorderRadius.circular(14),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 7, 11, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forum_rounded, size: 16, color: palette.accent),
                  const SizedBox(width: 6),
                  Text(
                    count,
                    style: TextStyle(
                      color: onBubble,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (latest != null && latest.isNotEmpty) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        latest,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onBubble.withValues(alpha: 0.78),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: onBubble.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks the event a room was opened at (search result, permalink, pin).
class FocusedEventMarker extends StatelessWidget {
  const FocusedEventMarker({
    super.key,
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.onBubble,
    required this.navigation,
  });
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final Color onBubble;
  final TimelineNavigation navigation;

  @override
  Widget build(BuildContext context) {
    final newer = navigation.hasNewerThanFocus(roomId);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.accent, width: 1.4),
          color: palette.accent.withValues(alpha: 0.12),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.my_location_rounded,
                    size: 15,
                    color: palette.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Jumped to this message',
                    style: TextStyle(
                      color: onBubble,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (newer)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: palette.secondary,
                ),
                onPressed: () => jumpToLatest(context, navigation, roomId),
                child: const Text('Jump to latest'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Leaves a focused timeline, reporting failures without leaving the room.
Future<void> jumpToLatest(
  BuildContext context,
  TimelineNavigation navigation,
  String roomId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await navigation.jumpToLatest(roomId);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Couldn’t load the latest messages.')),
    );
  }
}

/// A rounded list card used by the threads list.
class ThreadListTile extends StatelessWidget {
  const ThreadListTile({
    super.key,
    required this.palette,
    required this.root,
    required this.replyCount,
    required this.activity,
    required this.onTap,
    this.latest,
    this.unread,
  });
  final AppPalette palette;
  final ChatEntry root;
  final ChatEntry? latest;
  final int replyCount;
  final DateTime activity;
  final bool? unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isUnread = unread ?? false;
    return Card(
      color: p.surface,
      margin: const EdgeInsets.only(bottom: 9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.stroke),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 16, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Initial(name: root.senderLabel, palette: p),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            root.senderLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Text(
                          activityLabel(context, activity),
                          style: TextStyle(
                            color: isUnread ? p.accent : p.muted,
                            fontSize: 11,
                            fontWeight: isUnread
                                ? FontWeight.w800
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entryPreview(root),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground.withValues(alpha: 0.86),
                              fontSize: 14,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (isUnread)
                          Semantics(
                            label: 'Unread replies',
                            child: Container(
                              key: const ValueKey('thread-unread-dot'),
                              margin: const EdgeInsets.only(left: 8),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: p.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(Icons.forum_rounded, size: 15, color: p.secondary),
                        const SizedBox(width: 5),
                        Text(
                          replyCountLabel(replyCount),
                          style: TextStyle(
                            color: p.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (latest case final latest?) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${latest.senderLabel}: ${entryPreview(latest)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.muted, fontSize: 12),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Initial extends StatelessWidget {
  const _Initial({required this.name, required this.palette});
  final String name;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.replaceFirst(RegExp(r'^[@!#+]'), '').trim();
    final letter = trimmed.isEmpty
        ? '?'
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: accentGradient(palette),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: palette.accentOn,
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      ),
    );
  }
}
