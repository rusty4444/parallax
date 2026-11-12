// Hook implementations for the composer (formatting toolbar and chat effects) feature module.
//
// Rich-text toolbar, /commands and full-screen chat effects.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Full-screen overlays above the room timeline (chat effects).
List<Widget> composerRoomOverlays(BuildContext context, RoomHookContext ctx) =>
    const [];

/// Settings sections (for example "Show chat effects").
List<Widget> composerSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];

/// Outgoing text transform (for example `/confetti` → effect msgtype).
Map<String, Object?> composerTransformOutgoing(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) => content;
