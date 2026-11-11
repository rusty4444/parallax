// Hook implementations for the reactions and message actions feature module.
//
// Emoji picker, reactions, forwarding, pinning and reporting.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../hooks/hook_types.dart';

/// Full emoji picker. Returns null when cancelled. Core falls back to its
/// short built-in list only when this returns null *and* [available] is false.
const bool emojiPickerAvailable = false;

Future<String?> pickEmoji(
  BuildContext context, {
  AppPalette? palette,
  bool forReaction = false,
}) async => null;

/// Whether reactions may be sent in this room from the UI.
bool reactionsAllowed(RoomHookContext ctx) => !ctx.encrypted;

List<MessageActionItem> reactionMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

/// Banners under the room header (for example pinned messages).
List<Widget> reactionRoomBanners(BuildContext context, RoomHookContext ctx) =>
    const [];

List<Widget> reactionRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];
