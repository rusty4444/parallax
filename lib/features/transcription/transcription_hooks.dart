// Hook implementations for the on-device voice transcription module.
//
// A voice or audio message gets a small Transcribe button beside its player
// (TranscribeButton, placed by the media bodies). The transcript then shows
// under the player in the same bubble and is saved on this device, so it is
// still there next time the chat opens. The long-press "Transcribe" action
// does the same.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'transcript_widgets.dart';
import 'transcripts.dart';

/// Long-press message action: "Transcribe" on voice/audio messages.
List<MessageActionItem> transcriptionMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final transcripts = Transcripts.instance;
  final entry = ctx.entry;
  if (!transcribable(entry) || !transcripts.available) return const [];
  final status = transcripts.stateFor(ctx.backend, entry.id).status;
  if (status == TranscriptStatus.done || status == TranscriptStatus.working) {
    return const [];
  }
  return [
    MessageActionItem(
      id: 'transcription.transcribe',
      icon: Icons.subtitles_outlined,
      label: 'Transcribe',
      onSelected: (context) => transcripts.transcribe(
        backend: ctx.backend,
        roomId: ctx.roomId,
        eventId: entry.id,
      ),
    ),
  ];
}

/// The transcript under a voice or audio message's player.
Widget? transcriptionEntryFooter(BuildContext context, EntryHookContext ctx) =>
    transcribable(ctx.entry) ? TranscriptFooter(ctx: ctx) : null;
