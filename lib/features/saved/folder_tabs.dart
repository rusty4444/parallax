import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'folder_editor_screen.dart';
import 'folders_screen.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_models.dart';

/// Horizontally scrollable chat folder tabs above the room list: "All", one
/// tab per folder with its unread badge, and a New folder button.
class FolderTabs extends StatelessWidget {
  const FolderTabs({
    super.key,
    required this.folders,
    required this.selectedId,
    required this.unreadCounts,
    required this.palette,
    required this.onSelected,
    required this.onOptions,
    required this.onNewFolder,
  });

  final List<ChatFolder> folders;
  final String? selectedId;
  final Map<String, int> unreadCounts;
  final AppPalette palette;
  final ValueChanged<String?> onSelected;
  final ValueChanged<ChatFolder> onOptions;
  final VoidCallback onNewFolder;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        _FolderTab(
          key: const ValueKey('folder-tab-all'),
          label: 'All',
          selected: selectedId == null,
          palette: palette,
          onTap: () => onSelected(null),
        ),
        for (final folder in folders)
          _FolderTab(
            key: ValueKey('folder-tab-${folder.id}'),
            label: folder.label,
            unread: unreadCounts[folder.id] ?? 0,
            selected: selectedId == folder.id,
            palette: palette,
            onTap: () => onSelected(folder.id),
            onLongPress: () => onOptions(folder),
          ),
        IconButton(
          tooltip: 'New folder',
          visualDensity: VisualDensity.compact,
          onPressed: onNewFolder,
          icon: Icon(Icons.create_new_folder_outlined, color: palette.muted),
        ),
      ],
    ),
  );
}

class _FolderTab extends StatelessWidget {
  const _FolderTab({
    super.key,
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
    this.onLongPress,
    this.unread = 0,
  });

  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final foreground = selected ? p.foreground : p.muted;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Semantics(
        button: true,
        selected: selected,
        label: unread > 0 ? '$label, $unread unread' : label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? p.accent : Colors.transparent,
                  width: 2.5,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (unread > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? p.accent : p.raised,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: selected ? p.accentOn : p.foreground,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the folder editor. Resolves to the saved folder's ID, or null.
Future<String?> openFolderEditor(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
  ChatFolder? folder,
  List<String> initialRooms = const [],
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => FolderEditorScreen(
      backend: backend,
      palette: palette,
      features: features,
      folder: folder,
      initialRooms: initialRooms,
    ),
  ),
);

Future<void> openFoldersScreen(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => ChatFoldersScreen(
      backend: backend,
      palette: palette,
      features: features,
    ),
  ),
);

/// Asks before deleting [folder]; chats in it are not affected.
Future<bool> confirmDeleteFolder(
  BuildContext context,
  ChatFolder folder,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete “${folder.name}”?'),
      content: const Text(
        'The folder is removed on all your devices. The chats in it are '
        'not affected.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete folder'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Long-press options for a folder tab: edit, move, manage and delete.
/// Returns true when the folder was deleted.
Future<bool> showFolderTabOptions(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
  required ChatFolder folder,
}) async {
  final folders = features.folders.folders;
  final index = folders.indexWhere((f) => f.id == folder.id);
  if (index < 0) return false;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              folder.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Chat folder'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('Edit folder'),
            onTap: () => Navigator.pop(sheetContext, 'edit'),
          ),
          if (index > 0)
            ListTile(
              leading: const Icon(Icons.arrow_back_rounded),
              title: const Text('Move left'),
              onTap: () => Navigator.pop(sheetContext, 'left'),
            ),
          if (index < folders.length - 1)
            ListTile(
              leading: const Icon(Icons.arrow_forward_rounded),
              title: const Text('Move right'),
              onTap: () => Navigator.pop(sheetContext, 'right'),
            ),
          ListTile(
            leading: const Icon(Icons.reorder_rounded),
            title: const Text('Reorder folders'),
            onTap: () => Navigator.pop(sheetContext, 'manage'),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_outline_rounded,
              color: Theme.of(sheetContext).colorScheme.error,
            ),
            title: Text(
              'Delete folder',
              style: TextStyle(color: Theme.of(sheetContext).colorScheme.error),
            ),
            onTap: () => Navigator.pop(sheetContext, 'delete'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return false;
  final owner = BackendSessionOwner(backend);
  try {
    switch (choice) {
      case 'edit':
        await openFolderEditor(
          context,
          backend: backend,
          palette: palette,
          features: features,
          folder: folder,
        );
      case 'manage':
        await openFoldersScreen(
          context,
          backend: backend,
          palette: palette,
          features: features,
        );
      case 'left' || 'right':
        await features.updateFolders((current) {
          final at = current.folders.indexWhere((f) => f.id == folder.id);
          return at < 0
              ? current
              : current.withMoved(
                  folder.id,
                  choice == 'left' ? at - 1 : at + 1,
                );
        });
      case 'delete':
        if (!await confirmDeleteFolder(context, folder) ||
            !context.mounted ||
            !owner.isCurrent) {
          return false;
        }
        await features.updateFolders(
          (current) => current.withRemoved(folder.id),
        );
        return true;
    }
  } catch (_) {
    if (context.mounted && owner.isCurrent) {
      showSavedSnack(context, 'Couldn’t update your folders. Try again.');
    }
  } finally {
    owner.release();
  }
  return false;
}

/// "Add to folder…" from a room's long-press menu: tick folders to add or
/// remove the room; changes are written immediately.
Future<void> showAddToFolderSheet(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required SavedFeatures features,
  required ChatRoom room,
  required FolderRoomFacts facts,
}) async {
  final createNew = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _AddToFolderSheet(
      backend: backend,
      palette: palette,
      features: features,
      room: room,
      facts: facts,
    ),
  );
  if (createNew == true && context.mounted) {
    await openFolderEditor(
      context,
      backend: backend,
      palette: palette,
      features: features,
      initialRooms: [room.id],
    );
  }
}

