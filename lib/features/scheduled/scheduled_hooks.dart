// Hook implementations for the scheduled messages and undo send feature module.
//
// Send later (MSC4140 delayed events) and the undo-send grace period.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'undo_send.dart';
import 'undo_send_settings.dart';

List<ComposerSendOption> scheduledSendOptions(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<Widget> scheduledRoomBanners(BuildContext context, RoomHookContext ctx) =>
    const [];

/// Settings → Sending → Undo send.
List<Widget> scheduledSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  if (undoSendFeaturesOf(ctx.backend) == null) return const [];
  return [UndoSendSettingsSection(palette: ctx.palette)];
}
