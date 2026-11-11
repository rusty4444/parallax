import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'create_poll_screen.dart';
import 'poll_features.dart';
import 'poll_model.dart';

/// A poll as rendered in the timeline and in poll history (Element X
/// `PollContentView`): question, answers with selection, live tallies for
/// disclosed polls (undisclosed ones after ending), winner highlight, total
/// votes, and Edit/End for the poll's creator.
class PollBody extends StatefulWidget {
  const PollBody({
    super.key,
    required this.features,
    required this.palette,
    required this.roomId,
    required this.pollId,
    required this.pollSender,
    required this.content,
    required this.myUserId,
    required this.foreground,
    this.highlightMine = false,
  });

  final PollFeatures features;
  final AppPalette palette;
  final String roomId;
  final String pollId;
  final String pollSender;
  final Map<String, Object?> content;
  final String? myUserId;

  /// Text colour for the surface the poll is drawn on.
  final Color foreground;

  /// Drawn inside the user's own (accent-coloured) bubble.
  final bool highlightMine;

  @override
  State<PollBody> createState() => _PollBodyState();
}

class _PollBodyState extends State<PollBody> {
  Set<String>? _pending;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.features.ensurePollLoaded(widget.roomId, widget.pollId);
  }

  @override
  void didUpdateWidget(PollBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pollId != widget.pollId ||
        oldWidget.roomId != widget.roomId ||
        !identical(oldWidget.features, widget.features)) {
      _pending = null;
      _sending = false;
      widget.features.ensurePollLoaded(widget.roomId, widget.pollId);
    }
  }

  bool get _remote => widget.pollId.startsWith(r'$');
  bool get _isCreator =>
      widget.myUserId != null && widget.myUserId == widget.pollSender;

  Future<void> _select(PollResults results, String answerId) async {
    if (results.ended || _sending || !_remote) return;
    final current = _pending ?? results.mySelection;
    final List<String> next;
    if (results.poll.maxSelections <= 1) {
      if (current.length == 1 && current.contains(answerId)) return;
      next = [answerId];
    } else {
      final toggled = {...current};
      if (!toggled.remove(answerId)) toggled.add(answerId);
      if (toggled.length > results.poll.maxSelections) return;
      next = [
        for (final answer in results.poll.answers)
          if (toggled.contains(answer.id)) answer.id,
      ];
    }
    final pollId = widget.pollId;
    setState(() {
      _pending = next.toSet();
      _sending = true;
    });
    try {
      await widget.features.respondToPoll(widget.roomId, pollId, next);
    } catch (_) {
      if (mounted && pollId == widget.pollId) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Couldn’t send your vote. Try again.')),
        );
      }
    } finally {
      if (mounted && pollId == widget.pollId) {
        setState(() {
          _sending = false;
          _pending = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.features.pollUpdates,
    builder: (context, _) {
      final results = pollResultsFor(
        features: widget.features,
        roomId: widget.roomId,
        pollId: widget.pollId,
        pollSender: widget.pollSender,
        content: widget.content,
        myUserId: widget.myUserId,
      );
      if (results == null) {
        return Text(
          'This poll can’t be displayed.',
          style: TextStyle(color: widget.foreground),
        );
      }
      final snapshot = widget.features.pollSnapshot(
        widget.roomId,
        widget.pollId,
      );
      return _buildPoll(context, results, snapshot?.state);
    },
  );

  Widget _buildPoll(
    BuildContext context,
    PollResults results,
    PollLoadState? state,
  ) {
    final p = widget.palette;
    final fg = widget.foreground;
    final muted = fg.withValues(alpha: 0.82);
    final poll = results.poll;
    final selection = _pending ?? results.mySelection;
    final showResults = results.showResults;
    final multiple = poll.maxSelections > 1;
    final canVote = !results.ended && _remote && !_sending;
    // Votes may exist until relations have loaded, so editing waits for them.
    final canEdit =
        _isCreator &&
        _remote &&
        state == PollLoadState.ready &&
        !results.ended &&
        !results.hasVotes;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Semantics(
        container: true,
        label: results.ended ? 'Ended poll' : 'Poll',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    results.ended
                        ? Icons.how_to_vote_rounded
                        : Icons.poll_outlined,
                    size: 20,
                    color: fg,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    poll.question,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 15.5,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (multiple && !results.ended) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(
                  'Choose up to ${poll.maxSelections} options',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 8),
            for (final answer in poll.answers)
              _AnswerRow(
                key: ValueKey(answer.id),
                palette: p,
                foreground: fg,
                highlightMine: widget.highlightMine,
                answer: answer,
                multiple: multiple,
                selected: selection.contains(answer.id),
                winner: results.winners.contains(answer.id),
                ended: results.ended,
                showResults: showResults,
                votes: results.votesFor(answer.id),
                fraction: results.fractionFor(answer.id),
                onTap: canVote ? () => _select(results, answer.id) : null,
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (_sending) ...[
                  SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: muted,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    _footer(results),
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                if (results.edited)
                  Text(
                    '(edited)',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
              ],
            ),
            if (state == PollLoadState.failed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => widget.features.ensurePollLoaded(
                    widget.roomId,
                    widget.pollId,
                    retry: true,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('Couldn’t load all votes. Retry'),
                ),
              ),
            if (_isCreator && _remote && !results.ended) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: fg,
                    side: BorderSide(color: fg.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: canEdit
                      ? () => openEditPoll(
                          context,
                          palette: p,
                          roomId: widget.roomId,
                          pollId: widget.pollId,
                          poll: poll,
                          features: widget.features,
                        )
                      : () => confirmAndEndPoll(
                          context,
                          features: widget.features,
                          roomId: widget.roomId,
                          pollId: widget.pollId,
                        ),
                  child: Text(canEdit ? 'Edit poll' : 'End poll'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _footer(PollResults results) {
    final votes = results.totalVotes == 1
        ? '1 vote'
        : '${results.totalVotes} votes';
    if (results.ended) return 'Final results based on $votes';
    if (results.poll.disclosed) return 'Total votes: ${results.totalVotes}';
    return 'Results will show after the poll has ended';
  }
}

class _AnswerRow extends StatelessWidget {
  const _AnswerRow({
    super.key,
    required this.palette,
    required this.foreground,
    required this.highlightMine,
    required this.answer,
    required this.multiple,
    required this.selected,
    required this.winner,
    required this.ended,
    required this.showResults,
    required this.votes,
    required this.fraction,
    required this.onTap,
  });

  final AppPalette palette;
  final Color foreground;
  final bool highlightMine;
  final PollAnswer answer;
  final bool multiple;
  final bool selected;
  final bool winner;
  final bool ended;
  final bool showResults;
  final int votes;
  final double fraction;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final fg = foreground;
    final IconData icon;
    if (ended && winner) {
      icon = Icons.emoji_events_rounded;
    } else if (multiple) {
      icon = selected
          ? Icons.check_box_rounded
          : Icons.check_box_outline_blank_rounded;
    } else {
      icon = selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded;
    }
    final iconColour = ended && winner
        ? p.secondary
        : selected
        ? (highlightMine ? fg : p.accent)
        : fg.withValues(alpha: 0.7);
    final fill = winner
        ? p.secondary
        : highlightMine
        ? fg
        : p.accent;
    final percent = (fraction * 100).round();
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: !multiple,
      checked: multiple ? selected : null,
      enabled: onTap != null,
      label: [
        answer.text,
        if (showResults) '$votes ${votes == 1 ? 'vote' : 'votes'}',
        if (showResults) '$percent percent of total votes',
        if (ended && winner) 'This is the winning answer',
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: iconColour),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      answer.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: ended && winner
                            ? FontWeight.w800
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (showResults) ...[
                    const SizedBox(width: 8),
                    Text(
                      votes == 1 ? '1 vote' : '$votes votes',
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.78),
                        fontSize: 12,
                        fontWeight: winner ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
              if (showResults) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: fraction.clamp(0, 1),
                      minHeight: 6,
                      color: fill,
                      backgroundColor: fg.withValues(alpha: 0.16),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks "Are you sure you want to end this poll?" then ends it.
Future<void> confirmAndEndPoll(
  BuildContext context, {
  required PollFeatures features,
  required String roomId,
  required String pollId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('End poll'),
      content: const Text('Are you sure you want to end this poll?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('End poll'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await features.endPoll(roomId, pollId);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Couldn’t end this poll. Try again.')),
    );
  }
}
