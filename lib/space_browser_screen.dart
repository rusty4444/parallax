import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'features/home/home_features.dart';
import 'features/threads/thread_widgets.dart' show paletteFromTheme;
import 'features/spaces_admin/manage_space_screen.dart';
import 'features/spaces_admin/space_options_sheet.dart';
import 'features/spaces_admin/spaces_admin_features.dart';
import 'messaging_features.dart';
import 'room_details_screen.dart';
import 'room_join_dialog.dart';

/// Browse joined Spaces, or direct children of [spaceId]. A selected/joined chat
/// room ID is propagated through every nested browser back to the caller.
///
/// With Space administration available, the root offers "New space" and a
/// joined Space offers "Manage rooms", "Space settings" and Element X
/// LeaveSpace (choose which rooms to leave too).
class SpaceBrowserScreen extends StatefulWidget {
  const SpaceBrowserScreen({
    super.key,
    required this.backend,
    this.spaceId,
    this.ancestors = const {},
    this.palette,
  });
  final ChatBackend backend;
  final String? spaceId;
  final Set<String> ancestors;

  /// Palette for the Space administration screens; defaults to the theme's.
  final AppPalette? palette;

  @override
  State<SpaceBrowserScreen> createState() => _SpaceBrowserScreenState();
}

class _SpaceBrowserScreenState extends State<SpaceBrowserScreen> {
  int _generation = 0;
  int _joinGeneration = 0;
  bool _loading = false;
  bool _paging = false;
  bool _expired = false;
  String? _account;
  String? _userId;
  String? _error;
  String? _nextBatch;
  String? _joining;
  List<SpaceSummary> _rooms = const [];

