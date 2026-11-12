import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../chat_backend.dart';
import '../features/rich_timeline/mention_suggestions.dart';
import '../features/rich_timeline/message_actions.dart';
import '../features/rich_timeline/rich_timeline_features.dart';
import '../features/rich_timeline/timeline_rows.dart';
import '../features/rich_timeline/timeline_widgets.dart';
import '../gallery_bubble.dart';
import '../message_receipts_sheet.dart';
import 'message_bubble.dart';

/// Distance from the newest message before the jump-to-bottom button shows.
const jumpToBottomThreshold = 320.0;

/// The scrolling room timeline (newest at the bottom), with day separators,
/// Element X-style sender grouping, collapsible room changes, read receipts
/// and a jump-to-bottom button.
class TimelineView extends StatefulWidget {
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
  State<TimelineView> createState() => _TimelineViewState();
}

/// A flattened list item: a row, or one member of an expanded group.
class _Item {
  const _Item.row(this.row) : child = null;
  const _Item.child(this.row, ChatEntry this.child);
  final TimelineRow row;
  final ChatEntry? child;

  String get key => child == null ? row.key : 'child-${child!.id}';
}

class _TimelineViewState extends State<TimelineView> {
  final _scroll = ScrollController();
  final _groupIds = <String, String>{};
  final _expanded = <String>{};
  bool _away = false;

