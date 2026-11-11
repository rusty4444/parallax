// Hook implementations for the polls and location feature module.
//
// Poll creation/voting/results and static location sharing.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'create_poll_screen.dart';
import 'location_model.dart';
import 'location_view.dart';
import 'poll_features.dart';
import 'poll_history_screen.dart';
import 'poll_model.dart';
import 'poll_view.dart';
import 'share_location_screen.dart';

Widget? pollEntryBody(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  if (entry.kind != EntryKind.poll || entry.redacted) return null;
  final features = pollFeaturesOf(ctx.backend);
  if (features == null || PollStart.fromContent(entry.content) == null) {
    return null;
  }
  return PollBody(
    key: ValueKey('poll-${entry.id}'),
    features: features,
    palette: ctx.palette,
    roomId: ctx.roomId,
    pollId: entry.id,
    pollSender: entry.sender,
    content: entry.content,
    myUserId: ctx.backend.userId,
    foreground: ctx.onBubble,
    highlightMine: ctx.mine,
  );
}

Widget? locationEntryBody(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  if (entry.kind != EntryKind.location || entry.redacted) return null;
  final location = SharedLocation.fromContent(entry.content);
  if (location == null) return null;
  return LocationBody(
    key: ValueKey('location-${entry.id}'),
    palette: ctx.palette,
    location: location,
    foreground: ctx.onBubble,
    senderName: entry.senderLabel,
    sentAt: entry.time,
  );
}

List<ComposerAttachmentAction> pollComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) {
  final polls = pollFeaturesOf(ctx.backend);
  final location = locationFeaturesOf(ctx.backend);
  return [
    if (polls != null)
      ComposerAttachmentAction(
        id: 'poll',
        icon: Icons.poll_outlined,
        label: 'Poll',
        onSelected: (context) => openCreatePoll(
          context,
          palette: ctx.palette,
          roomId: ctx.roomId,
          features: polls,
        ),
      ),
    if (location != null)
      ComposerAttachmentAction(
        id: 'location',
        icon: Icons.location_on_outlined,
        label: 'Share location',
        onSelected: (context) => openShareLocation(
          context,
          palette: ctx.palette,
          roomId: ctx.roomId,
          features: location,
        ),
      ),
  ];
}

List<MessageActionItem> pollMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  if (entry.kind != EntryKind.poll ||
      entry.redacted ||
      !entry.id.startsWith(r'$')) {
    return const [];
  }
  final features = pollFeaturesOf(ctx.backend);
  final me = ctx.backend.userId;
  if (features == null || me == null) return const [];
  final results = pollResultsFor(
    features: features,
    roomId: ctx.roomId,
    pollId: entry.id,
    pollSender: entry.sender,
    content: entry.content,
    myUserId: me,
  );
  if (results == null || results.ended) return const [];
  final creator = entry.sender == me;
  final loaded =
      features.pollSnapshot(ctx.roomId, entry.id)?.state == PollLoadState.ready;
  return [
    // Element X: "Edit poll" only for the creator before anyone has voted.
    if (creator && loaded && !results.hasVotes)
      MessageActionItem(
        id: 'poll-edit',
        icon: Icons.edit_outlined,
        label: 'Edit poll',
        onSelected: (context) => openEditPoll(
          context,
          palette: ctx.palette,
          roomId: ctx.roomId,
          pollId: entry.id,
          poll: results.poll,
          features: features,
        ),
      ),
    if (features.mayEndPoll(ctx.roomId, me, entry.sender))
      MessageActionItem(
        id: 'poll-end',
        icon: Icons.how_to_vote_outlined,
        label: 'End poll',
        onSelected: (context) => confirmAndEndPoll(
          context,
          features: features,
          roomId: ctx.roomId,
          pollId: entry.id,
        ),
      ),
  ];
}

List<Widget> pollRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = pollFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    ListTile(
      key: const ValueKey('poll-history-tile'),
      leading: const Icon(Icons.poll_outlined),
      title: const Text('Polls'),
      subtitle: const Text('Ongoing and past polls in this room'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PollHistoryScreen(
            backend: ctx.backend,
            features: features,
            palette: ctx.palette,
            roomId: ctx.roomId,
          ),
        ),
      ),
    ),
  ];
}
