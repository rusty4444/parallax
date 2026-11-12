import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'roles_permissions_screen.dart';
import 'rooms_admin_features.dart';

enum LeaveWarning { conversation, empty, lastAdmin, private, plain }

/// Which Element X leave warning applies, from fresh room state.
LeaveWarning leaveWarningFor(RoomDetails details, {required bool isDirect}) {
  if (isDirect) return LeaveWarning.conversation;
  final joined = details.membersWith(RoomMemberStatus.joined);
  if (joined.length <= 1) return LeaveWarning.empty;
  bool privileged(RoomMemberDetails member) =>
      member.creator && details.creatorsOutrank || member.powerLevel >= 100;
  final me = details.member(details.ownUserId ?? '');
  if (me != null &&
      privileged(me) &&
      !joined.any((member) => member.id != me.id && privileged(member))) {
    return LeaveWarning.lastAdmin;
  }
  if (!details.isPublic) return LeaveWarning.private;
  return LeaveWarning.plain;
}

String leaveWarningText(LeaveWarning warning) => switch (warning) {
  LeaveWarning.conversation =>
    'Are you sure that you want to leave this conversation? This '
        'conversation is not public and you won’t be able to rejoin without '
        'an invite.',
  LeaveWarning.empty =>
    'Are you sure that you want to leave this room? You’re the only person '
        'here. If you leave, no one will be able to join in the future, '
        'including you.',
  LeaveWarning.lastAdmin =>
    'You’re the only admin of this room. If you leave, nobody will be able '
        'to change its settings or moderate it. Promote someone first, or '
        'leave anyway.',
  LeaveWarning.private =>
    'Are you sure that you want to leave this room? This room is not public '
        'and you won’t be able to rejoin without an invite.',
  LeaveWarning.plain => 'Are you sure that you want to leave the room?',
};

/// Confirms with the right warning and leaves. Returns true once left.
Future<bool> leaveRoomFlow(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required RoomDetails details,
  required bool isDirect,
}) async {
  final warning = leaveWarningFor(details, isDirect: isDirect);
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isDirect ? 'Leave conversation' : 'Leave room'),
      content: Text(leaveWarningText(warning)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        if (warning == LeaveWarning.lastAdmin &&
            roomsAdminFeaturesOf(backend) != null)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'admins'),
            child: const Text('Choose admins'),
          ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD7263D),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(dialogContext, 'leave'),
          child: Text(
            warning == LeaveWarning.lastAdmin ? 'Leave anyway' : 'Leave',
          ),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return false;
  if (choice == 'admins') {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeRolesScreen(
          backend: backend,
          palette: palette,
          details: details,
          role: RoomRole.admin,
        ),
      ),
    );
    return false;
  }
  showAdminMessage(context, 'Leaving…');
  try {
    await backend.leaveRoom(details.roomId);
    return true;
  } catch (_) {
    if (context.mounted) {
      showAdminMessage(context, 'Couldn’t leave this room. Try again.');
    }
    return false;
  }
}
