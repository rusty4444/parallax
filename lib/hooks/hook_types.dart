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

/// The composer's current draft, for send options such as "Send later".
@immutable
class ComposerDraft {
  const ComposerDraft({
    required this.text,
    this.replyToId,
    this.threadRootId,
    this.editing = false,
  });

  /// Plain composer text (markdown, `/commands` and `:shortcodes:` intact).
  final String text;
  final String? replyToId;
  final String? threadRootId;

  /// True while editing an existing message.
  final bool editing;
}

/// An option in the send button's long-press menu (for example "Send later").
@immutable
class ComposerSendOption {
  const ComposerSendOption({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
  });
  final String id;
  final IconData icon;
  final String label;

  /// Runs with the room screen's context. Return true when the draft was
  /// consumed (the composer then clears it, exactly as after a normal send).
  final Future<bool> Function(BuildContext context, ComposerDraft draft)
  onSelected;
}

/// One row in a composer autocomplete list.
@immutable
class ComposerSuggestion {
  const ComposerSuggestion({
    required this.id,
    required this.label,
    required this.insertText,
    this.subtitle,
    this.leading,
  });
  final String id;
  final String label;
  final String? subtitle;

  /// Replaces the trigger character plus the typed query.
  final String insertText;
  final Widget? leading;
}

/// Autocomplete keyed by a trigger character typed after whitespace or at the
/// start of the text, for example `:` for custom emoji or `/` for commands.
/// (`@` mentions are built into the rich timeline module.)
@immutable
class ComposerSuggestionSource {
  const ComposerSuggestionSource({
    required this.id,
    required this.trigger,
    required this.search,
    this.minQueryLength = 0,
  });
  final String id;

  /// A single character such as `:` or `/`.
  final String trigger;
  final int minQueryLength;
  final List<ComposerSuggestion> Function(String query) search;
}

/// Context for transforming an outgoing text message's content just before
/// it is sent (and after markdown, `/me` and mentions were derived).
@immutable
class OutgoingTextContext {
  const OutgoingTextContext({
    required this.backend,
    required this.roomId,
    required this.text,
    this.editing = false,
  });
  final ChatBackend backend;
  final String roomId;

  /// The composer's original plain text.
  final String text;
  final bool editing;
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
