// Hook implementations for the room administration feature module.
//
// Start chat/create/join, room details, members, roles and moderation.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../room_events.dart';
import 'admin_ui.dart';
import 'decline_and_block.dart';
import 'knock_requests_screen.dart';
import 'rooms_admin_features.dart';
import 'start_chat_screen.dart';
import 'user_profile_screen.dart';

/// True once [openStartChat] provides the full start-chat flow.
const bool startChatAvailable = true;

/// Opens the start-chat flow (DM, create room, join by address). Returns the
/// room ID to open, or null when cancelled.
Future<String?> openStartChat(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => StartChatScreen(backend: backend, palette: palette),
  ),
);

/// Opens a user's profile (DM, verify, block/ignore, moderation in [roomId]).
Future<void> openUserProfile(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String userId, {
  String? roomId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => UserProfileScreen(
      backend: backend,
      palette: palette,
      userId: userId,
      roomId: roomId,
    ),
  ),
);

/// Banners under the room header (for example knock requests).
List<Widget> roomsAdminRoomBanners(BuildContext context, RoomHookContext ctx) {
  if (roomsAdminFeaturesOf(ctx.backend) == null) return const [];
  return [
    KnockRequestsBanner(
      key: ValueKey('rooms_admin.knocks.${ctx.roomId}'),
      backend: ctx.backend,
      palette: ctx.palette,
      roomId: ctx.roomId,
    ),
  ];
}

/// Moderator actions on others' messages (remove with reason …).
List<MessageActionItem> roomsAdminMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  final backend = ctx.backend;
  if (ctx.mine ||
      entry.redacted ||
      !entry.id.startsWith(r'$') ||
      backend is! RoomEventFeatures) {
    return const [];
  }
  final details = roomsAdminFeaturesOf(backend)?.cachedRoomDetails(ctx.roomId);
  if (details == null || !details.canRedactOthers) return const [];
  return [
    MessageActionItem(
      id: 'rooms_admin.remove',
      icon: Icons.delete_sweep_outlined,
      label: 'Remove…',
      destructive: true,
      onSelected: (context) =>
          removeMessageWithReason(context, backend, ctx.roomId, entry.id),
    ),
  ];
}

/// Confirms and redacts someone else's message with an optional reason.
Future<void> removeMessageWithReason(
  BuildContext context,
  ChatBackend backend,
  String roomId,
  String eventId,
) async {
  if (backend is! RoomEventFeatures) return;
  final reason = await askReason(
    context,
    title: 'Remove message?',
    message:
        'This removes the message for everyone in the room. You can add a '
        'reason, which other people can see.',
    confirm: 'Remove',
  );
  if (reason == null || !context.mounted) return;
  try {
    await (backend as RoomEventFeatures).redactEvent(
      roomId,
      eventId,
      reason: reason.isEmpty ? null : reason,
    );
  } catch (_) {
    if (context.mounted) {
      showAdminMessage(
        context,
        'Couldn’t remove this message. Your permissions may have changed.',
      );
    }
  }
}

// --- Extension points and APIs for other modules --------------------------

/// New extension point (coordinator wiring): a call starter for the room in
/// [ctx], shown as "Call" in room details and user profiles. Returns null to
/// hide the action. The call module should provide the body.
Future<void> Function(BuildContext context)? roomsAdminCallAction(
  BuildContext context,
  RoomHookContext ctx,
) => null;

/// Element X "Decline and block" for the invitation [roomId]: declines,
/// optionally blocks the inviter and reports the room. Returns true when the
/// invitation was declined. For the home module's invite actions.
Future<bool> showDeclineAndBlock(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String roomId, {
  String? roomName,
}) async {
  final declined = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => DeclineAndBlockScreen(
        backend: backend,
        palette: palette,
        roomId: roomId,
        roomName: roomName,
      ),
    ),
  );
  return declined == true;
}
