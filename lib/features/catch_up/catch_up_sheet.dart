import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'catch_up.dart';

/// Shows an on-device catch-up summary as a scrollable sheet.
Future<void> showCatchUpSheet(
  BuildContext context, {
  required CatchUpSummary summary,
  required String roomName,
  required AppPalette palette,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.background,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, scrollController) => CatchUpSheet(
        summary: summary,
        roomName: roomName,
        palette: palette,
        scrollController: scrollController,
      ),
    ),
  );
}

class CatchUpSheet extends StatelessWidget {
  const CatchUpSheet({
    super.key,
    required this.summary,
    required this.roomName,
    required this.palette,
    this.scrollController,
  });

  final CatchUpSummary summary;
  final String roomName;
  final AppPalette palette;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final s = summary;
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: p.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Catch up · $roomName',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Summarised on your device. Nothing was sent to a server.',
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Text(
          '${s.messageCount} unread messages from ${s.senderCount} '
          '${s.senderCount == 1 ? 'person' : 'people'}.',
          style: TextStyle(color: p.foreground, fontWeight: FontWeight.w600),
        ),
        if (s.topSenders.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Most active: ${s.topSenders.map((e) => '${e.$1} (${e.$2})').join(', ')}',
            style: TextStyle(color: p.muted, fontSize: 13),
          ),
        ],
        if (s.mediaCount > 0 || s.linkCount > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${s.mediaCount} media · ${s.linkCount} links shared',
            style: TextStyle(color: p.muted, fontSize: 13),
          ),
        ],
        _section(p, 'Mentioned you', Icons.alternate_email_rounded, s.mentions),
        _section(p, 'Questions', Icons.help_outline_rounded, s.questions),
        _section(p, 'Active threads', Icons.forum_outlined, s.threads),
        _section(p, 'Polls', Icons.poll_outlined, s.polls),
        if (s.mentions.isEmpty &&
            s.questions.isEmpty &&
            s.threads.isEmpty &&
            s.polls.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'No mentions, questions or polls — just conversation.',
              style: TextStyle(color: p.muted),
            ),
          ),
      ],
    );
  }

  Widget _section(
    AppPalette p,
    String title,
    IconData icon,
    List<CatchUpItem> items,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: p.secondary),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  color: p.foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(color: p.foreground, fontSize: 13.5),
                  children: [
                    TextSpan(
                      text: '${item.sender}: ',
                      style: TextStyle(
                        color: p.secondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(text: item.text),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
