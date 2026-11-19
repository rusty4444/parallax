import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_screen.dart';
import '../home/room_list_tile.dart';
import 'saved_features.dart';
import 'saved_models.dart';

/// Opens a room from the saved module's screens. Tests replace it to observe
/// navigation without building a full room screen.
void Function(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String roomId,
)
savedOpenRoomRoute = _pushRoom;

void _pushRoom(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String roomId,
) {
  unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoomScreen(backend: backend, palette: palette, roomId: roomId),
      ),
    ),
  );
}

/// Shows [message], replacing any snack bar from an earlier saved action so
/// rapid toggles do not queue stale confirmations.
void showSavedSnack(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

/// Opens (creating on first use) the Note to self room, then [open]s it.
/// Errors are shown as snack bars. Returns the room ID when it opened.
Future<String?> openNoteToSelfRoom(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
  void Function(String roomId)? open,
}) async {
  final owner = BackendSessionOwner(backend);
  try {
    final roomId = await features.openNoteToSelf();
    if (!context.mounted || !owner.isCurrent) return null;
    if (open != null) {
      open(roomId);
    } else {
      savedOpenRoomRoute(context, backend, palette, roomId);
    }
    return roomId;
  } on NoteToSelfUnavailable catch (error) {
    if (context.mounted && owner.isCurrent) {
      showSavedSnack(context, error.message);
    }
  } on NoteToSelfNotSynced {
    if (context.mounted && owner.isCurrent) {
      showSavedSnack(
        context,
        'Your note to self is ready but hasn’t synced yet. Try again in a '
        'moment.',
      );
    }
  } catch (_) {
    if (context.mounted && owner.isCurrent) {
      showSavedSnack(context, 'Couldn’t open your note to self. Try again.');
    }
  } finally {
    owner.release();
  }
  return null;
}

/// The distinct Note to self avatar: a notebook on the accent gradient.
class NoteToSelfAvatar extends StatelessWidget {
  const NoteToSelfAvatar({super.key, required this.palette, this.size = 52});
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: accentGradient(palette),
    ),
    alignment: Alignment.center,
    child: Icon(
      Icons.bookmarks_rounded,
      size: size * 0.46,
      color: palette.accentOn,
      semanticLabel: noteToSelfTitle,
    ),
  );
}

/// Pinned Note to self row at the top of the chat list.
class NoteToSelfTile extends StatelessWidget {
  const NoteToSelfTile({
    super.key,
    required this.room,
    required this.palette,
    required this.onTap,
    this.onLongPress,
    this.compact = false,
    this.busy = false,
    this.previewLines = 2,
    this.selected = false,
  });

  final ChatRoom room;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool compact;
  final bool busy;

  /// Open in the detail pane beside the list (wide adaptive layout).
  final bool selected;

  /// Lines of last-note preview (0 hides it), as the home setting chooses.
  final int previewLines;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final unread = room.unread > 0 || room.manuallyUnread;
    final preview = room.preview.isEmpty
        ? 'Notes, links and files just for you'
        : room.preview;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Color.alphaBlend(
          p.accent.withValues(alpha: selected ? 0.16 : 0.07),
          p.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: p.accent.withValues(alpha: selected ? 0.7 : 0.35),
          ),
        ),
        child: InkWell(
          onTap: busy ? null : onTap,
          onLongPress: busy ? null : onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: EdgeInsets.all(compact ? 9 : 14),
            child: Row(
              children: [
                NoteToSelfAvatar(palette: p),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              noteToSelfTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.foreground,
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: 'Pinned',
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 15,
                              color: p.secondary,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            RoomListTile.timeLabel(context, room.lastActivity),
                            style: TextStyle(color: p.muted, fontSize: 11),
                          ),
                        ],
                      ),
                      if (previewLines > 0) ...[
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            if (room.encrypted) ...[
                              Icon(
                                Icons.lock_outline,
                                size: 13,
                                color: p.secondary,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                preview,
                                maxLines: previewLines,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: unread ? p.foreground : p.muted,
                                  fontSize: 13,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            if (busy)
                              const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline inbox prompt shown until the Note to self room exists.
class StartNoteToSelfRow extends StatelessWidget {
  const StartNoteToSelfRow({
    super.key,
    required this.palette,
    required this.onStart,
    required this.onDismiss,
    this.busy = false,
  });

  final AppPalette palette;
  final VoidCallback onStart;
  final VoidCallback onDismiss;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: p.stroke),
        ),
        child: InkWell(
          onTap: busy ? null : onStart,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NoteToSelfAvatar(palette: p, size: 44),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Start your note to self',
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'A private, encrypted chat just for you, synced '
                        'across your devices.',
                        style: TextStyle(color: p.muted, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                    icon: Icon(Icons.close_rounded, color: p.muted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
