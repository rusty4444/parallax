// Hook implementations for the scheduled messages and undo send feature module.
//
// Send later (MSC4140 delayed events) and the undo-send grace period.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'scheduled_features.dart';
import 'scheduled_list.dart';
import 'send_later_sheet.dart';

/// Long-press send option: "Send later…".
List<ComposerSendOption> scheduledSendOptions(
  BuildContext context,
  RoomHookContext ctx,
) {
  if (scheduledFeaturesOf(ctx.backend) == null) return const [];
  return [
    ComposerSendOption(
      id: 'scheduled.send_later',
      icon: Icons.schedule_send_outlined,
      label: 'Send later…',
      onSelected: (context, draft) => sendDraftLater(context, ctx, draft),
    ),
  ];
}

/// "1 scheduled message" banner under the room header.
List<Widget> scheduledRoomBanners(BuildContext context, RoomHookContext ctx) {
  if (scheduledFeaturesOf(ctx.backend) == null) return const [];
  return [
    ScheduledMessagesBanner(
      key: ValueKey('scheduled.banner.${ctx.roomId}'),
      backend: ctx.backend,
      palette: ctx.palette,
      roomId: ctx.roomId,
      encrypted: ctx.encrypted,
    ),
  ];
}

// Undo send's setting lives in Settings → Appearance, next to the other
// message behaviour toggles (lib/appearance_settings_screen.dart).
