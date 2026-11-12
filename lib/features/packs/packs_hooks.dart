// Hook implementations for the custom emoji and sticker packs feature module.
//
// MSC2545 image packs: emoticons, stickers and pack management.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

List<ComposerSuggestionSource> packsSuggestionSources(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

Map<String, Object?> packsTransformOutgoing(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) => content;

List<ComposerAttachmentAction> packsComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<Widget> packsRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<Widget> packsSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
