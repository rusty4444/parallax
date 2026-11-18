// Hook implementations for the rich timeline feature module.
//
// Formatted text, mentions, links, state events and content actions.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../platform/matrix_link_opener.dart';
import 'mention_suggestions.dart';
import 'message_actions.dart';
import 'permalinks.dart';
import 'rich_text_view.dart';
import 'rich_timeline_features.dart';

/// Renders a message's text (plain or formatted) inside a bubble. Media
/// captions use it too, with [largeEmoji] off.
Widget buildMessageText(
  BuildContext context,
  EntryHookContext ctx, {
  required TextStyle style,
  bool largeEmoji = true,
}) {
  final features = richTimelineFeaturesOf(ctx.backend);
  return MessageContentView(
    backend: ctx.backend,
    entry: ctx.entry,
    style: style,
    largeEmoji: largeEmoji,
    palette: ctx.palette,
    ownUserId: ctx.backend.userId,
    resolveName: features == null
        ? null
        : (userId) => features.member(ctx.roomId, userId)?.displayName,
    onLink: (uri, text) {
      if (context.mounted) openTimelineLink(context, uri, text: text);
    },
    onPermalink: (link) {
      if (context.mounted) openMatrixPermalink(context, ctx, link);
    },
    onCopyTarget: (target) {
      if (context.mounted) showCopyTargetActions(context, target);
    },
  );
}

/// Navigation hook for Matrix permalinks (matrix.to / `matrix:`) tapped in the
/// timeline: user and room pills, and links to messages.
///
/// New extension point owned by this module. Default: open externally (the
/// browser or another Matrix app). The platform module can route these
/// in-app later by replacing this body.
Future<void> openMatrixPermalink(
  BuildContext context,
  EntryHookContext ctx,
  MatrixPermalink link,
) async {
  // Route in-app (rooms, users, event permalinks); fall back to the browser
  // for anything the platform module does not recognise.
  final handled = await openMatrixLink(
    context,
    ctx.backend,
    ctx.palette,
    link.uri,
  );
  if (!handled && context.mounted) await openTimelineLink(context, link.uri);
}

/// Mention suggestions for the composer of [ctx]'s room.
///
/// New extension point owned by this module. The composer already finds the
/// room via the timeline on the same route; pass this as
/// `RichMessageComposer(mentionSource: …)` to wire it explicitly.
MentionSource? richTimelineMentionSource(RoomHookContext ctx) =>
    roomMentionSource(
      backend: ctx.backend,
      roomId: ctx.roomId,
      palette: ctx.palette,
    );

/// Content actions such as copy text, copy link and view source.
List<MessageActionItem> richTimelineMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  if (entry.redacted || entry.kind == EntryKind.redacted) return const [];
  return [
    if (canCopyText(entry))
      MessageActionItem(
        id: 'rich-timeline-copy-text',
        icon: Icons.content_copy_rounded,
        label: 'Copy text',
        onSelected: (context) => copyToClipboard(
          context,
          copyableText(entry),
          confirmation: 'Message copied',
        ),
      ),
    if (hasServerEventId(entry))
      MessageActionItem(
        id: 'rich-timeline-copy-link',
        icon: Icons.link_rounded,
        label: 'Copy link to message',
        onSelected: (context) => copyToClipboard(
          context,
          eventPermalink(
            ctx.roomId,
            entry.id,
            via:
                richTimelineFeaturesOf(ctx.backend)?.viaServers(ctx.roomId) ??
                const [],
          ),
          confirmation: 'Link copied',
        ),
      ),
    MessageActionItem(
      id: 'rich-timeline-view-source',
      icon: Icons.code_rounded,
      label: 'View source',
      onSelected: (context) => showViewSource(
        context,
        entry: entry,
        roomId: ctx.roomId,
        encrypted: ctx.encrypted,
      ),
    ),
  ];
}
