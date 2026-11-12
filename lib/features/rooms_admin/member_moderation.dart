import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';

enum MemberChoice { profile, kick, ban, unban }

/// Element X "manage member" sheet. Only actions the fresh state permits are
/// offered; the backend re-checks before writing.
Future<MemberChoice?> showMemberSheet(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required RoomDetails details,
  required RoomMemberDetails member,
}) {
  final self = member.id == backend.userId;
  return showModalBottomSheet<MemberChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PersonAvatar(
              backend: backend,
              palette: palette,
              name: member.name,
              url: member.avatarUrl,
              size: 64,
            ),
            const SizedBox(height: 10),
            Text(
              member.name,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(member.id, style: TextStyle(color: palette.muted)),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('View profile'),
              onTap: () => Navigator.pop(sheetContext, MemberChoice.profile),
            ),
            if (!self && details.can(RoomAction.kick, member))
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('Remove user'),
                onTap: () => Navigator.pop(sheetContext, MemberChoice.kick),
              ),
            if (!self && details.can(RoomAction.ban, member))
              ListTile(
                leading: const Icon(
                  Icons.block_rounded,
                  color: Color(0xFFFF6B5E),
                ),
                title: const Text(
                  'Ban user',
                  style: TextStyle(color: Color(0xFFFF6B5E)),
                ),
                onTap: () => Navigator.pop(sheetContext, MemberChoice.ban),
              ),
            if (!self && details.can(RoomAction.unban, member))
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('Unban user'),
                onTap: () => Navigator.pop(sheetContext, MemberChoice.unban),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// Confirms (with an optional reason) and performs a moderation choice.
/// Returns true when the server accepted it.
Future<bool> moderateFromChoice(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required RoomMemberDetails member,
  required MemberChoice choice,
  ValueChanged<bool>? onBusy,
}) async {
  final (action, title, message, confirm, progress) = switch (choice) {
    MemberChoice.kick => (
      RoomAction.kick,
      'Are you sure you want to remove this member?',
      'They will be able to join this room again if invited.',
      'Remove',
      'Removing ${member.name}…',
    ),
    MemberChoice.ban => (
      RoomAction.ban,
      'Are you sure you want to ban this member?',
      'They won’t be able to join again if invited.',
      'Ban',
      'Banning ${member.name}…',
    ),
    MemberChoice.unban => (
      RoomAction.unban,
      'Are you sure you want to unban this member?',
      'They would be able to join again if invited.',
      'Unban',
      'Unbanning ${member.name}…',
    ),
    MemberChoice.profile => throw ArgumentError('Not a moderation choice'),
  };
  final reason = await askReason(
    context,
    title: title,
    message: message,
    confirm: confirm,
    destructive: choice != MemberChoice.unban,
  );
  if (reason == null || !context.mounted) return false;
  showAdminMessage(context, progress);
  onBusy?.call(true);
  try {
    final admin = roomsAdminFeaturesOf(backend);
    if (admin != null) {
      await admin.moderateMember(roomId, member.id, action, reason: reason);
    } else {
      await backend.moderateRoomMember(roomId, member.id, action);
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      showAdminMessage(
        context,
        'Couldn’t ${confirm.toLowerCase()} ${member.name}. Your permissions '
        'or the room may have changed.',
      );
    }
    return false;
  } finally {
    onBusy?.call(false);
  }
}
