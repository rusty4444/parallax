import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'created_room_wait.dart';
import 'features/home/home_features.dart';
import 'features/home/room_list_filters.dart';
import 'features/home/room_list_menu.dart';
import 'features/home/room_list_tile.dart';
import 'features/home/space_switcher.dart';
import 'features/rooms_admin/rooms_admin_hooks.dart';
import 'features/saved/folder_tabs.dart';
import 'features/saved/note_to_self.dart';
import 'features/saved/saved_features.dart';
import 'features/saved/saved_messages_screen.dart';
import 'features/saved/saved_models.dart';
import 'room_creation_request.dart';
import 'directory_screen.dart';
import 'feature_settings_scope.dart';
import 'messaging_features.dart';
import 'space_browser_screen.dart';
import 'user_directory_screen.dart';
import 'message_search_screen.dart';
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
    this.followSystemTheme = false,
    this.onFollowSystemTheme,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;

  /// Theme follows the platform's light/dark setting ("Match system").
  final bool followSystemTheme;
  final ValueChanged<bool>? onFollowSystemTheme;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _creation = RoomCreationRequest.forBackend(widget.backend);

  @override
  void initState() {
    super.initState();
    _creation.addListener(_creationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _creationChanged());
  }

  void _creationChanged() {
    if (!mounted || !_owner.isCurrent) return;
    setState(() {});
    if (_createdRoomId != null && ModalRoute.of(context)?.isCurrent == true) {
      _openCreatedRoom();
    }
  }

  MessagingFeatures? get _features => widget.backend is MessagingFeatures
      ? widget.backend as MessagingFeatures
      : null;

  RoomListFeatures? get _roomList => roomListFeaturesOf(widget.backend);

  /// Note to self, saved messages and chat folders (saved module).
  late final SavedFeatures? _saved = savedFeaturesOf(widget.backend);
  late final Listenable _changes = Listenable.merge([
    widget.backend,
    if (_saved != null && !identical(_saved, widget.backend)) _saved,
  ]);

  @override
  void dispose() {
    _createdRoomWait?.cancel();
    _creation.detach(_creationChanged);
    _owner.release();
    super.dispose();
  }

  bool _favourite(ChatRoom room) {
    final features = _features;
    // The live tag state is newer than the projection after a local change.
    if (features == null) return room.favourite;
    try {
      return features.isFavourite(room.id);
    } catch (_) {
      return room.favourite;
    } // A bad room projection cannot hide the inbox.
  }

  String _query = '';
  Set<RoomListFilter> _filters = const {};
  String? _spaceId;
  String? _folderId;
  bool _openingNote = false;
  String? _pendingRoomAction;
  bool _creatingRoom = false;
  String? get _createdRoomId => _creation.roomId;
  CreatedRoomWait? _createdRoomWait;
  bool _waitingForCreatedRoom = false;

  Future<void> _showInvitation(ChatRoom room) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join ${room.name}?'),
        content: const Text('You were invited to this Matrix room.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'block'),
            child: const Text('Decline and block'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'decline'),
            child: const Text('Decline invite'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'join'),
            child: const Text('Join room'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted || !_owner.isCurrent) return;
    if (choice == 'block') {
      // Element X "Decline and block": optionally report, block the
      // inviter, then decline.
      await showDeclineAndBlock(
        context,
        widget.backend,
        widget.palette,
        room.id,
        roomName: room.name,
      );
      return;
    }
    await (choice == 'join'
        ? _acceptInvite(room)
        : _declineInvite(room, confirm: false));
  }

  Future<void> _acceptInvite(ChatRoom room) async {
    if (_pendingRoomAction != null || !_owner.isCurrent) return;
    setState(() => _pendingRoomAction = room.id);
    try {
      await widget.backend.acceptInvite(room.id);
      if (mounted && _owner.isCurrent) _open(room.id);
    } catch (_) {
      if (mounted && _owner.isCurrent) _showError('Couldn’t join this room.');
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingRoomAction = null);
      }
    }
  }

  Future<void> _declineInvite(ChatRoom room, {bool confirm = true}) async {
    if (_pendingRoomAction != null || !_owner.isCurrent) return;
    if (confirm) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Decline invite to ${room.name}?'),
          content: const Text(
            'You won’t be able to join unless you are invited again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Decline invite'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !_owner.isCurrent) return;
    }
    setState(() => _pendingRoomAction = room.id);
    try {
      await widget.backend.declineInvite(room.id);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError('Couldn’t decline this invitation.');
      }
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingRoomAction = null);
      }
    }
  }

  Future<void> _showRoomActions(ChatRoom room) async {
    if (room.invited || _pendingRoomAction != null) return;
    final roomList = _roomList;
    final favourite = _favourite(room);
    final choice = await showRoomListMenu(
      context,
      room: room,
      favourite: favourite,
      capabilities: RoomMenuCapabilities(
        favourites: roomList != null || _features != null,
        tags: roomList != null,
        notifications: roomList != null,
        folders: _saved != null,
      ),
    );
    if (!mounted ||
        !_owner.isCurrent ||
        choice == null ||
        _pendingRoomAction != null) {
      return;
    }
    if (choice == RoomMenuAction.addToFolder) {
      final saved = _saved;
      if (saved == null) return;
      await showAddToFolderSheet(
        context,
        backend: widget.backend,
        palette: widget.palette,
        features: saved,
        room: room,
        facts: _facts(room, {if (favourite) room.id}, _failedRooms()),
      );
      return;
    }
    if (choice == RoomMenuAction.copyLink) {
      try {
        final link =
            roomList?.roomLink(room.id) ??
            matrixToRoomLink(room.canonicalAlias ?? room.id);
        await Clipboard.setData(ClipboardData(text: link));
        if (mounted && _owner.isCurrent) _showError('Room link copied');
      } catch (_) {
        if (mounted && _owner.isCurrent) _showError('Couldn’t copy the link.');
      }
      return;
    }
    if (choice == RoomMenuAction.leave &&
        (!await confirmLeaveRoom(context, room) ||
            !mounted ||
            !_owner.isCurrent)) {
      return;
    }
    setState(() => _pendingRoomAction = room.id);
    try {
      switch (choice) {
        case RoomMenuAction.leave:
          await widget.backend.leaveRoom(room.id);
        case RoomMenuAction.favourite:
          if (roomList != null) {
            await roomList.setFavourite(room.id, !favourite);
          } else {
            await _features!.setFavourite(room.id, !favourite);
          }
        case RoomMenuAction.lowPriority:
          await roomList!.setLowPriority(room.id, !room.lowPriority);
        case RoomMenuAction.mute || RoomMenuAction.unmute:
          await roomList!.setRoomMuted(room.id, choice == RoomMenuAction.mute);
        case RoomMenuAction.markUnread:
          await widget.backend.setRoomUnread(room.id, true);
        case RoomMenuAction.markRead:
          if (room.manuallyUnread) {
            await widget.backend.setRoomUnread(room.id, false);
          }
          if (!mounted || !_owner.isCurrent) return;
          await roomList?.markAsRead(
            room.id,
            publicReceipt:
                FeatureSettingsScope.maybeOf(
                  context,
                )?.preferences.sendReadReceipts ??
                true,
          );
        case RoomMenuAction.copyLink || RoomMenuAction.addToFolder:
          break;
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError(switch (choice) {
          RoomMenuAction.leave => 'Couldn’t leave this room.',
          RoomMenuAction.favourite => 'Couldn’t update favourites.',
          RoomMenuAction.lowPriority => 'Couldn’t update low priority.',
          RoomMenuAction.mute || RoomMenuAction.unmute =>
            'Couldn’t change notifications for this room.',
          _ => 'Couldn’t update this room’s unread status.',
        });
      }
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingRoomAction = null);
      }
    }
  }

  Set<String> _failedRooms() =>
      _features?.pendingSends
          .where((item) => item.state == DeliveryState.failed)
          .map((item) => item.roomId)
          .toSet() ??
      <String>{};

  FolderRoomFacts _facts(
    ChatRoom room,
    Set<String> favourites,
    Set<String> failedRooms,
  ) => (
    favourite: favourites.contains(room.id),
    unread: isRoomUnread(room, RoomListContext(failedRooms: failedRooms)),
  );

  Future<void> _openNoteToSelf() async {
    final saved = _saved;
    if (saved == null || _openingNote || !_owner.isCurrent) return;
    setState(() => _openingNote = true);
    try {
      await openNoteToSelfRoom(
        context,
        backend: widget.backend,
        palette: widget.palette,
        features: saved,
        open: _open,
      );
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _openingNote = false);
    }
  }

  Future<void> _dismissNotePrompt() async {
    final saved = _saved;
    if (saved == null || !_owner.isCurrent) return;
    try {
      await saved.dismissNoteToSelfPrompt();
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError('Couldn’t dismiss this suggestion. Try again.');
      }
    }
  }

  Future<void> _openSaved() async {
    final saved = _saved;
    if (saved == null || !_owner.isCurrent) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SavedMessagesScreen(
          backend: widget.backend,
          palette: widget.palette,
          features: saved,
          onOpenRoom: (_, roomId) => _open(roomId),
        ),
      ),
    );
  }

  Future<void> _newFolder() async {
    final saved = _saved;
    if (saved == null || !_owner.isCurrent) return;
    final id = await openFolderEditor(
      context,
      backend: widget.backend,
      palette: widget.palette,
      features: saved,
    );
    if (id != null && mounted && _owner.isCurrent) {
      setState(() => _folderId = id);
    }
  }

  Future<void> _showFolderOptions(ChatFolder folder) async {
    final saved = _saved;
    if (saved == null || !_owner.isCurrent) return;
    final deleted = await showFolderTabOptions(
      context,
      backend: widget.backend,
      palette: widget.palette,
      features: saved,
      folder: folder,
    );
    if (deleted && mounted && _owner.isCurrent && _folderId == folder.id) {
      setState(() => _folderId = null);
    }
  }

  Future<void> _showSpaceOptions(HomeSpace space) async {
    final roomList = _roomList;
    if (roomList == null || !_owner.isCurrent) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                space.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('Space'),
            ),
            if (_features != null)
              ListTile(
                leading: const Icon(Icons.travel_explore_rounded),
                title: const Text('Explore rooms in this Space'),
                onTap: () => Navigator.pop(sheetContext, 'explore'),
              ),
            ListTile(
              leading: Icon(
                Icons.exit_to_app_rounded,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                'Leave Space',
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, 'leave'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent || choice == null) return;
    if (choice == 'explore') return _browseSpaces(spaceId: space.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Leave ${space.name}?'),
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
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    try {
      await roomList.leaveSpace(space.id);
      if (mounted && _owner.isCurrent) {
        setState(() {
          if (_spaceId == space.id) _spaceId = null;
        });
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) _showError('Couldn’t leave this Space.');
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

  Future<void> _browseSpaces({String? spaceId}) async {
    if (!mounted || !_owner.isCurrent || _features == null) return;
    final joinedRoomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            SpaceBrowserScreen(backend: widget.backend, spaceId: spaceId),
      ),
    );
    if (mounted && _owner.isCurrent && joinedRoomId != null) {
      _open(joinedRoomId);
    }
  }

  Future<void> _newConversation() async {
    if (!mounted || !_owner.isCurrent) return;
    if (startChatAvailable) {
      final roomId = await openStartChat(
        context,
        widget.backend,
        widget.palette,
      );
      if (mounted && _owner.isCurrent && roomId != null) _open(roomId);
      return;
    }
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
    if (_creatingRoom || _creation.active || !_owner.isCurrent) return;
    setState(() => _creatingRoom = true);
    try {
      final choice = await showDialog<(String, bool)>(
        context: context,
        builder: (_) => const _CreateRoomDialog(),
      );
      if (!mounted || !_owner.isCurrent || choice == null) return;
      _creation.start(choice.$1, encrypted: choice.$2);
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
        // A user may have opened settings/another room while sync was pending.
        // Keep the acknowledged ID rather than navigating above that route.
        if (ModalRoute.of(context)?.isCurrent != true) return;
        setState(() => _creation.acknowledgeOpened(roomId));
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

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        backend: widget.backend,
        palette: widget.palette,
        style: widget.style,
        onThemeChanged: widget.onThemeChanged,
        followSystemTheme: widget.followSystemTheme,
        onFollowSystemTheme: widget.onFollowSystemTheme,
      ),
    ),
  );

  List<HomeSpace> _spaces() {
    try {
      return _roomList?.joinedSpaces ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Set<String>? _spaceRooms(String? spaceId) {
    if (spaceId == null) return null;
    try {
      return _roomList?.spaceDescendants(spaceId) ?? const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final settings = FeatureSettingsScope.maybeOf(context)?.preferences;
    final compact = settings?.compact ?? false;
    final hideInviteAvatars = settings?.hideInviteAvatars ?? false;
    return AnimatedBuilder(
      animation: _changes,
      builder: (context, _) {
        final chats = widget.backend.rooms.where((room) => !room.isSpace);
        final chatCount = chats.length;
        final roomCountLabel = chatCount > 0
            ? '$chatCount ROOMS'
            : switch (widget.backend.roomSyncState) {
                RoomSyncState.loading => 'SYNCING',
                RoomSyncState.error => 'SYNC ERROR',
                RoomSyncState.ready => '0 ROOMS',
              };
        final failedRooms = _failedRooms();
        final favourites = {
          for (final room in widget.backend.rooms)
            if (_favourite(room)) room.id,
        };
        final spaces = _spaces();
        final spaceId = spaces.any((space) => space.id == _spaceId)
            ? _spaceId
            : null;
        // Saved module: Note to self is pinned first and counts as a DM;
        // a selected chat folder narrows the list before the filters.
        final saved = _saved;
        final noteId = saved?.noteToSelfRoomId;
        final folderList = saved?.folders.folders ?? const <ChatFolder>[];
        final folder = folderList.where((f) => f.id == _folderId).firstOrNull;
        final allRooms = [
          for (final room in widget.backend.rooms)
            room.id == noteId && !room.invited ? presentNoteToSelf(room) : room,
        ];
        FolderRoomFacts facts(ChatRoom room) =>
            _facts(room, favourites, failedRooms);
        final unreadByFolder = {
          for (final f in folderList)
            f.id: folderUnreadCount(f, allRooms, facts),
        };
        final filtered = filterRoomList(
          folder == null
              ? allRooms
              : [
                  for (final room in allRooms)
                    if (folderContainsRoom(folder, room, facts(room))) room,
                ],
          _filters,
          RoomListContext(
            favourites: favourites,
            failedRooms: failedRooms,
            spaceRooms: _spaceRooms(spaceId),
            query: _query,
          ),
        );
        final rooms = [
          ...filtered.where((room) => room.id == noteId),
          ...filtered.where((room) => room.id != noteId),
        ];
        final showNotePrompt =
            saved != null &&
            noteId == null &&
            !saved.noteToSelfPromptDismissed &&
            _filters.isEmpty &&
            _query.isEmpty &&
            spaceId == null &&
            folder == null &&
            widget.backend.roomSyncState == RoomSyncState.ready;
        final emptyState = folder != null && _filters.isEmpty && spaceId == null
            ? (
                title: 'No chats in this folder yet',
                subtitle:
                    'Long-press a chat and choose Add to folder…, or '
                    'long-press the folder tab to edit it.',
              )
            : roomListEmptyState(_filters, spaceSelected: spaceId != null);
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
                                'Parallax',
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
                          onPressed: _creatingRoom || _creation.active
                              ? null
                              : _createRoom,
                          icon: const Icon(Icons.add_home_work_outlined),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          iconSize: 25,
                          onPressed: _openSettings,
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
                        if (_creation.failure != null && _owner.isCurrent)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Room not created'),
                            subtitle: Text(_creation.failure!.message),
                          ),
                        if (_creation.active &&
                            _createdRoomId == null &&
                            _owner.isCurrent)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              _creation.uncertain
                                  ? 'Room creation not confirmed'
                                  : 'Waiting for room acknowledgement…',
                            ),
                            subtitle: const Text(
                              'The request may already have created a room. '
                              'Check the inbox; no second request will be sent. '
                              'A late acknowledgement will be retained.',
                            ),
                          ),
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
                            if (saved != null)
                              IconButton(
                                tooltip: 'Saved messages',
                                onPressed: _openSaved,
                                icon: Icon(
                                  Icons.bookmarks_outlined,
                                  color: p.secondary,
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
                        if (spaces.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          SpaceSwitcher(
                            spaces: spaces,
                            selected: spaceId,
                            backend: widget.backend,
                            palette: p,
                            onSelected: (id) => setState(() => _spaceId = id),
                            onOptions: _showSpaceOptions,
                          ),
                        ],
                        if (folderList.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          FolderTabs(
                            folders: folderList,
                            selectedId: folder?.id,
                            unreadCounts: unreadByFolder,
                            palette: p,
                            onSelected: (id) => setState(() => _folderId = id),
                            onOptions: _showFolderOptions,
                            onNewFolder: _newFolder,
                          ),
                        ],
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              if (_filters.isNotEmpty) ...[
                                IconButton.filledTonal(
                                  tooltip: 'Clear filters',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      setState(() => _filters = const {}),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                                const SizedBox(width: 6),
                              ],
                              // Element X keeps selected filters first.
                              for (final filter in [
                                ...RoomListFilter.values.where(
                                  _filters.contains,
                                ),
                                ...RoomListFilter.values.where(
                                  (f) => !_filters.contains(f),
                                ),
                              ]) ...[
                                _FilterChip(
                                  label: filter.label,
                                  selected: _filters.contains(filter),
                                  palette: p,
                                  onTap: () => setState(
                                    () => _filters = toggleRoomListFilter(
                                      _filters,
                                      filter,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 9),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                  Expanded(
                    child:
                        chatCount == 0 &&
                            widget.backend.roomSyncState != RoomSyncState.ready
                        ? RoomSyncPanel(backend: widget.backend, palette: p)
                        : rooms.isEmpty
                        ? _EmptyRoomList(
                            palette: p,
                            icon: _query.isNotEmpty
                                ? Icons.search_off_rounded
                                : _filters.contains(RoomListFilter.unread)
                                ? Icons.celebration_outlined
                                : Icons.forum_outlined,
                            title: _query.isNotEmpty
                                ? 'No matches yet'
                                : emptyState?.title ?? 'No rooms found',
                            subtitle: _query.isNotEmpty
                                ? 'Try another search.'
                                : emptyState?.subtitle ??
                                      'Synced as ${widget.backend.userId ?? 'this account'}. '
                                          'No joined rooms or invitations were returned.',
                            action: _query.isEmpty && emptyState == null
                                ? OutlinedButton.icon(
                                    onPressed: () =>
                                        widget.backend.refreshRooms(),
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: const Text('Refresh rooms'),
                                  )
                                : _query.isEmpty && _filters.isNotEmpty
                                ? OutlinedButton.icon(
                                    onPressed: () =>
                                        setState(() => _filters = const {}),
                                    icon: const Icon(Icons.filter_alt_off),
                                    label: const Text('Clear filters'),
                                  )
                                : _query.isEmpty && folder != null
                                ? OutlinedButton.icon(
                                    onPressed: () => _showFolderOptions(folder),
                                    icon: const Icon(Icons.edit_outlined),
                                    label: const Text('Edit folder'),
                                  )
                                : null,
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                            itemCount: rooms.length + (showNotePrompt ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (showNotePrompt) {
                                if (index == 0) {
                                  return StartNoteToSelfRow(
                                    key: const ValueKey('note-to-self-prompt'),
                                    palette: p,
                                    busy: _openingNote,
                                    onStart: _openNoteToSelf,
                                    onDismiss: _dismissNotePrompt,
                                  );
                                }
                                index--;
                              }
                              final room = rooms[index];
                              if (room.id == noteId) {
                                return NoteToSelfTile(
                                  key: ValueKey('room-${room.id}'),
                                  room: room,
                                  palette: p,
                                  compact: compact,
                                  busy: _pendingRoomAction == room.id,
                                  onTap: () => _open(room.id),
                                  onLongPress: () => _showRoomActions(room),
                                );
                              }
                              return RoomListTile(
                                key: ValueKey('room-${room.id}'),
                                room: room,
                                backend: widget.backend,
                                palette: p,
                                compact: compact,
                                favourite: favourites.contains(room.id),
                                failedSend: failedRooms.contains(room.id),
                                hideInviteAvatar: hideInviteAvatars,
                                busy: _pendingRoomAction == room.id,
                                onTap: room.invited
                                    ? () => _showInvitation(room)
                                    : () => _open(room.id),
                                onLongPress: room.invited
                                    ? null
                                    : () => _showRoomActions(room),
                                onAccept: () => _acceptInvite(room),
                                onDecline: () => _declineInvite(room),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          floatingActionButton:
              chatCount == 0 &&
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

class _EmptyRoomList extends StatelessWidget {
  const _EmptyRoomList({
    required this.palette,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final AppPalette palette;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: viewport.maxHeight),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(35),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 50, color: palette.secondary),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.foreground,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.muted, height: 1.4),
                ),
                if (action != null) ...[const SizedBox(height: 18), action!],
              ],
            ),
          ),
        ),
      ),
    ),
  );
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
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: ActionChip(
      onPressed: onTap,
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      backgroundColor: selected ? palette.accent : palette.surface,
      labelStyle: TextStyle(
        color: selected ? palette.accentOn : palette.foreground,
      ),
      side: BorderSide(color: selected ? palette.accent : palette.stroke),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
