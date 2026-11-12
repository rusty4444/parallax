import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import '../home/settings_widgets.dart';
import '../reactions/emoji_picker_sheet.dart';
import 'folder_tabs.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_models.dart';

/// Create or edit a chat folder: name, emoji icon, chat types, and chats that
/// are always included or always excluded.
class FolderEditorScreen extends StatefulWidget {
  const FolderEditorScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
    this.folder,
    this.initialRooms = const [],
  });

  final ChatBackend backend;
  final AppPalette palette;
  final SavedFeatures features;

  /// The folder to edit; null creates a new one.
  final ChatFolder? folder;

  /// Chats included in a new folder ("Add to folder… → New folder").
  final List<String> initialRooms;

  @override
  State<FolderEditorScreen> createState() => _FolderEditorScreenState();
}

class _FolderEditorScreenState extends State<FolderEditorScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _name = TextEditingController(text: widget.folder?.name ?? '');
  late String? _icon = widget.folder?.icon;
  late FolderIncludes _include =
      widget.folder?.include ?? const FolderIncludes();
  late List<String> _included = [
    ...?widget.folder?.includeRooms,
    for (final id in widget.initialRooms)
      if (!(widget.folder?.includeRooms.contains(id) ?? false)) id,
  ];
  late List<String> _excluded = [
    ...?widget.folder?.excludeRooms.where(
      (id) => !widget.initialRooms.contains(id),
    ),
  ];
  bool _saving = false;

  bool get _editing => widget.folder != null;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
  }

  @override
  void dispose() {
    _name.removeListener(_changed);
    _name.dispose();
    _owner.release();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _valid =>
      cleanFolderName(_name.text).isNotEmpty &&
      (_include.any || _included.isNotEmpty);

  String _roomName(String id) {
    if (id == widget.features.noteToSelfRoomId) return noteToSelfTitle;
    for (final room in widget.backend.rooms) {
      if (room.id == id) return room.name;
    }
    return 'Unknown room';
  }

  Future<void> _pickIcon() async {
    final emoji = await showEmojiPickerSheet(context, palette: widget.palette);
    if (!mounted || emoji == null) return;
    final icon = cleanFolderIcon(emoji);
    if (icon != null) setState(() => _icon = icon);
  }

  Future<void> _pickRooms({required bool include}) async {
    final current = include ? _included : _excluded;
    final other = include ? _excluded : _included;
    final picked = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(
        builder: (_) => FolderRoomPickerScreen(
          backend: widget.backend,
          palette: widget.palette,
          title: include ? 'Included chats' : 'Excluded chats',
          selected: current,
          noteToSelfRoomId: widget.features.noteToSelfRoomId,
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() {
      final capped = picked.take(maxFolderRooms).toList();
      if (include) {
        _included = capped;
        _excluded = other.where((id) => !capped.contains(id)).toList();
      } else {
        _excluded = capped;
        _included = other.where((id) => !capped.contains(id)).toList();
      }
    });
  }

  Future<void> _save() async {
    if (!_valid || _saving || !_owner.isCurrent) return;
    setState(() => _saving = true);
    final base =
        widget.folder ??
        ChatFolder(id: newFolderId(), name: cleanFolderName(_name.text));
    final folder = base.copyWith(
      name: cleanFolderName(_name.text),
      icon: _icon,
      clearIcon: _icon == null,
      include: _include,
      includeRooms: List.unmodifiable(_included),
      excludeRooms: List.unmodifiable(_excluded),
    );
    try {
      await widget.features.updateFolders(
        (current) => current.withUpserted(folder),
      );
      if (mounted && _owner.isCurrent) Navigator.pop(context, folder.id);
    } on SavedDataTooLarge {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(
          context,
          'You have too many folders or chats in folders. Remove some, then '
          'try again.',
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'Couldn’t save this folder. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final folder = widget.folder;
    if (folder == null || _saving || !_owner.isCurrent) return;
    if (!await confirmDeleteFolder(context, folder) ||
        !mounted ||
        !_owner.isCurrent) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.features.updateFolders(
        (current) => current.withRemoved(folder.id),
      );
      if (mounted && _owner.isCurrent) Navigator.pop(context);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'Couldn’t delete this folder. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _typeSwitch(
    String title,
    String subtitle,
    bool value,
    FolderIncludes Function(bool value) update,
  ) => SwitchListTile(
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: _saving
        ? null
        : (next) => setState(() => _include = update(next)),
  );

  List<Widget> _roomRows(List<String> ids, {required bool include}) => [
    ListTile(
      leading: Icon(
        include ? Icons.add_circle_outline_rounded : Icons.block_rounded,
      ),
      title: Text(include ? 'Add chats' : 'Exclude chats'),
      onTap: _saving ? null : () => _pickRooms(include: include),
    ),
    for (final id in ids)
      ListTile(
        key: ValueKey('${include ? 'in' : 'out'}-$id'),
        leading: InitialAvatar(
          name: _roomName(id),
          palette: widget.palette,
          size: 34,
        ),
        title: Text(
          _roomName(id),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          tooltip: 'Remove',
          onPressed: _saving
              ? null
              : () => setState(() {
                  if (include) {
                    _included = _included.where((i) => i != id).toList();
                  } else {
                    _excluded = _excluded.where((i) => i != id).toList();
                  }
                }),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return SettingsPage(
      palette: p,
      eyebrow: 'Chat folders',
      title: _editing ? 'Edit folder' : 'New folder',
      children: [
        SettingsGroup(
          palette: p,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _name,
                autofocus: !_editing,
                maxLength: maxFolderNameLength,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Folder name',
                  hintText: 'Work, Family, Projects…',
                ),
              ),
            ),
            ListTile(
              leading: _icon == null
                  ? const Icon(Icons.emoji_emotions_outlined)
                  : Text(_icon!, style: const TextStyle(fontSize: 24)),
              title: Text(_icon == null ? 'Add an icon' : 'Change icon'),
              subtitle: const Text('Optional emoji shown on the folder tab'),
              onTap: _saving ? null : _pickIcon,
              trailing: _icon == null
                  ? null
                  : IconButton(
                      tooltip: 'Remove icon',
                      onPressed: _saving
                          ? null
                          : () => setState(() => _icon = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ],
        ),
        SettingsGroup(
          palette: p,
          title: 'Chat types',
          footer: 'Chats of these types appear in the folder automatically.',
          children: [
            _typeSwitch(
              'Unread',
              'Chats with unread messages',
              _include.unread,
              (v) => _include.copyWith(unread: v),
            ),
            _typeSwitch(
              'People',
              'Direct chats',
              _include.people,
              (v) => _include.copyWith(people: v),
            ),
            _typeSwitch(
              'Rooms',
              'Group chats',
              _include.groups,
              (v) => _include.copyWith(groups: v),
            ),
            _typeSwitch(
              'Favourites',
              'Chats you marked as favourite',
              _include.favourites,
              (v) => _include.copyWith(favourites: v),
            ),
            _typeSwitch(
              'Invites',
              'Pending invitations',
              _include.invites,
              (v) => _include.copyWith(invites: v),
            ),
          ],
        ),
        SettingsGroup(
          palette: p,
          title: 'Included chats',
          footer: 'Always shown in this folder.',
          children: _roomRows(_included, include: true),
        ),
        SettingsGroup(
          palette: p,
          title: 'Excluded chats',
          footer:
              'Never shown in this folder, even when they match a chat type.',
          children: _roomRows(_excluded, include: false),
        ),
        if (!_valid && cleanFolderName(_name.text).isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Choose at least one chat type or add a chat.',
              style: TextStyle(color: p.secondary, fontSize: 13),
            ),
          ),
        AccentButton(
          palette: p,
          label: _saving
              ? 'Saving…'
              : _editing
              ? 'Save changes'
              : 'Create folder',
          icon: Icons.check_rounded,
          onPressed: _valid && !_saving ? _save : null,
        ),
        if (_editing) ...[
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _saving ? null : _delete,
            icon: Icon(
              Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            label: Text(
              'Delete folder',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          'Folders sync across your devices. Only folder names and chat IDs '
          'are stored on your homeserver.',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
      ],
    );
  }
}

/// Multi-select list of chats for a folder's included or excluded chats.
/// Resolves to the selected room IDs, or null when cancelled.
class FolderRoomPickerScreen extends StatefulWidget {
  const FolderRoomPickerScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.title,
    required this.selected,
    this.noteToSelfRoomId,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final String title;
  final List<String> selected;
  final String? noteToSelfRoomId;

  @override
  State<FolderRoomPickerScreen> createState() => _FolderRoomPickerScreenState();
}

class _FolderRoomPickerScreenState extends State<FolderRoomPickerScreen> {
  late final _selected = <String>[...widget.selected];
  String _query = '';

  String _name(ChatRoom room) =>
      room.id == widget.noteToSelfRoomId ? noteToSelfTitle : room.name;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final query = _query.trim().toLowerCase();
        final rooms = [
          for (final room in widget.backend.rooms)
            if (!room.isSpace &&
                (query.isEmpty || _name(room).toLowerCase().contains(query)))
              room,
        ];
        // Chats already chosen but no longer in the list (left rooms) stay
        // visible so they can be removed.
        final known = {for (final room in widget.backend.rooms) room.id};
        final missing = _selected.where((id) => !known.contains(id)).toList();
        return SettingsPage(
          palette: p,
          eyebrow: 'Chat folders',
          title: widget.title,
          trailing: TextButton(
            onPressed: () => Navigator.pop(context, List.of(_selected)),
            child: Text('Done (${_selected.length})'),
          ),
          children: [
            TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Find a chat',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
            const SizedBox(height: 14),
            SettingsGroup(
              palette: p,
              children: [
                if (rooms.isEmpty && missing.isEmpty)
                  const ListTile(title: Text('No chats found')),
                for (final room in rooms)
                  CheckboxListTile(
                    key: ValueKey('pick-${room.id}'),
                    value: _selected.contains(room.id),
                    title: Text(
                      _name(room),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      room.invited
                          ? 'Invitation'
                          : room.isDirect
                          ? 'Direct chat'
                          : 'Room',
                    ),
                    onChanged: (value) => setState(() {
                      _selected.remove(room.id);
                      if (value == true && _selected.length < maxFolderRooms) {
                        _selected.add(room.id);
                      }
                    }),
                  ),
                for (final id in missing)
                  CheckboxListTile(
                    value: true,
                    title: const Text('Unknown room'),
                    subtitle: Text(id, maxLines: 1),
                    onChanged: (_) => setState(() => _selected.remove(id)),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
