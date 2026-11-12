import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../widgets.dart';
import 'poll_features.dart';
import 'poll_view.dart';

enum PollHistoryFilter { ongoing, past }

/// Element X "Polls" (poll history): polls in the room's loaded history,
/// filtered into Ongoing and Past, newest first, with "Load more" to page
/// further back through the room timeline.
class PollHistoryScreen extends StatefulWidget {
  const PollHistoryScreen({
    super.key,
    required this.backend,
    required this.features,
    required this.palette,
    required this.roomId,
  });

  final ChatBackend backend;
  final PollFeatures features;
  final AppPalette palette;
  final String roomId;

  @override
  State<PollHistoryScreen> createState() => _PollHistoryScreenState();
}

class _PollHistoryScreenState extends State<PollHistoryScreen> {
  PollHistoryFilter _filter = PollHistoryFilter.ongoing;
  bool _loadingMore = false;
  String? _error;

  bool get _active => widget.backend.activeRoomId == widget.roomId;

  List<ChatEntry> _polls() => _active
      ? [
          for (final entry in widget.backend.messages.reversed)
            if (entry.kind == EntryKind.poll && !entry.redacted) entry,
        ]
      : const [];

  Future<void> _loadMore() async {
    if (_loadingMore || !_active) return;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      await widget.backend.loadOlder(widget.roomId);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load older polls.');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.backend,
              widget.features.pollUpdates,
            ]),
            builder: (context, _) {
              final me = widget.backend.userId;
              final polls = _polls();
              final shown = <ChatEntry>[];
              for (final entry in polls) {
                widget.features.ensurePollLoaded(widget.roomId, entry.id);
                final results = pollResultsFor(
                  features: widget.features,
                  roomId: widget.roomId,
                  pollId: entry.id,
                  pollSender: entry.sender,
                  content: entry.content,
                  myUserId: me,
                );
                if (results == null) continue;
                if (results.ended == (_filter == PollHistoryFilter.past)) {
                  shown.add(entry);
                }
              }
              final canLoadMore =
                  _active &&
                  widget.backend.canLoadOlder &&
                  !widget.backend.loadingHistory;
              return Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(
                        child: Text(
                          'Polls',
                          style: TextStyle(
                            color: p.foreground,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: SegmentedButton<PollHistoryFilter>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: PollHistoryFilter.ongoing,
                          label: Text('Ongoing'),
                        ),
                        ButtonSegment(
                          value: PollHistoryFilter.past,
                          label: Text('Past'),
                        ),
                      ],
                      selected: {_filter},
                      onSelectionChanged: (value) =>
                          setState(() => _filter = value.first),
                    ),
                  ),
                  if (_loadingMore || widget.backend.loadingHistory)
                    const LinearProgressIndicator(),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (!_active)
                          _Message(
                            palette: p,
                            text: 'Open this room to browse its polls.',
                          )
                        else if (shown.isEmpty)
                          _Message(
                            palette: p,
                            text: _filter == PollHistoryFilter.ongoing
                                ? 'Can’t find any ongoing polls.'
                                : 'Can’t find any past polls.',
                          ),
                        for (final entry in shown)
                          _PollCard(
                            key: ValueKey(entry.id),
                            palette: p,
                            entry: entry,
                            child: PollBody(
                              features: widget.features,
                              palette: p,
                              roomId: widget.roomId,
                              pollId: entry.id,
                              pollSender: entry.sender,
                              content: entry.content,
                              myUserId: me,
                              foreground: p.foreground,
                            ),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: p.foreground),
                            ),
                          ),
                        if (canLoadMore)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Center(
                              child: OutlinedButton(
                                onPressed: _loadingMore
                                    ? null
                                    : () => unawaited(_loadMore()),
                                child: const Text('Load more'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.palette, required this.text});
  final AppPalette palette;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: palette.muted),
    ),
  );
}

class _PollCard extends StatelessWidget {
  const _PollCard({
    super.key,
    required this.palette,
    required this.entry,
    required this.child,
  });
  final AppPalette palette;
  final ChatEntry entry;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final date = MaterialLocalizations.of(
      context,
    ).formatMediumDate(entry.time.toLocal());
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Eyebrow('$date · ${entry.senderLabel}', palette: palette),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
