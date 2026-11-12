import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import '../home/settings_widgets.dart';
import 'folder_tabs.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_models.dart';

/// Settings → Saved → Chat folders: reorder, edit, delete and create.
class ChatFoldersScreen extends StatefulWidget {
  const ChatFoldersScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final SavedFeatures features;

  @override
  State<ChatFoldersScreen> createState() => _ChatFoldersScreenState();
}

class _ChatFoldersScreenState extends State<ChatFoldersScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final Listenable _changes = Listenable.merge([
    widget.backend,
    if (!identical(widget.features, widget.backend)) widget.features,
  ]);
  bool _busy = false;

  /// Order shown while a reorder write is in flight.
  List<String>? _pendingOrder;

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy || !_owner.isCurrent) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && _owner.isCurrent) showSavedSnack(context, failure);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _pendingOrder = null;
        });
      }
    }
  }

  /// [newIndex] is already adjusted for the removed item.
  void _reorder(List<ChatFolder> folders, int oldIndex, int newIndex) {
    final ids = [for (final f in folders) f.id];
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex, moved);
    setState(() => _pendingOrder = ids);
    _run(
      () => widget.features
          .updateFolders((current) => current.withOrder(ids))
          .then((_) {}),
      'Couldn’t reorder your folders. Try again.',
    );
  }

  Future<void> _delete(ChatFolder folder) async {
    if (!await confirmDeleteFolder(context, folder) ||
        !mounted ||
        !_owner.isCurrent) {
      return;
    }
    await _run(
      () => widget.features
          .updateFolders((current) => current.withRemoved(folder.id))
          .then((_) {}),
      'Couldn’t delete this folder. Try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: _changes,
      builder: (context, _) {
        final stored = widget.features.folders;
        final order = _pendingOrder;
        final folders = order == null
            ? stored.folders
            : stored.withOrder(order).folders;
        return SettingsPage(
          palette: p,
          eyebrow: 'Saved',
          title: 'Chat folders',
          children: [
            SettingsGroup(
              palette: p,
              footer:
                  'Folders appear as tabs above your chats. Long-press a tab '
                  'to edit it. Folders sync across your devices; only folder '
                  'names and chat IDs are stored on your homeserver.',
              children: [
                if (folders.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.folder_off_outlined),
                    title: Text('No folders yet'),
                    subtitle: Text(
                      'Group chats into tabs such as Work or Family.',
                    ),
                  )
                else
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: folders.length,
                    onReorderItem: (from, to) => _reorder(folders, from, to),
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      return Material(
                        key: ValueKey('folder-${folder.id}'),
                        color: p.surface,
                        child: ListTile(
                          leading: ReorderableDragStartListener(
                            index: index,
                            enabled: !_busy,
                            child: const Icon(Icons.drag_handle_rounded),
                          ),
                          title: Text(
                            folder.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_summary(folder)),
                          onTap: _busy
                              ? null
                              : () => openFolderEditor(
                                  context,
                                  backend: widget.backend,
                                  palette: p,
                                  features: widget.features,
                                  folder: folder,
                                ),
                          trailing: IconButton(
                            tooltip: 'Delete folder',
                            onPressed: _busy ? null : () => _delete(folder),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            AccentButton(
              palette: p,
              label: 'New folder',
              icon: Icons.create_new_folder_outlined,
              onPressed: _busy || folders.length >= maxFolders
                  ? null
                  : () => openFolderEditor(
                      context,
                      backend: widget.backend,
                      palette: p,
                      features: widget.features,
                    ),
            ),
          ],
        );
      },
    );
  }
}

String _summary(ChatFolder folder) {
  final include = folder.include;
  final parts = [
    if (include.unread) 'Unread',
    if (include.people) 'People',
    if (include.groups) 'Rooms',
    if (include.favourites) 'Favourites',
    if (include.invites) 'Invites',
    if (folder.includeRooms.isNotEmpty)
      folder.includeRooms.length == 1
          ? '1 chat'
          : '${folder.includeRooms.length} chats',
  ];
  return parts.isEmpty ? 'Empty' : parts.join(' · ');
}
