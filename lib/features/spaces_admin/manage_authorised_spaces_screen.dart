import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';
import '../rooms_admin/admin_ui.dart';
import 'spaces_admin_models.dart';

/// Element X ManageAuthorizedSpaces: choose which Spaces' members may join
/// a room without an invitation. Pops the selected Space IDs on "Done", or
/// null when cancelled. The caller writes the join rule.
class ManageAuthorisedSpacesScreen extends StatefulWidget {
  const ManageAuthorisedSpacesScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.spaces,
    required this.initial,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final AuthorisedSpaces spaces;
  final List<String> initial;

  @override
  State<ManageAuthorisedSpacesScreen> createState() =>
      _ManageAuthorisedSpacesScreenState();
}

class _ManageAuthorisedSpacesScreenState
    extends State<ManageAuthorisedSpacesScreen> {
  late final _selected = <String>{...widget.initial};

  void _toggle(String id, bool? value) => setState(() {
    if (value == true) {
      _selected.add(id);
    } else {
      _selected.remove(id);
    }
  });

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final spaces = widget.spaces;
    return AdminPage(
      palette: p,
      title: 'Manage spaces',
      backTooltip: 'Cancel',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
            child: Text(
              'Spaces where members can join the room without an invitation.',
              style: TextStyle(color: p.muted),
            ),
          ),
          if (spaces.selectable.isNotEmpty)
            AdminSection(
              palette: p,
              title: 'Your spaces',
              children: [
                for (final space in spaces.selectable)
                  CheckboxListTile(
                    value: _selected.contains(space.id),
                    onChanged: (value) => _toggle(space.id, value),
                    secondary: RoomAvatar(
                      room: ChatRoom(
                        id: space.id,
                        name: space.name,
                        preview: '',
                        lastActivity: null,
                        avatarUrl: space.avatarUrl,
                        isSpace: true,
                      ),
                      backend: widget.backend,
                      palette: p,
                      size: 40,
                    ),
                    title: Text(
                      space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          if (spaces.unknown.isNotEmpty)
            AdminSection(
              palette: p,
              title: 'Other spaces you’re not a member of',
              children: [
                for (final id in spaces.unknown)
                  CheckboxListTile(
                    value: _selected.contains(id),
                    onChanged: (value) => _toggle(id, value),
                    secondary: CircleAvatar(
                      radius: 20,
                      backgroundColor: p.raised,
                      foregroundColor: p.muted,
                      child: const Icon(Icons.workspaces_outline, size: 20),
                    ),
                    title: Text(
                      '(Unknown space)',
                      style: TextStyle(color: p.foreground),
                    ),
                    subtitle: Text(
                      id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted),
                    ),
                  ),
              ],
            ),
          if (spaces.count == 0)
            AdminPlaceholder(
              palette: p,
              icon: Icons.workspaces_outline,
              title: 'No spaces to choose from',
              message:
                  'Add this room to a space you’ve joined, then try again.',
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: AccentButton(
              palette: p,
              icon: Icons.check_rounded,
              label: 'Done',
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, [
                      for (final space in spaces.selectable)
                        if (_selected.contains(space.id)) space.id,
                      for (final id in spaces.unknown)
                        if (_selected.contains(id)) id,
                    ]),
            ),
          ),
        ],
      ),
    );
  }
}
