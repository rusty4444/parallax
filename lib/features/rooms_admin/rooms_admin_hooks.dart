// Hook implementations for the room administration feature module.
//
// Start chat/create/join, room details, members, roles and moderation.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';

/// True once [openStartChat] provides the full start-chat flow.
const bool startChatAvailable = false;

/// Opens the start-chat flow (DM, create room, join by address). Returns the
/// room ID to open, or null when cancelled.
Future<String?> openStartChat(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
) async => null;

/// Opens a user's profile (DM, verify, block/ignore, moderation in [roomId]).
Future<void> openUserProfile(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String userId, {
  String? roomId,
}) async {}

/// Banners under the room header (for example knock requests).
List<Widget> roomsAdminRoomBanners(BuildContext context, RoomHookContext ctx) =>
    const [];

/// Moderator actions on others' messages (remove with reason …).
List<MessageActionItem> roomsAdminMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];
