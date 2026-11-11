import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../chat_backend.dart';

/// Extension-point types shared by feature modules.
///
/// Core screens (room, room details, settings, app shell) call the
/// aggregators in `registry.dart`; each feature module implements the hook
/// functions in its own `lib/features/<feature>/*_hooks.dart` file. This keeps
/// features independent of each other and of the core screens.

/// A room as seen by a hook.
@immutable
class RoomHookContext {
  const RoomHookContext({
    required this.backend,
    required this.roomId,
    required this.palette,
    this.room,
  });
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  /// Current inbox projection of the room, if known.
  final ChatRoom? room;

  bool get encrypted => room?.encrypted ?? false;
}

/// A timeline entry as seen by a hook.
@immutable
class EntryHookContext {
  const EntryHookContext({
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.entry,
    this.room,
    this.entries = const [],
  });
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final ChatEntry entry;
  final ChatRoom? room;

  /// Currently loaded timeline (oldest first), for lookups such as replies.
  final List<ChatEntry> entries;

  bool get mine => entry.mine;
  bool get encrypted => room?.encrypted ?? false;

  /// Foreground colour for text drawn inside this entry's bubble.
  Color get onBubble => mine ? palette.bubbleText : palette.foreground;

  RoomHookContext get roomContext => RoomHookContext(
    backend: backend,
    roomId: roomId,
    palette: palette,
    room: room,
  );
}

/// The app shell as seen by hooks that wrap the whole UI.
@immutable
class AppHookContext {
  const AppHookContext({
    required this.backend,
    required this.palette,
    required this.navigatorKey,
  });
  final ChatBackend backend;
  final AppPalette palette;

  /// Navigator of the signed-in UI. Replaced on logout/account change, so do
  /// not cache it beyond one callback.
  final GlobalKey<NavigatorState> navigatorKey;
}

/// The settings screen as seen by hooks that contribute sections.
@immutable
class SettingsHookContext {
  const SettingsHookContext({required this.backend, required this.palette});
  final ChatBackend backend;
  final AppPalette palette;
}

/// One entry in a message's long-press action sheet.
@immutable
class MessageActionItem {
  const MessageActionItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });
  final String id;
  final IconData icon;
  final String label;
  final bool destructive;

  /// Runs after the sheet closes, with the room screen's context.
  final Future<void> Function(BuildContext context) onSelected;
}

/// One extra option in the composer's attachment sheet (poll, location …).
@immutable
class ComposerAttachmentAction {
  const ComposerAttachmentAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
  });
  final String id;
  final IconData icon;
  final String label;

  /// Runs after the attachment sheet closes, with the room screen's context.
  final Future<void> Function(BuildContext context) onSelected;
}
