import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../message_groups.dart';

/// Element X groups consecutive messages from one sender within 5 minutes.
const senderGroupingWindow = Duration(minutes: 5);

/// Runs of this many removed messages collapse into one row (Element X).
const minRemovedRun = 3;

/// One visual row of the room timeline.
sealed class TimelineRow {
  const TimelineRow();

  /// Stable key for list diffing.
  String get key;
}

/// "Today", "Yesterday" or a date between days.
class DaySeparatorRow extends TimelineRow {
  const DaySeparatorRow(this.day);

  /// Local midnight of the day.
  final DateTime day;

  @override
  String get key =>
      'day-${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
}

/// A single event (message bubble or state line).
class EntryRow extends TimelineRow {
  const EntryRow(
    this.entry, {
    required this.continuesGroup,
    required this.showSender,
  });
  final ChatEntry entry;

  /// Follows a message from the same sender within [senderGroupingWindow].
  final bool continuesGroup;

  /// Show the sender's avatar and name (first message of a group from
  /// someone else, outside direct chats).
  final bool showSender;

  @override
  String get key => entry.id;
}

/// Consecutive photos from one sender, rendered as a gallery.
class GalleryRow extends TimelineRow {
  const GalleryRow(this.entries, {required this.showSender});
  final List<ChatEntry> entries;
  final bool showSender;

  @override
  String get key => entries.first.id;
}

enum CollapsedKind { roomChanges, removedMessages }

/// An expandable summary such as "3 room changes" or "4 removed messages".
class CollapsedRow extends TimelineRow {
  const CollapsedRow(this.groupId, this.kind, this.entries);
  final String groupId;
  final CollapsedKind kind;

  /// Oldest first.
  final List<ChatEntry> entries;

  @override
  String get key => groupId;

  String get label {
    final count = entries.length;
    return switch (kind) {
      CollapsedKind.roomChanges =>
        count == 1 ? '1 room change' : '$count room changes',
      CollapsedKind.removedMessages =>
        count == 1 ? '1 removed message' : '$count removed messages',
    };
  }
}

/// Builds rows from [entries] (oldest first).
///
/// [groupIds] maps an event ID to the ID of the collapsed group it started,
/// so a group keeps its identity (and expanded state) when older history
/// loads in or new changes join it.
List<TimelineRow> buildTimelineRows(
  List<ChatEntry> entries, {
  bool isDirect = false,
  Map<String, String>? groupIds,
}) {
  final registry = groupIds ?? <String, String>{};
  final rows = <TimelineRow>[];
  DateTime? currentDay;
  final dayEntries = <ChatEntry>[];

  void flushDay() {
    if (dayEntries.isEmpty) return;
    rows.add(DaySeparatorRow(currentDay!));
    _addDay(rows, List.of(dayEntries), isDirect, registry);
    dayEntries.clear();
  }

  for (final entry in entries) {
    final local = entry.time.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (currentDay != day) {
      flushDay();
      currentDay = day;
    }
    dayEntries.add(entry);
  }
  flushDay();
  return rows;
}

void _addDay(
  List<TimelineRow> rows,
  List<ChatEntry> entries,
  bool isDirect,
  Map<String, String> registry,
) {
  final groups = groupTimeline(entries);
  ChatEntry? previousMessage;

  bool continues(ChatEntry entry) {
    final previous = previousMessage;
    if (previous == null || previous.sender != entry.sender) return false;
    final gap = entry.time.difference(previous.time);
    return !gap.isNegative && gap <= senderGroupingWindow;
  }

  var index = 0;
  while (index < groups.length) {
    final group = groups[index];
    if (group.isGallery) {
      final first = group.entries.first;
      rows.add(
        GalleryRow(
          group.entries,
          showSender: !first.mine && !isDirect && !continues(first),
        ),
      );
      previousMessage = group.entries.last;
      index++;
      continue;
    }
    final entry = group.entries.single;
    final kind = entry.kind;
    if (kind == EntryKind.state || kind == EntryKind.redacted) {
      final run = <ChatEntry>[entry];
      while (index + run.length < groups.length) {
        final next = groups[index + run.length];
        if (next.isGallery || next.entries.single.kind != kind) break;
        run.add(next.entries.single);
      }
      final collapse = kind == EntryKind.state
          ? run.length >= 2
          : run.length >= minRemovedRun;
      if (collapse) {
        rows.add(
          CollapsedRow(
            resolveGroupId(registry, run),
            kind == EntryKind.state
                ? CollapsedKind.roomChanges
                : CollapsedKind.removedMessages,
            List.unmodifiable(run),
          ),
        );
        // State changes break sender groups; removed messages do too.
        previousMessage = null;
        index += run.length;
        continue;
      }
    }
    if (kind == EntryKind.state) {
      rows.add(EntryRow(entry, continuesGroup: false, showSender: false));
      previousMessage = null;
    } else {
      final grouped = continues(entry);
      rows.add(
        EntryRow(
          entry,
          continuesGroup: grouped,
          showSender: !entry.mine && !isDirect && !grouped,
        ),
      );
      previousMessage = entry;
    }
    index++;
  }
}

/// Element X's group-ID registry: reuse the ID of any member that already
/// started a group, otherwise register a new one for the first member.
@visibleForTesting
String resolveGroupId(Map<String, String> registry, List<ChatEntry> entries) {
  for (final entry in entries) {
    final existing = registry[entry.id];
    if (existing != null) return existing;
  }
  final id = '${entries.first.id}_group';
  registry[entries.first.id] = id;
  return id;
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Day separator label: "Today", "Yesterday", "Monday 3 November" within a
/// week, "3 November" this year, otherwise "3 November 2025".
String dayLabel(DateTime day, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final today = DateTime(current.year, current.month, current.day);
  final date = DateTime(day.year, day.month, day.day);
  final diff = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(date.year, date.month, date.day)).inDays;
  final dayMonth = '${date.day} ${_months[date.month - 1]}';
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return '${_weekdays[date.weekday - 1]} $dayMonth';
  if (date.year == today.year) return dayMonth;
  return '$dayMonth ${date.year}';
}
