// Hook implementations for the saved messages and chat folders feature module.
//
// Note to self, bookmarks and chat folders.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_messages_screen.dart';
import 'saved_models.dart';
import 'saved_settings_section.dart';

/// "Save" / "Remove from saved" on any sent, non-state message.
List<MessageActionItem> savedMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final features = savedFeaturesOf(ctx.backend);
  final entry = ctx.entry;
  if (features == null ||
      entry.kind == EntryKind.state ||
      entry.redacted ||
      !isRoomIdLike(ctx.roomId) ||
      // Local echoes have no server event ID yet.
      !isEventIdLike(entry.id)) {
    return const [];
  }
  final saved = features.bookmarks.contains(ctx.roomId, entry.id);
  return [
    MessageActionItem(
      id: 'saved.toggle',
      icon: saved
          ? Icons.bookmark_remove_outlined
          : Icons.bookmark_add_outlined,
      label: saved ? 'Remove from saved' : 'Save',
      onSelected: (context) => toggleSavedMessage(
        context,
        backend: ctx.backend,
        palette: ctx.palette,
        features: features,
        roomId: ctx.roomId,
        eventId: entry.id,
        save: !saved,
      ),
    ),
  ];
}

/// Saves or un-saves one message and confirms with a snack bar.
Future<void> toggleSavedMessage(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
  required String roomId,
  required String eventId,
  required bool save,
}) async {
  try {
    await features.setSaved(roomId, eventId, saved: save);
  } catch (_) {
    if (context.mounted) {
      showSavedSnack(context, 'Couldn’t update your saved messages.');
    }
    return;
  }
  if (!context.mounted) return;
  showSavedSnack(
    context,
    save ? 'Message saved' : 'Removed from saved messages',
    action: save
        ? SnackBarAction(
            label: 'View',
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => SavedMessagesScreen(
                  backend: backend,
                  palette: palette,
                  features: features,
                ),
              ),
            ),
          )
        : null,
  );
}

List<Widget> savedSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final features = savedFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    SavedSettingsSection(
      key: const ValueKey('saved-settings'),
      backend: ctx.backend,
      palette: ctx.palette,
      features: features,
    ),
  ];
}