class _AddToFolderSheet extends StatefulWidget {
  const _AddToFolderSheet({
    required this.backend,
    required this.palette,
    required this.features,
    required this.room,
    required this.facts,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final SavedFeatures features;
  final ChatRoom room;
  final FolderRoomFacts facts;

  @override
  State<_AddToFolderSheet> createState() => _AddToFolderSheetState();
}

class _AddToFolderSheetState extends State<_AddToFolderSheet> {
  late final _owner = BackendSessionOwner(widget.backend);
  String? _busy;

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  Future<void> _toggle(ChatFolder folder, bool member) async {
    if (_busy != null || !_owner.isCurrent) return;
    setState(() => _busy = folder.id);
    try {
      await widget.features.updateFolders((current) {
        final latest = current.byId(folder.id);
        if (latest == null) return current;
        return current.withUpserted(
          latest.withRoomMembership(
            widget.room.id,
            member: member,
            matchesTypes: folderMatchesTypes(latest, widget.room, widget.facts),
          ),
        );
      });
    } on SavedDataTooLarge {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'This folder can’t hold any more chats.');
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'Couldn’t update this folder. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  late final Listenable _changes = Listenable.merge([
    widget.backend,
    if (!identical(widget.features, widget.backend)) widget.features,
  ]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) {
      final folders = widget.features.folders.folders;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Add “${widget.room.name}” to a folder',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Folders sync across your devices.'),
              ),
              for (final folder in folders)
                CheckboxListTile(
                  key: ValueKey('add-to-folder-${folder.id}'),
                  value: folderContainsRoom(folder, widget.room, widget.facts),
                  title: Text(folder.label),
                  secondary: _busy == folder.id
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.folder_outlined),
                  onChanged: _busy != null
                      ? null
                      : (value) => unawaited(_toggle(folder, value ?? false)),
                ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('New folder…'),
                enabled: folders.length < maxFolders,
                onTap: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ),
      );
    },
  );
}
