// Hook implementations for the rich timeline feature module.
//
// Formatted text, mentions, links, state events and content actions.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Renders a message's text (plain or formatted) inside a bubble.
Widget buildMessageText(
  BuildContext context,
  EntryHookContext ctx, {
  required TextStyle style,
}) => Text(
  ctx.entry.edited ? '${ctx.entry.body} (edited)' : ctx.entry.body,
  style: style,
);

/// Content actions such as copy text, copy link and view source.
List<MessageActionItem> richTimelineMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];
