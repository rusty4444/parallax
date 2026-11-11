import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import 'rich_timeline_features.dart';
import 'state_event_text.dart';
import 'timeline_rows.dart';

/// Element X shows at most this many read-receipt avatars per event.
const maxReceiptAvatars = 3;

/// "Today" / "Yesterday" / date between days.
class DaySeparator extends StatelessWidget {
  const DaySeparator({
    super.key,
    required this.day,
    required this.palette,
    this.now,
  });
  final DateTime day;
  final AppPalette palette;
  final DateTime? now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Expanded(child: Divider(color: palette.stroke)),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: palette.stroke),
          ),
          child: Text(
            dayLabel(day, now: now),
            style: TextStyle(
              color: palette.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(child: Divider(color: palette.stroke)),
      ],
    ),
  );
}

/// A readable room state change (membership, name, topic …), upgraded to
/// Element X wording once its previous state is known.
class StateChangeLine extends StatefulWidget {
  const StateChangeLine({
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
  State<StateChangeLine> createState() => _StateChangeLineState();
}

class _StateChangeLineState extends State<StateChangeLine> {
  int _generation = 0;
  PreviousState? _previous;

  RichTimelineFeatures? get _features {
    final backend = widget.backend;
    return backend == null ? null : richTimelineFeaturesOf(backend);
  }

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(StateChangeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id ||
        oldWidget.backend != widget.backend ||
        oldWidget.roomId != widget.roomId) {
      _previous = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  void _resolve() {
    final generation = ++_generation;
    final features = _features;
    final roomId = widget.roomId;
    if (features == null ||
        roomId == null ||
        !stateEventNeedsPrevious(widget.entry)) {
      return;
    }
    final cached = features.cachedPreviousState(roomId, widget.entry.id);
    if (cached != null) {
      _previous = cached;
      return;
    }
    unawaited(
      features.previousState(roomId, widget.entry.id).then((previous) {
        if (!mounted || generation != _generation || previous == null) return;
        setState(() => _previous = previous);
      }, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final features = _features;
    final roomId = widget.roomId;
    final text =
        describeStateEvent(
          widget.entry,
          ownUserId: widget.backend?.userId,
          previous: _previous,
          nameOf: features == null || roomId == null
              ? null
              : (userId) => features.member(roomId, userId)?.displayName,
        ) ??
        widget.entry.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: widget.palette.muted, fontSize: 12),
        ),
      ),
    );
  }
}

/// "3 room changes" / "4 removed messages", expandable like Element X.
class CollapsedRowHeader extends StatelessWidget {
  const CollapsedRowHeader({
    super.key,
    required this.row,
    required this.expanded,
    required this.palette,
    required this.onToggle,
  });
  final CollapsedRow row;
  final bool expanded;
  final AppPalette palette;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      button: true,
      expanded: expanded,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                row.label,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
                color: palette.muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Small avatars of users whose latest receipt is on this event, aligned to
/// the end of the row as in Element X. Tapping opens the receipts sheet.
class ReadReceiptsRow extends StatelessWidget {
  const ReadReceiptsRow({
    super.key,
    required this.readers,
    required this.backend,
    required this.palette,
    required this.onTap,
    this.sent = false,
  });
  final List<ReceiptReader> readers;
  final ChatBackend backend;
  final AppPalette palette;
  final VoidCallback onTap;

  /// Show Element X's "Sent" tick (own latest message, no receipts yet).
  final bool sent;

  String get _description {
    final names = readers.map((reader) => reader.name).toList();
    if (names.length == 1) return 'Read by ${names.first}';
    if (names.length == 2) return 'Read by ${names[0]} and ${names[1]}';
    final others = names.length - 2;
    return 'Read by ${names[0]}, ${names[1]} and $others '
        '${others == 1 ? 'other' : 'others'}';
  }

  @override
  Widget build(BuildContext context) {
    if (readers.isEmpty) {
      if (!sent) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 3, right: 4),
        child: Align(
          alignment: Alignment.centerRight,
          child: Icon(
            Icons.check_circle_outline_rounded,
            size: 14,
            color: palette.muted,
            semanticLabel: 'Sent',
          ),
        ),
      );
    }
    const size = 18.0;
    const step = 12.0;
    final shown = readers.take(maxReceiptAvatars).toList();
    final extra = readers.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          button: true,
          label: _description,
          hint: 'Show all read receipts',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (extra > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        '+$extra',
                        style: TextStyle(color: palette.muted, fontSize: 11),
                      ),
                    ),
                  SizedBox(
                    width: size + step * (shown.length - 1) + 2,
                    height: size + 2,
                    child: Stack(
                      children: [
                        for (var i = shown.length - 1; i >= 0; i--)
                          Positioned(
                            right: step * i,
                            child: Container(
                              padding: const EdgeInsets.all(1),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: palette.background,
                              ),
                              child: UserAvatar(
                                key: ValueKey(shown[i].userId),
                                name: shown[i].name,
                                url: shown[i].avatar,
                                backend: backend,
                                palette: palette,
                                size: size,
                              ),
                            ),
                          ),
                      ],
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
}

/// Element X's jump-to-bottom button, with a count of newer messages.
class JumpToBottomButton extends StatelessWidget {
  const JumpToBottomButton({
    super.key,
    required this.palette,
    required this.onPressed,
    this.newMessages = 0,
  });
  final AppPalette palette;
  final VoidCallback onPressed;
  final int newMessages;

  @override
  Widget build(BuildContext context) => Badge(
    isLabelVisible: newMessages > 0,
    label: Text(newMessages > 99 ? '99+' : '$newMessages'),
    backgroundColor: palette.accent,
    textColor: palette.accentOn,
    child: FloatingActionButton.small(
      heroTag: null,
      tooltip: 'Jump to latest messages',
      backgroundColor: palette.surface,
      foregroundColor: palette.foreground,
      shape: CircleBorder(side: BorderSide(color: palette.stroke)),
      onPressed: onPressed,
      child: const Icon(Icons.keyboard_double_arrow_down_rounded),
    ),
  );
}
