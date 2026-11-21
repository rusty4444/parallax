import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../chat_lock/chat_lock_gate.dart';
import 'room_list_filters.dart';

/// Choices in the room list long-press menu (Element X RoomListContextMenu).
enum RoomMenuAction {
  markRead,
  markUnread,
  favourite,
  lowPriority,
  mute,
  unmute,

  /// Keeps Note to self first in the chat list, or lets it sort with the
  /// other chats.
  pin,
  unpin,

  /// Opens the saved module's "Add to folder…" sheet.
  addToFolder,

  /// Opens the chat picture sheet (a picture only this phone shows).
  chatPicture,
  lockChat,
  unlockChat,
  copyLink,
  leave,
}

/// What the menu can offer for the current backend.
class RoomMenuCapabilities {
  const RoomMenuCapabilities({
    this.favourites = false,
    this.tags = false,
    this.notifications = false,
    this.folders = false,
  });
  final bool favourites;

  /// Low priority tagging.
  final bool tags;

  /// Per-room mute via push rules.
  final bool notifications;

  /// Chat folders (saved module).
  final bool folders;
}

Future<RoomMenuAction?> showRoomListMenu(
  BuildContext context, {
  required ChatRoom room,
  required bool favourite,
  required RoomMenuCapabilities capabilities,

  /// Offers Pin/Unpin for a chat that can be pinned to the top (Note to
  /// self); null hides it.
  bool? pinned,
}) {
  final unread = isRoomUnread(room, const RoomListContext());
  return showModalBottomSheet<RoomMenuAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final chatLock = ChatLockScope.maybeOf(sheetContext);
      final chatLocked = chatLock?.isLocked(room.id) ?? false;
      Widget item(
        RoomMenuAction action,
        IconData icon,
        String label, {
        bool destructive = false,
      }) {
        final colour = destructive
            ? Theme.of(sheetContext).colorScheme.error
            : null;
        return ListTile(
          leading: Icon(icon, color: colour),
          title: Text(label, style: TextStyle(color: colour)),
          onTap: () => Navigator.pop(sheetContext, action),
        );
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Room actions'),
              ),
              if (unread)
                item(
                  RoomMenuAction.markRead,
                  Icons.mark_email_read_outlined,
                  'Mark as read',
                )
              else
                item(
                  RoomMenuAction.markUnread,
                  Icons.mark_email_unread_outlined,
                  'Mark as unread',
                ),
              if (pinned != null)
                pinned
                    ? item(
                        RoomMenuAction.unpin,
                        Icons.push_pin_outlined,
                        'Unpin from top',
                      )
                    : item(
                        RoomMenuAction.pin,
                        Icons.push_pin_rounded,
                        'Pin to top',
                      ),
              if (capabilities.favourites)
                item(
                  RoomMenuAction.favourite,
                  favourite ? Icons.star_rounded : Icons.star_border_rounded,
                  favourite ? 'Remove favourite' : 'Add favourite',
                ),
              if (capabilities.tags)
                item(
                  RoomMenuAction.lowPriority,
                  room.lowPriority
                      ? Icons.keyboard_double_arrow_up_rounded
                      : Icons.keyboard_double_arrow_down_rounded,
                  room.lowPriority
                      ? 'Remove from low priority'
                      : 'Mark as low priority',
                ),
              if (capabilities.notifications)
                room.muted
                    ? item(
                        RoomMenuAction.unmute,
                        Icons.notifications_active_outlined,
                        'Unmute notifications',
                      )
                    : item(
                        RoomMenuAction.mute,
                        Icons.notifications_off_outlined,
                        'Mute notifications',
                      ),
              if (capabilities.folders)
                item(
                  RoomMenuAction.addToFolder,
                  Icons.create_new_folder_outlined,
                  'Add to folder…',
                ),
              item(
                RoomMenuAction.chatPicture,
                Icons.add_photo_alternate_outlined,
                'Chat picture…',
              ),
              if (chatLock != null && !room.invited)
                item(
                  chatLocked
                      ? RoomMenuAction.unlockChat
                      : RoomMenuAction.lockChat,
                  chatLocked ? Icons.lock_open_rounded : Icons.lock_rounded,
                  chatLocked ? 'Unlock chat' : 'Lock chat',
                ),
              item(
                RoomMenuAction.copyLink,
                Icons.link_rounded,
                'Copy room link',
              ),
              item(
                RoomMenuAction.leave,
                Icons.exit_to_app_rounded,
                room.isDirect ? 'Leave conversation' : 'Leave room',
                destructive: true,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Element X leave-room confirmation wording.
Future<bool> confirmLeaveRoom(BuildContext context, ChatRoom room) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Leave ${room.name}?'),
      content: Text(
        room.isDirect
            ? 'Are you sure you want to leave this conversation? This '
                  'conversation is not public and you won’t be able to rejoin '
                  'without an invite.'
            : 'You will no longer see new messages in this room. '
                  'You may need another invitation to rejoin.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Leave'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