  MessagingFeatures? get _features => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };
  bool get _spacesAdmin => spacesAdminFeaturesOf(widget.backend) != null;
  AppPalette get _palette => paletteFromTheme(context, widget.palette);
  bool get _ownerCurrent =>
      !_expired &&
      _account == _features?.accountKey &&
      _userId == widget.backend.userId;
  bool _current(int generation) =>
      mounted && _ownerCurrent && generation == _generation;

  @override
  void initState() {
    super.initState();
    _bind();
    unawaited(_refresh(afterFrame: true));
  }

  void _bind() {
    _account = _features?.accountKey;
    _userId = widget.backend.userId;
    widget.backend.addListener(_changed);
  }

  void _changed() {
    if (_expired) return;
    if (!_ownerCurrent) {
      _generation++;
      _joinGeneration++;
      setState(() {
        _expired = true;
        _rooms = const [];
        _loading = _paging = false;
        _joining = _nextBatch = _error = null;
      });
    } else if (widget.spaceId == null && !_loading) {
      setState(() => _rooms = _features?.spaces ?? const []);
    }
  }

  @override
  void didUpdateWidget(covariant SpaceBrowserScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend &&
        oldWidget.spaceId == widget.spaceId) {
      return;
    }
    oldWidget.backend.removeListener(_changed);
    _generation++;
    _joinGeneration++;
    _expired = false;
    _rooms = const [];
    _joining = null;
    _bind();
    unawaited(_refresh(afterFrame: true));
  }

  Future<void> _refresh({bool afterFrame = false}) async {
    final owner = widget;
    final features = _features;
    if (!mounted || !_ownerCurrent || features == null) return;
    final generation = ++_generation;
    final account = _account;
    final userId = _userId;
    bool current() =>
        _current(generation) &&
        identical(widget.backend, owner.backend) &&
        widget.spaceId == owner.spaceId &&
        features.accountKey == account &&
        owner.backend.userId == userId;

    // Reserve ownership and show loading before the first build. Only the
    // backend call is deferred: it may synchronously notify other routes.
    setState(() {
      _loading = true;
      _paging = false;
      _error = null;
      _nextBatch = null;
      _rooms = const [];
    });
    if (afterFrame) await WidgetsBinding.instance.endOfFrame;
    // Dispose, rebind, account changes and newer refreshes also cancel starts
    // that have not reached the backend yet.
    if (!current()) return;
    try {
      final List<SpaceSummary> rooms;
      String? nextBatch;
      if (owner.spaceId == null) {
        await owner.backend.refreshRooms();
        if (!current()) return;
        rooms = features.spaces;
      } else {
        final page = await features.loadSpace(owner.spaceId!);
        if (!current()) return;
        rooms = page.rooms;
        nextBatch = page.nextBatch;
      }
      if (!current()) return;
      setState(() {
        _rooms = rooms;
        _nextBatch = nextBatch;
      });
    } catch (_) {
      if (current()) {
        setState(() => _error = 'Couldn’t load this Space. Try again.');
      }
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    final spaceId = widget.spaceId;
    if (!_ownerCurrent ||
        _loading ||
        _paging ||
        token == null ||
        spaceId == null) {
      return;
    }
    final generation = _generation;
    setState(() {
      _paging = true;
      _error = null;
    });
    try {
      final page = await _features!.loadSpace(spaceId, nextBatch: token);
      if (!_current(generation)) return;
      setState(() {
        final rooms = {for (final room in _rooms) room.id: room};
        for (final room in page.rooms) {
          rooms[room.id] = room;
        }
        _rooms = rooms.values.toList();
        _nextBatch = page.nextBatch == token ? null : page.nextBatch;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = 'Couldn’t load more rooms. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _paging = false);
    }
  }

  Future<void> _openSpace(SpaceSummary space) async {
    if (!_ownerCurrent) return;
    if (space.id == widget.spaceId || widget.ancestors.contains(space.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This Space is already open in the current path.'),
        ),
      );
      return;
    }
    final generation = _joinGeneration;
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => SpaceBrowserScreen(
          backend: widget.backend,
          palette: widget.palette,
          spaceId: space.id,
          ancestors: {
            ...widget.ancestors,
            if (widget.spaceId != null) widget.spaceId!,
          },
        ),
      ),
    );
    if (mounted &&
        _ownerCurrent &&
        generation == _joinGeneration &&
        id != null) {
      Navigator.pop(context, id);
    }
  }

  Future<void> _openRoom(SpaceSummary room) async {
    if (!_ownerCurrent || _joining != null) return;
    if (room.joined) {
      Navigator.pop(context, room.id);
      return;
    }
    final generation = ++_joinGeneration;
    setState(() => _joining = room.id);
    try {
      final id = await showRoomJoin(context, widget.backend, room.id);
      if (id != null &&
          mounted &&
          _ownerCurrent &&
          generation == _joinGeneration) {
        Navigator.pop(context, id);
      }
    } catch (_) {
      if (mounted && _ownerCurrent && generation == _joinGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t join this room. Your server may require an invitation.',
            ),
          ),
        );
      }
    } finally {
      if (mounted && _ownerCurrent && generation == _joinGeneration) {
        setState(() => _joining = null);
      }
    }
  }

  bool get _canLeave {
    final spaceId = widget.spaceId;
    if (spaceId == null || _expired) return false;
    try {
      return roomListFeaturesOf(
            widget.backend,
          )?.joinedSpaces.any((space) => space.id == spaceId) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Creates a Space and browses it; a room opened there is returned.
  Future<void> _newSpace() async {
    if (!_ownerCurrent) return;
    final generation = _joinGeneration;
    final spaceId = await openCreateSpace(
      context,
      backend: widget.backend,
      palette: _palette,
    );
    if (spaceId == null ||
        !mounted ||
        !_ownerCurrent ||
        generation != _joinGeneration) {
      return;
    }
    unawaited(_refresh());
    await _openSpace(
      SpaceSummary(id: spaceId, name: 'Space', isSpace: true, joined: true),
    );
  }

  Future<void> _manage(Widget screen) async {
    if (!_ownerCurrent) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted && _ownerCurrent) await _refresh();
  }

  /// The open Space is joined (Space administration or home module).
  bool get _joinedSpace {
    final spaceId = widget.spaceId;
    if (spaceId == null || _expired) return false;
    try {
      if (spacesAdminFeaturesOf(widget.backend)?.isJoinedSpace(spaceId) ??
          false) {
        return true;
      }
    } catch (_) {}
    return _canLeave;
  }

  Future<void> _leave() async {
    final spaceId = widget.spaceId;
    if (spaceId != null && _spacesAdmin && _ownerCurrent) {
      final generation = _joinGeneration;
      final left = await openLeaveSpace(
        context,
        backend: widget.backend,
        palette: _palette,
        spaceId: spaceId,
      );
      if (left && mounted && _ownerCurrent && generation == _joinGeneration) {
        Navigator.pop(context);
      }
      return;
    }
    final features = roomListFeaturesOf(widget.backend);
    if (spaceId == null || features == null || !_ownerCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this Space?'),
        content: const Text(
          'You will leave the Space itself. Rooms you joined through it stay '
          'in your chat list until you leave them too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Leave Space'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_ownerCurrent) return;
    final generation = _joinGeneration;
    try {
      await features.leaveSpace(spaceId);
      if (mounted && _ownerCurrent && generation == _joinGeneration) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted && _ownerCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t leave this Space.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _joinGeneration++;
    widget.backend.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.spaceId == null ? 'Spaces' : 'Browse Space'),
      actions: [
        if (widget.spaceId == null && _spacesAdmin && !_expired)
          IconButton(
            tooltip: 'New space',
            onPressed: _newSpace,
            icon: const Icon(Icons.add_rounded),
          ),
        if (_joinedSpace && _spacesAdmin) ...[
          IconButton(
            tooltip: 'Manage rooms',
            onPressed: () => _manage(
              ManageSpaceScreen(
                backend: widget.backend,
                palette: _palette,
                spaceId: widget.spaceId!,
              ),
            ),
            icon: const Icon(Icons.dashboard_customize_outlined),
          ),
          IconButton(
            tooltip: 'Space settings',
            onPressed: () => _manage(
              RoomDetailsScreen(
                backend: widget.backend,
                palette: _palette,
                roomId: widget.spaceId!,
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
        if (_canLeave || _joinedSpace && _spacesAdmin)
          IconButton(
            tooltip: 'Leave Space',
            onPressed: _leave,
            icon: const Icon(Icons.exit_to_app_rounded),
          ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _expired || _features == null ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: _expired
          ? const Center(child: Text('Account changed. Reopen Spaces.'))
          : _features == null
          ? const Center(
              child: Text('Spaces are unavailable for this account.'),
            )
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          TextButton(
                            onPressed: _rooms.isEmpty ? _refresh : _more,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  if (_rooms.isEmpty && _error == null)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        widget.spaceId == null
                            ? _spacesAdmin
                                  ? 'No joined Spaces yet. Create one, or join a Space from the room directory to browse its rooms.'
                                  : 'No joined Spaces yet. Join a Space from the room directory to browse its rooms.'
                            : 'No accessible rooms in this Space.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final room in _rooms)
                    ListTile(
                      leading: Icon(
                        room.isSpace
                            ? Icons.workspaces_outline
                            : Icons.chat_bubble_outline,
                      ),
                      title: Text(room.name),
                      subtitle: Text(
                        [
                          if (room.topic?.isNotEmpty == true) room.topic!,
                          '${room.members} members',
                          room.id,
                        ].join('\n'),
                      ),
                      onTap: _joining != null
                          ? null
                          : () => room.isSpace
                                ? _openSpace(room)
                                : _openRoom(room),
                      trailing: room.isSpace
                          ? const Icon(Icons.chevron_right)
                          : TextButton(
                              onPressed: _joining != null
                                  ? null
                                  : () => _openRoom(room),
                              child: Text(
                                _joining == room.id
                                    ? 'Joining…'
                                    : room.joined
                                    ? 'Open'
                                    : 'Join',
                              ),
                            ),
                    ),
                  if (_paging)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_nextBatch != null && !_paging)
                    TextButton(
                      onPressed: _more,
                      child: const Text('Load more'),
                    ),
                ],
              ),
            ),
    ),
  );
}
