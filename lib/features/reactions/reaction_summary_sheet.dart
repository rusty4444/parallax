import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import 'message_action_features.dart';
import '../packs/pack_image.dart' show reactionKeyLabel;
import '../../room_avatar.dart';

/// Element X ReactionSummary: who reacted with each emoji.
Future<void> showReactionSummary(
  BuildContext context, {
  required ChatBackend backend,
  required MessageActionFeatures features,
  required String roomId,
  required ChatEntry entry,
  required AppPalette palette,
  String? initialEmoji,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: palette.surface,
  builder: (_) => ReactionSummarySheet(
    backend: backend,
    features: features,
    roomId: roomId,
    entry: entry,
    palette: palette,
    initialEmoji: initialEmoji,
  ),
);

class ReactionSummarySheet extends StatefulWidget {
  const ReactionSummarySheet({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.entry,
    required this.palette,
    this.initialEmoji,
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final String roomId;
  final ChatEntry entry;
  final AppPalette palette;
  final String? initialEmoji;

  @override
  State<ReactionSummarySheet> createState() => _ReactionSummarySheetState();
}

class _ReactionSummarySheetState extends State<ReactionSummarySheet> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  List<ReactionSender>? _senders;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected =
        widget.initialEmoji ?? widget.entry.reactions.firstOrNull?.emoji;
    _loading = true;
    _fetch(++_generation);
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  void _load() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _fetch(++_generation);
  }

  Future<void> _fetch(int generation) async {
    try {
      final senders = await widget.features.reactionSenders(
        widget.roomId,
        widget.entry.id,
      );
      if (!mounted || generation != _generation || !_owner.isCurrent) return;
      setState(() {
        _senders = senders;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation || !_owner.isCurrent) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Emoji tabs: local counts first (as shown on the message), then any extra
  /// keys only the server knows about.
  List<({String emoji, int count, bool mine})> _tabs() {
    final senders = _senders;
    final ownId = widget.backend.userId;
    final tabs = <String, ({String emoji, int count, bool mine})>{
      for (final r in widget.entry.reactions)
        r.emoji: (emoji: r.emoji, count: r.count, mine: r.mine),
    };
    if (senders != null) {
      final byEmoji = <String, List<ReactionSender>>{};
      for (final s in senders) {
        byEmoji.putIfAbsent(s.emoji, () => []).add(s);
      }
      for (final e in byEmoji.entries) {
        tabs[e.key] = (
          emoji: e.key,
          count: e.value.length,
          mine: e.value.any((s) => s.userId == ownId),
        );
      }
    }
    return tabs.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final tabs = _tabs();
    final selected = tabs.any((t) => t.emoji == _selected)
        ? _selected
        : tabs.firstOrNull?.emoji;
    final senders = (_senders ?? const <ReactionSender>[])
        .where((s) => s.emoji == selected)
        .toList();
    final expired = !_owner.isCurrent;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Eyebrow('Reactions', palette: p),
            ),
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final tab in tabs)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('reaction-tab-${tab.emoji}'),
                        selected: tab.emoji == selected,
                        showCheckmark: false,
                        onSelected: (_) =>
                            setState(() => _selected = tab.emoji),
                        side: BorderSide(
                          color: tab.mine
                              ? p.accent
                              : p.stroke.withValues(alpha: 0.8),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        label: Text(
                          // Custom (MSC4027) reactions show their shortcode.
                          '${reactionKeyLabel(widget.backend, widget.roomId, tab.emoji)}  ${tab.count}',
                          style: TextStyle(
                            color: p.foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: expired
                  ? _message(p, 'Account changed. Reopen this message.')
                  : _loading && _senders == null
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: Center(
                        child: CircularProgressIndicator(color: p.accent),
                      ),
                    )
                  : _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _message(
                          p,
                          'Couldn’t load who reacted. The counts above are '
                          'from this device.',
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    )
                  : senders.isEmpty
                  ? _message(p, 'No details for this reaction yet.')
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      itemCount: senders.length,
                      itemBuilder: (context, index) {
                        final sender = senders[index];
                        final time = sender.time;
                        return ListTile(
                          key: ValueKey('reaction-sender-${sender.userId}'),
                          leading: UserAvatar(
                            name: sender.label,
                            url: sender.avatarUrl,
                            backend: widget.backend,
                            palette: p,
                            size: 40,
                          ),
                          title: Text(
                            sender.userId == widget.backend.userId
                                ? '${sender.label} (you)'
                                : sender.label,
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            sender.userId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                          trailing: time == null
                              ? null
                              : Text(
                                  MaterialLocalizations.of(
                                    context,
                                  ).formatTimeOfDay(
                                    TimeOfDay.fromDateTime(time.toLocal()),
                                  ),
                                  style: TextStyle(
                                    color: p.muted,
                                    fontSize: 12,
                                  ),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _message(AppPalette p, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
    child: Text(text, style: TextStyle(color: p.muted)),
  );
}
