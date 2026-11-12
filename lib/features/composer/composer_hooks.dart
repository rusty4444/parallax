// Hook implementations for the composer (formatting toolbar and chat effects) feature module.
//
// Rich-text toolbar, /commands and full-screen chat effects.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
//
// The formatting toolbar, live markdown styling, `/` command and generic
// autocomplete and the send button's long-press options live in
// lib/rich_message_composer.dart (owned by this module).
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'chat_effects_overlay.dart';
import 'chat_effects_preferences.dart';
import 'slash_commands.dart';

/// Full-screen overlays above the room timeline (chat effects).
List<Widget> composerRoomOverlays(BuildContext context, RoomHookContext ctx) =>
    [
      ChatEffectsOverlay(
        key: ValueKey('chat-effects-${ctx.roomId}'),
        backend: ctx.backend,
        roomId: ctx.roomId,
      ),
    ];

/// Settings sections (for example "Show chat effects").
List<Widget> composerSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => [ChatEffectsSettingsSection(palette: ctx.palette)];

/// Outgoing text transform (for example `/confetti` → effect msgtype).
Map<String, Object?> composerTransformOutgoing(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) {
  try {
    return applySlashCommand(ctx, content);
  } catch (_) {
    // A command transform must never block an otherwise valid send.
    return content;
  }
}
