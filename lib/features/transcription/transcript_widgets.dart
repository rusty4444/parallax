import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'transcripts.dart';

/// Whether [entry] is a voice or audio message that can be transcribed.
bool transcribable(ChatEntry entry) =>
    (entry.kind == EntryKind.voice || entry.kind == EntryKind.audio) &&
    !entry.redacted &&
    entry.id.startsWith(r'$');

/// The small "Transcribe" button beside a voice or audio message's player.
/// Hidden where this device cannot transcribe, and once a transcript shows.
class TranscribeButton extends StatelessWidget {
  const TranscribeButton({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) {
    final transcripts = Transcripts.instance;
    return ListenableBuilder(
      listenable: transcripts,
      builder: (context, _) {
        final entry = ctx.entry;
        if (!transcribable(entry) || !transcripts.available) {
          return const SizedBox.shrink();
        }
        final state = transcripts.stateFor(ctx.backend, entry.id);
        final colour = ctx.onBubble;
        return switch (state.status) {
          TranscriptStatus.done => const SizedBox.shrink(),
          TranscriptStatus.working => SizedBox(
            key: ValueKey('transcribing-${entry.id}'),
            width: 30,
            height: 30,
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: CircularProgressIndicator(strokeWidth: 2, color: colour),
            ),
          ),
          _ => SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              key: ValueKey('transcribe-${entry.id}'),
              tooltip: 'Transcribe',
              padding: EdgeInsets.zero,
              iconSize: 19,
              color: colour,
              onPressed: () => transcripts.transcribe(
                backend: ctx.backend,
                roomId: ctx.roomId,
                eventId: entry.id,
              ),
              icon: const Icon(Icons.subtitles_outlined),
            ),
          ),
        };
      },
    );
  }
}

/// The transcript (or its progress / error) under the player, inside the
/// message's bubble.
class TranscriptFooter extends StatelessWidget {
  const TranscriptFooter({super.key, required this.ctx});
  final EntryHookContext ctx;

  @override
  Widget build(BuildContext context) {
    final transcripts = Transcripts.instance;
    return ListenableBuilder(
      listenable: transcripts,
      builder: (context, _) {
        final state = transcripts.stateFor(ctx.backend, ctx.entry.id);
        final colour = ctx.onBubble;
        final muted = colour.withValues(alpha: 0.75);
        final Widget child = switch (state.status) {
          TranscriptStatus.none => const SizedBox.shrink(),
          TranscriptStatus.working => Text(
            'Transcribing…',
            style: TextStyle(
              color: muted,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          ),
          TranscriptStatus.failed => Text(
            state.error ?? 'Couldn’t transcribe this message.',
            style: TextStyle(color: muted, fontSize: 13),
          ),
          TranscriptStatus.done => Semantics(
            label: 'Transcript: ${state.text}',
            excludeSemantics: true,
            child: Text(
              state.text ?? '',
              key: ValueKey('transcript-${ctx.entry.id}'),
              style: TextStyle(color: colour, fontSize: 14, height: 1.35),
            ),
          ),
        };
        if (state.status == TranscriptStatus.none) return child;
        return Padding(padding: const EdgeInsets.only(top: 6), child: child);
      },
    );
  }
}
