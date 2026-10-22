import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'chat_backend.dart';
import 'created_room_wait.dart';
import 'directory_screen.dart';
import 'feature_settings_scope.dart';
import 'messaging_features.dart';
import 'space_browser_screen.dart';
import 'user_directory_screen.dart';
import 'message_search_screen.dart';
import 'room_avatar.dart';
import 'room_screen.dart';
import 'room_sync_panel.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.style,
    required this.onThemeChanged,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  MessagingFeatures? get _features => widget.backend is MessagingFeatures
      ? widget.backend as MessagingFeatures
      : null;

  @override
  void dispose() {
    _createdRoomWait?.cancel();
    _owner.release();
    super.dispose();
  }

  bool _favourite(String roomId) {
    try {
      return _features?.isFavourite(roomId) ?? false;
    } catch (_) {
      return false;
    } // A bad room projection cannot hide the inbox.
  }

  String _query = '';
  bool _unreadOnly = false;
  bool _invitesOnly = false;
  String? _pendingRoomAction;
  bool _creatingRoom = false;
  String? _createdRoomId;
  CreatedRoomWait? _createdRoomWait;
  bool _waitingForCreatedRoom = false;

  Future<void> _showInvitation(ChatRoom room) async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join ${room.name}?'),
        content: const Text('You were invited to this Matrix room.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join room'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted || !_owner.isCurrent) return;
    try {
      if (choice) {
        await widget.backend.acceptInvite(room.id);
        if (mounted && _owner.isCurrent) _open(room.id);
      } else {
        await widget.backend.declineInvite(room.id);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError(
          choice
              ? 'Couldn’t join this room.'
              : 'Couldn’t decline this invitation.',
        );
      }
    }
  }

  Future<void> _showRoomActions(ChatRoom room) async {
    if (room.invited || _pendingRoomAction != null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text('Room actions'),
            ),
            ListTile(
              leading: Icon(
                room.manuallyUnread
                    ? Icons.mark_email_read_outlined
                    : Icons.mark_email_unread_outlined,
              ),
              title: Text(
                room.manuallyUnread ? 'Clear manually unread' : 'Mark unread',
              ),
              onTap: () => Navigator.pop(sheetContext, 'unread'),
            ),
            if (_features != null)
              ListTile(
                leading: Icon(
                  _favourite(room.id)
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                ),
                title: Text(
                  _favourite(room.id) ? 'Remove favourite' : 'Add favourite',
                ),
                onTap: () => Navigator.pop(sheetContext, 'favourite'),
              ),
            ListTile(
              leading: const Icon(Icons.exit_to_app_rounded),
              title: const Text('Leave room'),
              onTap: () => Navigator.pop(sheetContext, 'leave'),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        !_owner.isCurrent ||
        choice == null ||
        _pendingRoomAction != null) {
      return;
    }
    if (choice == 'leave') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Leave ${room.name}?'),
          content: const Text(
            'You will no longer see new messages in this room. '
            'You may need another invitation to rejoin.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Leave'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !_owner.isCurrent) return;
    }
    setState(() => _pendingRoomAction = room.id);
    try {
      if (choice == 'leave') {
        await widget.backend.leaveRoom(room.id);
      } else if (choice == 'favourite') {
        await _features!.setFavourite(room.id, !_favourite(room.id));
      } else {
        await widget.backend.setRoomUnread(room.id, !room.manuallyUnread);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError(
          choice == 'leave'
              ? 'Couldn’t leave this room.'
              : 'Couldn’t update this room’s unread status.',
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingRoomAction = null);
      }
    }
  }

  Future<void> _findPeople() async {
    if (!mounted || !_owner.isCurrent || _features == null) return;
    final userId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => UserDirectoryScreen(backend: widget.backend),
      ),
    );
    if (!mounted || !_owner.isCurrent || userId == null || userId.isEmpty) {
      return;
    }
    try {
      await widget.backend.createDirectChat(userId);
      if (!mounted || !_owner.isCurrent) return;
      final roomId = widget.backend.activeRoomId;
      if (roomId != null) _open(roomId);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError('Couldn’t start this conversation. Try again.');
      }
    }
  }

  Future<void> _browseSpaces() async {
    if (!mounted || !_owner.isCurrent || _features == null) return;
    final joinedRoomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SpaceBrowserScreen(backend: widget.backend),
      ),
    );
    if (mounted && _owner.isCurrent && joinedRoomId != null) {
      _open(joinedRoomId);
    }
  }

  Future<void> _newConversation() async {
    if (!mounted || !_owner.isCurrent) return;
    if (_features != null) return _findPeople();
    final controller = TextEditingController();
    try {
      final userId = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('New conversation'),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: '@someone:example.org',
              labelText: 'Matrix user ID',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Start chat'),
            ),
          ],
        ),
      );
      if (!mounted || !_owner.isCurrent || userId == null || userId.isEmpty) {
        return;
      }
      if (!RegExp(r'^@[^:\s]+:[^:\s]+$').hasMatch(userId)) {
        _showError('Enter a full Matrix user ID, like @alex:example.org.');
        return;
      }
      await widget.backend.createDirectChat(userId);
      if (!mounted || !_owner.isCurrent) return;
      final roomId = widget.backend.activeRoomId;
      if (roomId != null) _open(roomId);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError('Couldn’t start this conversation. Try again.');
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _createRoom() async {
    if (_creatingRoom || _createdRoomId != null || !_owner.isCurrent) return;
    setState(() => _creatingRoom = true);
    try {
      final choice = await showDialog<(String, bool)>(
        context: context,
        builder: (_) => const _CreateRoomDialog(),
      );
      if (!mounted || !_owner.isCurrent || choice == null) return;
      final roomId = await widget.backend.createRoom(
        choice.$1,
        encrypted: choice.$2,
      );
      if (!mounted || !_owner.isCurrent) return;
      setState(() => _createdRoomId = roomId);
      await _openCreatedRoom();
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError(
          'Room creation was not confirmed. Check the inbox before trying again.',
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _creatingRoom = false);
    }
  }

  Future<void> _openCreatedRoom() async {
    final roomId = _createdRoomId;
    if (roomId == null || _waitingForCreatedRoom || !_owner.isCurrent) return;
    setState(() => _waitingForCreatedRoom = true);
    final wait = CreatedRoomWait(
      backend: widget.backend,
      roomId: roomId,
      isCurrent: () => mounted && _owner.isCurrent,
    );
    _createdRoomWait = wait;
    try {
      final ready = await wait.result;
      if (!mounted || !_owner.isCurrent) return;
      if (ready) {
        setState(() => _createdRoomId = null);
        _open(roomId);
      } else {
        _showError(
          'Room created. Sync is not ready yet; check the created room again.',
        );
      }
    } finally {
      wait.cancel();
      _createdRoomWait = null;
      if (mounted && _owner.isCurrent) {
        setState(() => _waitingForCreatedRoom = false);
      }
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  void _open(String id) {
    if (!mounted || !_owner.isCurrent) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoomScreen(
          backend: widget.backend,
          palette: widget.palette,
          roomId: id,
        ),
      ),
    );
  }

  Future<void> _explore() async {
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            DirectoryScreen(backend: widget.backend, palette: widget.palette),
      ),
    );
    if (mounted && _owner.isCurrent && roomId != null) _open(roomId);
  }

  Future<void> _searchMessages() async {
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => MessageSearchScreen(
          backend: widget.backend,
          palette: widget.palette,
        ),
      ),
    );
    if (mounted && _owner.isCurrent && roomId != null) _open(roomId);
  }

  String _time(DateTime? value) {
    if (value == null) return '';
    final now = DateTime.now();
    final local = value.toLocal();
    if (now.year == local.year &&
        now.month == local.month &&
        now.day == local.day) {
      return TimeOfDay.fromDateTime(local).format(context);
    }
    return '${local.day}/${local.month}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final compact =
        FeatureSettingsScope.maybeOf(context)?.preferences.compact ?? false;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final roomCountLabel = widget.backend.rooms.isNotEmpty
            ? '${widget.backend.rooms.length} ROOMS'
            : switch (widget.backend.roomSyncState) {
                RoomSyncState.loading => 'SYNCING',
                RoomSyncState.error => 'SYNC ERROR',
                RoomSyncState.ready => '0 ROOMS',
              };
        final failedRooms =
            _features?.pendingSends
                .where((item) => item.state == DeliveryState.failed)
                .map((item) => item.roomId)
                .toSet() ??
            <String>{};
        final favourites = {
          for (final room in widget.backend.rooms) room.id: _favourite(room.id),
        };
        final originalOrder = {
          for (final (index, room) in widget.backend.rooms.indexed)
            room.id: index,
        };
        final rooms = widget.backend.rooms
            .where(
              (room) =>
                  (!_unreadOnly ||
                      room.invited ||
                      room.unread > 0 ||
                      room.manuallyUnread ||
                      failedRooms.contains(room.id)) &&
                  (!_invitesOnly || room.invited) &&
                  (room.name.toLowerCase().contains(_query.toLowerCase()) ||
                      room.id.toLowerCase().contains(_query.toLowerCase())),
            )
            .toList();
        if (_features != null) {
          rooms.sort((a, b) {
            if (a.invited != b.invited) return a.invited ? -1 : 1;
            final af = favourites[a.id] ?? false;
            final bf = favourites[b.id] ?? false;
            if (af != bf) return af ? -1 : 1;
            return originalOrder[a.id]!.compareTo(originalOrder[b.id]!);
          });
        }
        return Scaffold(
          body: GlowBackdrop(
            palette: p,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 22, 16, 0),
                    child: Row(
                      children: [
                        BrandMark(palette: p, size: 46),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'MatriXpress',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontSize: 23,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.1,
                                ),
                              ),
                              Text(
                                'YOUR SPACE TO CONNECT',
                                style: TextStyle(
                                  color: p.secondary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.7,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Explore public rooms',
                          onPressed: _explore,
                          icon: const Icon(Icons.travel_explore_rounded),
                        ),
                        IconButton(
                          tooltip: 'Create room',
                          onPressed: _creatingRoom || _createdRoomId != null
                              ? null
                              : _createRoom,
                          icon: const Icon(Icons.add_home_work_outlined),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          iconSize: 25,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SettingsScreen(
                                backend: widget.backend,
                                palette: p,
                                style: widget.style,
                                onThemeChanged: widget.onThemeChanged,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(24, compact ? 12 : 30, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow('The good stuff', palette: p),
                        if (_createdRoomId != null && _owner.isCurrent)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              _waitingForCreatedRoom
                                  ? 'Waiting for room sync…'
                                  : 'Room created',
                            ),
                            subtitle: SelectableText(_createdRoomId!),
                            trailing: TextButton(
                              onPressed: _waitingForCreatedRoom
                                  ? null
                                  : _openCreatedRoom,
                              child: const Text('Open created room'),
                            ),
                          ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Messages',
                                style: TextStyle(
                                  fontSize: 37,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1.7,
                                  color: p.foreground,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: p.secondary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(40),
                              ),
                              child: Text(
                                roomCountLabel,
                                style: TextStyle(
                                  color: p.secondary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 19),
                        TextField(
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            hintText: 'Find a conversation',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: IconButton(
                              tooltip: 'Search messages',
                              onPressed: _searchMessages,
                              icon: const Icon(Icons.manage_search_rounded),
                            ),
                          ),
                        ),
                        if (_features != null)
                          Wrap(
                            spacing: 12,
                            children: [
                              TextButton.icon(
                                onPressed: _findPeople,
                                icon: const Icon(Icons.person_search_outlined),
                                label: const Text('Find people'),
                              ),
                              TextButton.icon(
                                onPressed: _browseSpaces,
                                icon: const Icon(Icons.hub_outlined),
                                label: const Text('Spaces'),
                              ),
                            ],
                          ),
                        const SizedBox(height: 17),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _FilterChip(
                                label: 'All chats',
                                selected: !_unreadOnly && !_invitesOnly,
                                palette: p,
                                onTap: () => setState(() {
                                  _unreadOnly = false;
                                  _invitesOnly = false;
                                }),
                              ),
                              const SizedBox(width: 9),
                              _FilterChip(
                                label: 'Unread',
                                selected: _unreadOnly,
                                palette: p,
                                onTap: () => setState(() {
                                  _unreadOnly = true;
                                  _invitesOnly = false;
                                }),
                              ),
                              const SizedBox(width: 9),
                              _FilterChip(
                                label: 'Invites',
                                selected: _invitesOnly,
                                palette: p,
                                onTap: () => setState(() {
                                  _invitesOnly = true;
                                  _unreadOnly = false;
                                }),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
                  ),
                  Expanded(
                    child:
                        widget.backend.rooms.isEmpty &&
                            widget.backend.roomSyncState != RoomSyncState.ready
                        ? RoomSyncPanel(backend: widget.backend, palette: p)
                        : rooms.isEmpty
                        ? LayoutBuilder(
                            builder: (context, viewport) => SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: viewport.maxHeight,
                                ),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(35),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _query.isNotEmpty
                                              ? Icons.search_off_rounded
                                              : Icons.forum_outlined,
                                          size: 50,
                                          color: p.secondary,
                                        ),
                                        const SizedBox(height: 14),
                                        Text(
                                          _query.isNotEmpty
                                              ? 'No matches yet'
                                              : _invitesOnly
                                              ? 'No invitations'
                                              : _unreadOnly
                                              ? 'All caught up'
                                              : 'No rooms found',
                                          style: TextStyle(
                                            color: p.foreground,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          _query.isNotEmpty
                                              ? 'Try another search.'
                                              : _invitesOnly
                                              ? 'Invitations will appear here.'
                                              : _unreadOnly
                                              ? 'No unread rooms right now.'
                                              : 'Synced as ${widget.backend.userId ?? 'this account'}. '
                                                    'No joined rooms or invitations were returned.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: p.muted,
                                            height: 1.4,
                                          ),
                                        ),
                                        if (_query.isEmpty &&
                                            !_invitesOnly &&
                                            !_unreadOnly) ...[
                                          const SizedBox(height: 18),
                                          OutlinedButton.icon(
                                            onPressed: () =>
                                                widget.backend.refreshRooms(),
                                            icon: const Icon(
                                              Icons.refresh_rounded,
                                            ),
                                            label: const Text('Refresh rooms'),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                            itemCount: rooms.length,
                            itemBuilder: (context, index) {
                              final room = rooms[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Material(
                                  color: p.surface,
                                  borderRadius: BorderRadius.circular(20),
                                  child: InkWell(
                                    onTap: room.invited
                                        ? () => _showInvitation(room)
                                        : () => _open(room.id),
                                    onLongPress: room.invited
                                        ? null
                                        : () => _showRoomActions(room),
                                    borderRadius: BorderRadius.circular(20),
                                    child: Padding(
                                      padding: EdgeInsets.all(compact ? 9 : 14),
                                      child: Row(
                                        children: [
                                          RoomAvatar(
                                            room: room,
                                            backend: widget.backend,
                                            palette: p,
                                          ),
                                          const SizedBox(width: 13),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        room.name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: p.foreground,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                    ),
                                                    if (favourites[room.id] ==
                                                        true)
                                                      Icon(
                                                        Icons.star_rounded,
                                                        size: 16,
                                                        color: p.accent,
                                                      ),
                                                    if (failedRooms.contains(
                                                      room.id,
                                                    ))
                                                      Tooltip(
                                                        message:
                                                            'Message not sent',
                                                        child: Icon(
                                                          Icons.error_outline,
                                                          size: 16,
                                                          color: p.accent,
                                                        ),
                                                      ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      _time(room.lastActivity),
                                                      style: TextStyle(
                                                        color: p.muted,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 5),
                                                Row(
                                                  children: [
                                                    if (room.encrypted) ...[
                                                      Icon(
                                                        Icons.lock_outline,
                                                        size: 13,
                                                        color: p.secondary,
                                                      ),
                                                      const SizedBox(width: 4),
                                                    ],
                                                    Expanded(
                                                      child: Text(
                                                        room.invited
                                                            ? 'Invited to join'
                                                            : room
                                                                  .preview
                                                                  .isEmpty
                                                            ? 'No messages yet'
                                                            : room.preview,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: p.muted,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ),
                                                    if (room.invited) ...[
                                                      const SizedBox(width: 8),
                                                      Text(
                                                        'INVITE',
                                                        style: TextStyle(
                                                          color: p.secondary,
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                      ),
                                                    ] else if (room.unread >
                                                            0 ||
                                                        room.manuallyUnread) ...[
                                                      const SizedBox(width: 8),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 7,
                                                              vertical: 3,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: p.accent,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                11,
                                                              ),
                                                        ),
                                                        child: Text(
                                                          room.unread == 0
                                                              ? '•'
                                                              : room.unread > 99
                                                              ? '99+'
                                                              : '${room.unread}',
                                                          style: TextStyle(
                                                            color: p.accentOn,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton:
              widget.backend.rooms.isEmpty &&
                  widget.backend.roomSyncState != RoomSyncState.ready
              ? null
              : FloatingActionButton.extended(
                  tooltip: 'New conversation',
                  onPressed: _newConversation,
                  backgroundColor: p.accent,
                  foregroundColor: p.accentOn,
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text(
                    'New chat',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
        );
      },
    );
  }
}

class _CreateRoomDialog extends StatefulWidget {
  const _CreateRoomDialog();

  @override
  State<_CreateRoomDialog> createState() => _CreateRoomDialogState();
}

class _CreateRoomDialogState extends State<_CreateRoomDialog> {
  String _name = '';
  bool _encrypted = true;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create room'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            autofocus: true,
            maxLength: 255,
            onChanged: (value) => setState(() => _name = value),
            decoration: const InputDecoration(labelText: 'Room name'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Encrypted room'),
            subtitle: Text(
              _encrypted
                  ? 'Private room. Encryption cannot be disabled later.'
                  : 'Private room without end-to-end encryption.',
            ),
            value: _encrypted,
            onChanged: (value) => setState(() => _encrypted = value),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _name.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (_name.trim(), _encrypted)),
        child: const Text('Create'),
      ),
    ],
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    onPressed: onTap,
    label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    backgroundColor: selected ? palette.accent : palette.surface,
    labelStyle: TextStyle(
      color: selected ? palette.accentOn : palette.foreground,
    ),
    side: BorderSide(color: selected ? palette.accent : palette.stroke),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}
