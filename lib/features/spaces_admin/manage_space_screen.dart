import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import '../../room_details_screen.dart';
import '../rooms_admin/admin_ui.dart';
import 'add_rooms_to_space_screen.dart';
import 'create_space_screen.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

enum _ChildAction { suggest, unsuggest, up, down, remove }

/// The Space's rooms with Element X Space-screen management: add existing
/// rooms, create a room in the Space, mark suggested, reorder and remove.
/// Everything is loaded from fresh server state and re-read after each
/// change; the server makes the final permission decision.
class ManageSpaceScreen extends StatefulWidget {
  const ManageSpaceScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.spaceId,
    this.showSettings = true,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String spaceId;

  /// Offer the Space settings action (off when opened from them).
  final bool showSettings;

  @override
  State<ManageSpaceScreen> createState() => _ManageSpaceScreenState();
}

class _ManageSpaceScreenState extends State<ManageSpaceScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  SpaceGraph? _graph;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  SpacesAdminFeatures? get _spaces => spacesAdminFeaturesOf(widget.backend);
  bool get _current => mounted && _owner.isCurrent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  Future<void> _load() async {
    final spaces = _spaces;
    if (spaces == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final graph = await spaces.loadSpace(widget.spaceId);
      if (_current && generation == _generation) {
        setState(() => _graph = graph);
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _graph = null; // Never keep stale permissions after a failure.
          _error = 'Couldn’t load this space. Check your connection.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _run(String failure, Future<void> Function() action) async {
    if (_busy || _loading) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && _owner.isCurrent) showAdminMessage(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_current) await _load();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<Object?>(builder: (_) => screen));
    if (_current) await _load();
  }

  String get _spaceName {
    final details = _graph?.details;
    if (details != null && details.hasName) return details.name;
    return [
          for (final room in widget.backend.rooms)
            if (room.id == widget.spaceId) room.name,
        ].firstOrNull ??
        'Space';
  }

  Future<void> _childAction(
    SpaceGraph graph,
    SpaceChildEntry child,
    _ChildAction action,
  ) async {
    final spaces = _spaces;
    if (spaces == null) return;
    final index = graph.children.indexOf(child);
    switch (action) {
      case _ChildAction.suggest:
      case _ChildAction.unsuggest:
        await _run(
          'Couldn’t update the suggestion. Try again.',
          () => spaces.setChildSuggested(
            widget.spaceId,
            child.roomId,
            action == _ChildAction.suggest,
          ),
        );
      case _ChildAction.up:
      case _ChildAction.down:
        await _run(
          'Couldn’t move the room. Try again.',
          () => spaces.moveChild(
            widget.spaceId,
            child.roomId,
            action == _ChildAction.up ? index - 1 : index + 1,
          ),
        );
      case _ChildAction.remove:
        final confirmed = await confirmAction(
          context,
          title: 'Remove ${child.label} from $_spaceName?',
          message:
              'Removing a room will not affect the room access. To change '
              'the access go to Room info › Security & privacy.',
          confirm: 'Remove',
          destructive: true,
        );
        if (!confirmed || !_current) return;
        await _run(
          'Couldn’t remove the room. Try again.',
          () => spaces.removeChild(widget.spaceId, child.roomId),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final graph = _graph;
    final idle = !_busy && !_loading;
    return AdminPage(
      palette: p,
      title: _spaceName,
      busy: _loading || _busy,
      actions: [
        if (widget.showSettings && graph != null)
          IconButton(
            tooltip: 'Space settings',
            onPressed: idle
                ? () => _push(
                    RoomDetailsScreen(
                      backend: widget.backend,
                      palette: p,
                      roomId: widget.spaceId,
                    ),
                  )
                : null,
            icon: const Icon(Icons.settings_outlined),
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: idle ? _load : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: _spaces == null
          ? AdminPlaceholder(
              palette: p,
              icon: Icons.workspaces_outline,
              title: 'Spaces are unavailable for this account.',
            )
          : graph == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Space unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                _header(graph),
                if (graph.canEditChildren)
                  AdminSection(
                    palette: p,
                    children: [
                      AdminTile(
                        palette: p,
                        icon: Icons.playlist_add_rounded,
                        title: 'Add existing rooms',
                        onTap: idle
                            ? () => _push(
                                AddRoomsToSpaceScreen(
                                  backend: widget.backend,
                                  palette: p,
                                  spaceId: widget.spaceId,
                                  spaceName: _spaceName,
                                ),
                              )
                            : null,
                      ),
                      AdminTile(
                        palette: p,
                        icon: Icons.add_comment_outlined,
                        title: 'Create a new room',
                        onTap: idle
                            ? () => _push(
                                CreateSpaceScreen(
                                  backend: widget.backend,
                                  palette: p,
                                  parentSpaceId: widget.spaceId,
                                  parentSpaceName: _spaceName,
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                if (graph.children.isEmpty)
                  AdminPlaceholder(
                    palette: p,
                    icon: Icons.meeting_room_outlined,
                    title: graph.canEditChildren
                        ? 'Add your first room'
                        : 'No rooms in this space yet',
                  )
                else
                  AdminSection(
                    palette: p,
                    title: 'Rooms',
                    footer: graph.canEditChildren
                        ? 'Suggested rooms are highlighted to space members. '
                              'Use the menu to reorder or remove rooms.'
                        : 'Only space admins can add, remove or reorder '
                              'rooms.',
                    children: [
                      for (final child in graph.children)
                        _childTile(graph, child, idle),
                    ],
                  ),
              ],
            ),
    );
  }

  Widget _header(SpaceGraph graph) {
    final p = widget.palette;
    final details = graph.details;
    final rooms = graph.children.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          RoomAvatar(
            room: ChatRoom(
              id: widget.spaceId,
              name: _spaceName,
              preview: '',
              lastActivity: null,
              avatarUrl: details.avatarUrl,
              isSpace: true,
            ),
            backend: widget.backend,
            palette: p,
            size: 56,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _spaceName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    details.canonicalAlias ?? widget.spaceId,
                    rooms == 1 ? '1 room' : '$rooms rooms',
                    details.joinedCount == 1
                        ? '1 member'
                        : '${details.joinedCount} members',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _childTile(SpaceGraph graph, SpaceChildEntry child, bool idle) {
    final p = widget.palette;
    final index = graph.children.indexOf(child);
    final last = graph.children.length - 1;
    final subtitle = [
      if (child.suggested) 'Suggested',
      if (child.isSpace) 'Space',
      if (child.members != null)
        child.members == 1 ? '1 member' : '${child.members} members',
      if (!child.joined) 'Not joined',
    ].join(' · ');
    return ListTile(
      key: ValueKey('space-child-${child.roomId}'),
      leading: RoomAvatar(
        room: ChatRoom(
          id: child.roomId,
          name: child.label,
          preview: '',
          lastActivity: null,
          avatarUrl: child.avatarUrl,
          isSpace: child.isSpace,
        ),
        backend: widget.backend,
        palette: p,
        size: 40,
      ),
      title: Text(
        child.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.foreground, fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, style: TextStyle(color: p.muted)),
      trailing: graph.canEditChildren
          ? PopupMenuButton<_ChildAction>(
              tooltip: 'Options for ${child.label}',
              enabled: idle,
              onSelected: (action) => _childAction(graph, child, action),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: child.suggested
                      ? _ChildAction.unsuggest
                      : _ChildAction.suggest,
                  child: Text(
                    child.suggested ? 'Remove suggestion' : 'Mark as suggested',
                  ),
                ),
                if (index > 0)
                  const PopupMenuItem(
                    value: _ChildAction.up,
                    child: Text('Move up'),
                  ),
                if (index < last)
                  const PopupMenuItem(
                    value: _ChildAction.down,
                    child: Text('Move down'),
                  ),
                const PopupMenuItem(
                  value: _ChildAction.remove,
                  child: Text('Remove from space'),
                ),
              ],
            )
          : null,
    );
  }
}
