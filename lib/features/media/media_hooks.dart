// Hook implementations for the media feature module.
//
// Video, voice/audio, stickers, animated images, gallery and upload quality.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Body for media kinds (video, audio, voice, sticker …). Return null to use
/// the core image/attachment rendering.
Widget? mediaEntryBody(BuildContext context, EntryHookContext ctx) => null;

List<MessageActionItem> mediaMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

List<Widget> mediaRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<Widget> mediaSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