  /// Newest entry when the user scrolled away from the bottom.
  String? _awayNewestId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId ||
        oldWidget.backend != widget.backend) {
      _groupIds.clear();
      _expanded.clear();
      _away = false;
      _awayNewestId = null;
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > jumpToBottomThreshold;
    if (away == _away) return;
    setState(() {
      _away = away;
      _awayNewestId = away ? widget.entries.lastOrNull?.id : null;
    });
  }

  int get _newSinceAway {
    final anchor = _awayNewestId;
    if (!_away || anchor == null) return 0;
    final index = widget.entries.lastIndexWhere((entry) => entry.id == anchor);
    if (index < 0) return 0;
    return widget.entries
        .skip(index + 1)
        .where((entry) => !entry.mine && entry.kind != EntryKind.state)
        .length;
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _openReceipts(String eventId) => showMessageReceipts(
    context,
    backend: widget.backend,
    roomId: widget.roomId,
    eventId: eventId,
  );

  List<_Item> _items(List<TimelineRow> rows) {
    final items = <_Item>[];
    for (final row in rows) {
      items.add(_Item.row(row));
      if (row is CollapsedRow && _expanded.contains(row.groupId)) {
        for (final entry in row.entries) {
          items.add(_Item.child(row, entry));
        }
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final palette = widget.palette;
    final entries = widget.entries;
    bindTimelineRoute(
      context,
      backend: backend,
      roomId: widget.roomId,
      palette: palette,
    );
    final features = richTimelineFeaturesOf(backend);
    final receipts =
        features?.latestReceipts(
          widget.roomId,
          eventIds: {for (final entry in entries) entry.id},
        ) ??
        const {};
    final isDirect = widget.room?.isDirect ?? false;
    final rows = buildTimelineRows(
      entries,
      isDirect: isDirect,
      groupIds: _groupIds,
    );
    final items = _items(rows);
    final lastOwn = entries
        .where(
          (entry) =>
              entry.mine &&
              entry.kind != EntryKind.state &&
              !entry.redacted &&
              hasServerEventId(entry),
        )
        .lastOrNull;

    List<ReceiptReader> readersFor(Iterable<ChatEntry> group) {
      final seen = <String>{};
      return [
        for (final entry in group)
          for (final reader in receipts[entry.id] ?? const <ReceiptReader>[])
            if (seen.add(reader.userId)) reader,
      ];
    }

    Widget receiptRow(Iterable<ChatEntry> group) {
      final readers = readersFor(group);
      if (readers.isEmpty) return const SizedBox.shrink();
      return ReadReceiptsRow(
        readers: readers,
        backend: backend,
        palette: palette,
        onTap: () => _openReceipts(
          group
              .lastWhere(
                (entry) => receipts[entry.id]?.isNotEmpty ?? false,
                orElse: () => group.last,
              )
              .id,
        ),
      );
    }

    Widget bubble(
      ChatEntry entry, {
      required bool group,
      required bool showSender,
    }) => MessageBubble(
      key: ValueKey(entry.id),
      entry: entry,
      backend: backend,
      roomId: widget.roomId,
      palette: palette,
      group: group,
      showSender: showSender,
      showAvatars: !isDirect,
      room: widget.room,
      entries: entries,
      receipts: receipts[entry.id] ?? const [],
      sent: entry.id == lastOwn?.id && (receipts[entry.id]?.isEmpty ?? true),
      onReceipts: () => _openReceipts(entry.id),
      onHeart: () => widget.onHeart(entry),
      onAction: () => widget.onAction(entry),
      onReaction: (emoji) => widget.onReaction(entry, emoji),
      replyPreview: entry.replyToId == null
          ? null
          : entries.where((item) => item.id == entry.replyToId).firstOrNull,
    );

    Widget buildItem(_Item item) {
      final row = item.row;
      final child = item.child;
      if (child != null) {
        if (child.kind == EntryKind.state) {
          return Column(
            key: ValueKey(item.key),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StateEventLine(
                entry: child,
                palette: palette,
                backend: backend,
                roomId: widget.roomId,
              ),
              receiptRow([child]),
            ],
          );
        }
        return bubble(child, group: true, showSender: false);
      }
      return switch (row) {
        DaySeparatorRow(:final day) => DaySeparator(
          key: ValueKey(row.key),
          day: day,
          palette: palette,
        ),
        GalleryRow(:final entries) => Column(
          key: ValueKey(row.key),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GalleryBubble(
              entries: entries,
              backend: backend,
              roomId: widget.roomId,
              palette: palette,
              onHeart: widget.onHeart,
              onAction: widget.onAction,
              onReaction: widget.onReaction,
            ),
            receiptRow(entries),
          ],
        ),
        CollapsedRow() => Column(
          key: ValueKey(row.key),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CollapsedRowHeader(
              row: row,
              expanded: _expanded.contains(row.groupId),
              palette: palette,
              onToggle: () => setState(() {
                if (!_expanded.remove(row.groupId)) {
                  _expanded.add(row.groupId);
                }
              }),
            ),
            if (!_expanded.contains(row.groupId)) receiptRow(row.entries),
          ],
        ),
        EntryRow(:final entry) when entry.kind == EntryKind.state => Column(
          key: ValueKey(row.key),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StateEventLine(
              entry: entry,
              palette: palette,
              backend: backend,
              roomId: widget.roomId,
            ),
            receiptRow([entry]),
          ],
        ),
        EntryRow(:final entry, :final continuesGroup, :final showSender) =>
          bubble(entry, group: continuesGroup, showSender: showSender),
      };
    }

    final list = ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: EdgeInsets.fromLTRB(
        16,
        widget.compact ? 8 : 20,
        16,
        widget.compact ? 8 : 18,
      ),
      itemCount: items.length + (backend.canLoadOlder ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return Center(
            child: TextButton(
              onPressed: backend.loadingHistory ? null : widget.onLoadOlder,
              child: Text(
                backend.loadingHistory ? 'Loading…' : 'Load earlier messages',
              ),
            ),
          );
        }
        return buildItem(items[items.length - index - 1]);
      },
    );
    return Stack(
      children: [
        Positioned.fill(child: list),
        if (_away)
          Positioned(
            right: 14,
            bottom: 14,
            child: JumpToBottomButton(
              palette: palette,
              newMessages: _newSinceAway,
              onPressed: _jumpToBottom,
            ),
          ),
      ],
    );
  }
}
