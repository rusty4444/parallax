// Hook implementations for the reactions and message actions feature module.
//
// Emoji picker, reactions, forwarding, pinning and reporting.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'emoji_picker_sheet.dart';
import 'forward_content.dart';
import 'forward_screen.dart';
import 'message_action_features.dart';
import 'pinned_messages.dart';
import 'reaction_summary_sheet.dart';
import 'remove_message_dialog.dart';
import 'report_content_screen.dart';

/// Full emoji picker. Returns null when cancelled. Core falls back to its
/// short built-in list only when this returns null *and* [available] is false.
const bool emojiPickerAvailable = true;

Future<String?> pickEmoji(
  BuildContext context, {
  AppPalette? palette,
  bool forReaction = false,
}) => showEmojiPickerSheet(
  context,
  palette: palette ?? paletteFromTheme(Theme.of(context)),
  forReaction: forReaction,
);

/// Whether reactions may be sent in this room from the UI.
///
/// Encrypted rooms are allowed, as in Element X: MatrixBackend.react sends
/// them through the trust and encryption guards as `m.room.encrypted`, with
/// the relation (target and emoji) in the cleartext envelope per the spec.
/// Only power levels that deny `m.reaction` hide them; when permissions are
/// unknown (for example offline) the backend reports the failure instead.
bool reactionsAllowed(RoomHookContext ctx) {
  final permissions = messageActionFeaturesOf(
    ctx.backend,
  )?.permissions(ctx.roomId);
  return permissions == null || !permissions.known || permissions.canReact;
}

/// New extension point (not yet wired): Element X opens the reaction summary
/// on a long-press of a reaction chip. The timeline owner can call this from
/// the chip's `onLongPress`, passing the pressed [emoji] to preselect its tab.
/// Does nothing when the backend has no message-action support.
Future<void> showReactionSummaryForEntry(
  BuildContext context,
  EntryHookContext ctx, {
  String? emoji,
}) async {
  final features = messageActionFeaturesOf(ctx.backend);
  if (features == null || ctx.entry.reactions.isEmpty) return;
  await showReactionSummary(
    context,
    backend: ctx.backend,
    features: features,
    roomId: ctx.roomId,
    entry: ctx.entry,
    palette: ctx.palette,
    initialEmoji: emoji,
  );
}

List<MessageActionItem> reactionMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final features = messageActionFeaturesOf(ctx.backend);
  final entry = ctx.entry;
  if (features == null || entry.redacted || entry.kind == EntryKind.state) {
    return const [];
  }
  final remote = entry.id.startsWith(r'$');
  final permissions = features.permissions(ctx.roomId);
  final pinned =
      entry.pinned || features.pinnedEventIds(ctx.roomId).contains(entry.id);
  return [
    if (entry.reactions.isNotEmpty)
      MessageActionItem(
        id: 'reactions.summary',
        icon: Icons.emoji_emotions_outlined,
        label: 'Reactions',
        onSelected: (context) => showReactionSummary(
          context,
          backend: ctx.backend,
          features: features,
          roomId: ctx.roomId,
          entry: entry,
          palette: ctx.palette,
        ),
      ),
    if (canForward(entry))
      MessageActionItem(
        id: 'reactions.forward',
        icon: Icons.forward_rounded,
        label: 'Forward',
        onSelected: (context) => openForwardScreen(
          context,
          backend: ctx.backend,
          features: features,
          palette: ctx.palette,
          entry: entry,
          candidates: ctx.entries,
        ),
      ),
    if (remote && permissions.canPin && entry.kind != EntryKind.call)
      MessageActionItem(
        id: pinned ? 'reactions.unpin' : 'reactions.pin',
        icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
        label: pinned ? 'Unpin' : 'Pin',
        onSelected: (context) => setMessagePinned(
          context,
          features: features,
          roomId: ctx.roomId,
          eventId: entry.id,
          pinned: !pinned,
        ),
      ),
    if (remote && !entry.mine)
      MessageActionItem(
        id: 'reactions.report',
        icon: Icons.flag_outlined,
        label: 'Report content',
        destructive: true,
        onSelected: (context) => _report(context, ctx, features),
      ),
    if (remote && !entry.mine && permissions.canRedactOthers)
      MessageActionItem(
        id: 'reactions.remove',
        icon: Icons.delete_sweep_outlined,
        label: 'Remove',
        destructive: true,
        onSelected: (context) => _remove(context, ctx, features),
      ),
  ];
}

Future<void> _report(
  BuildContext context,
  EntryHookContext ctx,
  MessageActionFeatures features,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await Navigator.of(context).push<ReportOutcome>(
    MaterialPageRoute(
      builder: (_) => ReportContentScreen(
        backend: ctx.backend,
        features: features,
        roomId: ctx.roomId,
        entry: ctx.entry,
        palette: ctx.palette,
      ),
    ),
  );
  if (outcome == null) return;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(switch (outcome) {
          ReportOutcome.reported => 'Report submitted',
          ReportOutcome.reportedAndBlocked => 'Report submitted. User blocked.',
          ReportOutcome.reportedBlockFailed =>
            'Report submitted, but couldn’t block this user.',
        }),
      ),
    );
}

Future<void> _remove(
  BuildContext context,
  EntryHookContext ctx,
  MessageActionFeatures features,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final reason = await confirmMessageRemoval(context, palette: ctx.palette);
  if (reason == null) return;
  try {
    await features.removeEvent(
      ctx.roomId,
      ctx.entry.id,
      reason: reason.isEmpty ? null : reason,
    );
  } catch (_) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Couldn’t remove this message.')),
      );
  }
}

/// Banners under the room header (for example pinned messages).
List<Widget> reactionRoomBanners(BuildContext context, RoomHookContext ctx) {
  final features = messageActionFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    PinnedMessagesBanner(
      key: ValueKey('pinned-banner-${ctx.roomId}'),
      backend: ctx.backend,
      features: features,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}

List<Widget> reactionRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = messageActionFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    PinnedMessagesDetailsTile(
      backend: ctx.backend,
      features: features,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}
