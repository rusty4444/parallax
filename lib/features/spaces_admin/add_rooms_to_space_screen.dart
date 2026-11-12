import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';
import '../rooms_admin/admin_ui.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

/// Element X AddRoomToSpace: pick joined rooms (not Spaces or DMs, not
/// already children) and add them. Pops the number of rooms added.
class AddRoomsToSpaceScreen extends StatefulWidget {
  const AddRoomsToSpaceScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.spaceId,
    this.spaceName,
    this.skippable = false,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String spaceId;
  final String? spaceName;

  /// Shown right after creating a Space: offers "Skip".
  final bool skippable;

  @override
  State<AddRoomsToSpaceScreen> createState() => _AddRoomsToSpaceScreenState();
}

class _AddRoomsToSpaceScreenState extends State<AddRoomsToSpaceScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _search = TextEditingController();
  final _selected = <String>{};
  final _added = <String>{};
  bool _suggested = false;
  bool _busy = false;

  SpacesAdminFeatures? get _spaces => spacesAdminFeaturesOf(widget.backend);

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _owner.release();
    _search.dispose();
    super.dispose();
  }

  List<SpaceRoomCandidate> _candidates() {
    try {
      final term = _search.text.trim().toLowerCase();
      return [
        for (final room
            in _spaces?.addableRooms(widget.spaceId) ??
                const <SpaceRoomCandidate>[])
          if (!_added.contains(room.id) &&
              (term.isEmpty ||
                  room.name.toLowerCase().contains(term) ||
                  (room.alias?.toLowerCase().contains(term) ?? false)))
            room,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _add() async {
    final spaces = _spaces;
    if (spaces == null || _selected.isEmpty || _busy || !_owner.isCurrent) {
      return;
    }
    final ids = _selected.toList();
    setState(() => _busy = true);
    List<String> failed;
    try {
      failed = await spaces.addChildren(
        widget.spaceId,
        ids,
        suggested: _suggested,
      );
    } catch (_) {
      failed = ids;
    }
    if (!mounted || !_owner.isCurrent) return;
    final added = ids.where((id) => !failed.contains(id)).toList();
    setState(() {
      _busy = false;
      _added.addAll(added);
      _selected.removeAll(added);
    });
    if (failed.isEmpty) {
      Navigator.pop(context, _added.length);
      return;
    }
    showAdminMessage(
      context,
      failed.length == 1
          ? 'Couldn’t add 1 room. Check your permissions and try again.'
          : 'Couldn’t add ${failed.length} rooms. Check your permissions and '
                'try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final candidates = _candidates();
        final count = _selected.length;
        return AdminPage(
          palette: p,
          title: 'Add rooms',
          busy: _busy,
          actions: [
            if (widget.skippable)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.pop(context, _added.length),
                child: const Text('Skip'),
              ),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: TextField(
                  controller: _search,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search rooms',
                  ),
                ),
              ),
              Expanded(
                child: candidates.isEmpty
                    ? AdminPlaceholder(
                        palette: p,
                        icon: Icons.meeting_room_outlined,
                        title: _search.text.trim().isEmpty
                            ? 'No rooms to add'
                            : 'No rooms found',
                        message: _search.text.trim().isEmpty
                            ? 'Rooms you’ve joined that aren’t in this space '
                                  'yet appear here. Direct chats and spaces '
                                  'can’t be added.'
                            : null,
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          AdminSection(
                            palette: p,
                            footer:
                                'Adding a room will not affect the room '
                                'access. To change the access go to Room info '
                                '› Security & privacy.',
                            children: [
                              for (final room in candidates)
                                CheckboxListTile(
                                  value: _selected.contains(room.id),
                                  onChanged: _busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value == true) {
                                            _selected.add(room.id);
                                          } else {
                                            _selected.remove(room.id);
                                          }
                                        }),
                                  secondary: RoomAvatar(
                                    room: ChatRoom(
                                      id: room.id,
                                      name: room.name,
                                      preview: '',
                                      lastActivity: null,
                                      avatarUrl: room.avatarUrl,
                                    ),
                                    backend: widget.backend,
                                    palette: p,
                                    size: 40,
                                  ),
                                  title: Text(
                                    room.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    room.alias ??
                                        (room.members == 1
                                            ? '1 member'
                                            : '${room.members} members'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: p.muted),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _suggested,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _suggested = value),
                      title: Text(
                        'Suggest to space members',
                        style: TextStyle(color: p.foreground),
                      ),
                    ),
                    AccentButton(
                      palette: p,
                      icon: Icons.playlist_add_rounded,
                      label: count == 0
                          ? 'Add'
                          : count == 1
                          ? 'Add 1 room'
                          : 'Add $count rooms',
                      onPressed: count == 0 || _busy ? null : _add,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
