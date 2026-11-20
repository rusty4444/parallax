import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'appearance_preferences.dart';
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
import 'features/threads/local_message_search.dart';
import 'features/threads/message_index_store.dart';
import 'features/threads/thread_widgets.dart';
import 'features/threads/timeline_navigation.dart';
import 'room_creation_request.dart';
import 'directory_screen.dart';
import 'feature_settings_scope.dart';
import 'messaging_features.dart';
import 'room_picture_sheet.dart';
import 'room_background_store.dart';
import 'space_browser_screen.dart';
import 'user_directory_screen.dart';
import 'message_search_screen.dart';
import 'room_screen.dart';
import 'room_sync_panel.dart';
import 'settings_screen.dart';
import 'two_pane.dart';
import 'widgets.dart';
import 'haptics.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.style,
    required this.onThemeChanged,
    this.followSystemTheme = false,
    this.onFollowSystemTheme,
    this.roomRoutes,
    this.backgroundStore,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;

  /// Theme follows the platform's light/dark setting ("Match system").
  final bool followSystemTheme;
  final ValueChanged<bool>? onFollowSystemTheme;

  /// The root navigator's chat-route tracker. When the window widens
  /// (unfold, rotate), open chat routes are absorbed into the detail pane.
  final RoomRouteObserver? roomRoutes;

  /// Test seam: the detail pane's room background store (the real one needs
  /// path_provider, which widget tests do not answer).
  @visibleForTesting
  final RoomBackgroundStore? backgroundStore;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> with WidgetsBindingObserver {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _creation = RoomCreationRequest.forBackend(widget.backend);

  /// Tablet/foldable detail-pane selection (see two_pane.dart).
  late final _twoPane = TwoPaneController();
  bool _windowSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _twoPane.register(widget.backend);
    _twoPane.addListener(_twoPaneChanged);
    _creation.addListener(_creationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _creationChanged());
    _messageIndex = localMessageSearchOf(widget.backend);
    final index = _messageIndex;
    if (index != null) {
      try {
        index.ensureStarted();
      } catch (_) {}
      unawaited(_loadDeviceSearch(index));
    }
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
  late final _changes = _WhileCurrent(
    Listenable.merge([
      widget.backend,
      if (_saved != null && !identical(_saved, widget.backend)) _saved,
    ]),
    isCurrent: () => _route?.isCurrent ?? true,
  );

  /// The inbox's route. While another screen covers it (an open room), the
  /// inbox ignores backend notifications (every timeline update, up to one
  /// a frame during a burst). Depending on the route rebuilds the inbox
  /// when it is back on top, which catches up.
  ModalRoute<Object?>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageDebounce?.cancel();
    _messageGeneration++;
    _deviceSetup++;
    _changes.dispose();
    _createdRoomWait?.cancel();
    _creation.detach(_creationChanged);
    _twoPane.unregister(widget.backend);
    _twoPane.removeListener(_twoPaneChanged);
    _twoPane.dispose();
    _owner.release();
    _search.dispose();
    super.dispose();
  }

  void _twoPaneChanged() {
    if (mounted && _owner.isCurrent) setState(() {});
  }

  /// A covered inbox is not re-laid out when the window resizes, so the
  /// LayoutBuilder alone misses fold/unfold while a chat route is on top.
  /// Metrics notifications reach every observer regardless.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    _scheduleWindowSync(isTwoPaneWindow(size));
  }

  void _scheduleWindowSync(bool wide) {
    if (wide == _twoPane.wide || _windowSyncScheduled) return;
    _windowSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _windowSyncScheduled = false;
      if (!mounted || !_owner.isCurrent) return;
      // Recompute from the CURRENT metrics: two window-class flips can
      // happen before this callback runs (rapid fold/unfold, split-screen
      // drag), and applying the captured snapshot could persist a phone
      // route on a wide window.
      final view = View.of(context);
      final size = view.physicalSize / view.devicePixelRatio;
      _applyWindowMode(isTwoPaneWindow(size));
    });
  }

  /// Fold/unfold, rotation and split-screen change the window class.
  /// Widening absorbs open chat routes into the detail pane; narrowing
  /// keeps the selected chat on screen by pushing it as a phone route.
  void _applyWindowMode(bool wide) {
    if (wide == _twoPane.wide) return;
    if (wide) {
      final routes = widget.roomRoutes?.rooms ?? const <RoomRoute>[];
      final top = routes.isEmpty ? null : routes.last;
      _twoPane.wide = true;
      if (top != null) {
        final navigator = Navigator.of(context);
        // Remove only chat routes; other screens (settings, media) stay.
        for (final route in routes) {
          navigator.removeRoute(route);
        }
        _twoPane.select(top.roomId);
      }
    } else {
      _twoPane.wide = false;
      final selected = _twoPane.selectedRoomId;
      final chatAlreadyOpen = widget.roomRoutes?.rooms.isNotEmpty ?? false;
      // Mirror the detail pane: a departed room must not push an error
      // screen when the window narrows.
      final stillJoined =
          selected != null &&
          widget.backend.rooms.any((r) => r.id == selected && !r.invited);
      if (selected != null &&
          stillJoined &&
          !chatAlreadyOpen &&
          (_route?.isCurrent ?? true)) {
        Navigator.of(context).push(
          RoomRoute(
            backend: widget.backend,
            palette: widget.palette,
            roomId: selected,
          ),
        );
      }
    }
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
  bool _searchOpen = false;

  // Inline message search. Room/people name filtering above stays
  // synchronous; these results arrive asynchronously (debounced, off the UI
  // thread) and are scoped to the rooms the current Space/folder/filters show.
  LocalMessageSearch? _messageIndex;
  bool _deviceSearch = false;
  int _deviceSetup = 0;
  Timer? _messageDebounce;
  int _messageGeneration = 0;
  List<MessageHit> _messageHits = const [];
  String? _openingMessage;
  Set<String> _messageScopeIds = const {};
  Set<RoomListFilter> _filters = const {};
  String? _spaceId;
  String? _folderId;
  bool _openingNote = false;

  /// Home options menu (Explore rooms, filters, Spaces, folders) is open.
  bool _optionsOpen = false;
  final _search = TextEditingController();
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
    if (choice == RoomMenuAction.chatPicture) {
      await showRoomPictureSheet(context, room: room, palette: widget.palette);
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
        case RoomMenuAction.copyLink ||
            RoomMenuAction.addToFolder ||
            RoomMenuAction.chatPicture:
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
          _spacesRevision++;
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

  /// Copies the one-time code offered on an unread row. The chat stays
  /// unread: nothing was opened.
  Future<void> _copyCode(String code) async {
    Haptics.selection();
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (mounted && _owner.isCurrent) _showError('Code copied');
    } catch (_) {
      if (mounted && _owner.isCurrent) _showError('Couldn’t copy the code.');
    }
  }

  void _open(String id) {
    if (!mounted || !_owner.isCurrent) return;
    unawaited(
      openRoom(
        context,
        backend: widget.backend,
        palette: widget.palette,
        roomId: id,
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
          initialQuery: _query,
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

  final _memos = <Symbol, (Object?, Object?)>{};

  /// Bumped when a Space is left here, before the sync drops it.
  int _spacesRevision = 0;
  Set<String>? _failedSet;
  Set<String>? _favouriteSet;
  Set<String>? _spaceSet;

  static Set<String>? _stableNullableSet(
    Set<String>? next,
    Set<String>? previous,
  ) => next == null ? null : _stableSet(next, previous);

  /// [compute] again only when [key] differs (==) from the last call's.
  T _memo<T>(Symbol slot, Object? key, T Function() compute) {
    final last = _memos[slot];
    if (last != null && last.$1 == key) return last.$2 as T;
    final value = compute();
    _memos[slot] = (key, value);
    return value;
  }

  static Set<String> _stableSet(Set<String> next, Set<String>? previous) =>
      previous != null &&
          previous.length == next.length &&
          previous.containsAll(next)
      ? previous
      : next;

  /// What narrows the room list, for the collapsed options summary.
  List<String> _narrowing(HomeSpace? space, ChatFolder? folder) => [
    if (_query.trim().isNotEmpty) '“${_query.trim()}”',
    if (space != null) space.name,
    if (folder != null) folder.name,
    for (final filter in RoomListFilter.values)
      if (_filters.contains(filter)) filter.label,
  ];

  void _toggleConversationSearch() {
    Haptics.selection();
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        // Never leave an invisible query narrowing the room list.
        _search.clear();
        _query = '';
        _resetMessageSearch();
      }
    });
  }

  void _clearNarrowing() {
    Haptics.selection();
    _search.clear();
    setState(() {
      _query = '';
      _filters = const {};
      _spaceId = null;
      _folderId = null;
      _resetMessageSearch();
    });
  }

  // ---- Inline message search -------------------------------------------

  /// Most message matches shown under the room list before "See all".
  static const _messageResultLimit = 20;

  void _resetMessageSearch() {
    _messageDebounce?.cancel();
    _messageGeneration++;
    _messageHits = const [];
    _openingMessage = null;
  }

  void _onSearchChanged(String value) {
    _messageDebounce?.cancel();
    final query = value.trim();
    final generation = ++_messageGeneration;
    final active = _searchOpen && query.length >= 2;
    setState(() {
      _query = value;
      _messageHits = const [];
      _openingMessage = null;
    });
    if (!active) return;
    // Debounced so a burst of keystrokes costs one search, not one per key.
    _messageDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_runMessageSearch(query, generation));
    });
  }

  Future<void> _loadDeviceSearch(LocalMessageSearch index) async {
    final setup = ++_deviceSetup;
    bool enabled;
    try {
      enabled = await index.isEnabled();
    } catch (_) {
      enabled = false;
    }
    if (!mounted ||
        setup != _deviceSetup ||
        !identical(index, _messageIndex) ||
        !_owner.isCurrent) {
      return;
    }
    if (enabled == _deviceSearch) return;
    setState(() => _deviceSearch = enabled);
    if (_searchOpen && _query.trim().length >= 2) {
      _onSearchChanged(_search.text);
    }
  }

  bool _messageSearchCurrent(int generation) =>
      mounted &&
      generation == _messageGeneration &&
      _searchOpen &&
      _owner.isCurrent;

  Future<void> _runMessageSearch(String query, int generation) async {
    if (!_messageSearchCurrent(generation)) return;
    final index = _messageIndex;
    var localHits = const <MessageHit>[];
    // Encrypted rooms: the on-device index (off the UI thread). Show these
    // as soon as they are ready, without waiting for the server.
    if (_deviceSearch && index != null) {
      try {
        final page = await index.search(query, limit: _messageResultLimit);
        if (!_messageSearchCurrent(generation)) return;
        localHits = page.hits;
        _publishMessageHits(localHits, const []);
      } catch (_) {
        if (!_messageSearchCurrent(generation)) return;
      }
    }
    // Unencrypted rooms: the homeserver. Best-effort — a failure keeps the
    // local matches already shown.
    try {
      final page = await widget.backend.searchMessages(query);
      if (!_messageSearchCurrent(generation)) return;
      _publishMessageHits(localHits, page.hits);
    } catch (_) {}
  }

  void _publishMessageHits(List<MessageHit> local, List<MessageHit> server) {
    final scope = _messageScopeIds;
    final seen = <String>{};
    final combined = <MessageHit>[];
    for (final hit in [...local, ...server]) {
      if (!scope.contains(hit.roomId) || !seen.add(hit.id)) continue;
      combined.add(hit);
    }
    combined.sort((a, b) => b.time.compareTo(a.time));
    setState(() {
      _messageHits = combined.take(_messageResultLimit).toList();
      _openingMessage = null;
    });
  }

  /// Rooms eligible for message search: the same Space/folder/filters as the
  /// list, but ignoring the name query (a message can match in a room whose
  /// name does not).
  Set<String> _computeMessageScope(
    List<ChatRoom> source,
    String? noteId,
    ChatFolder? folder,
    Set<String> favourites,
    Set<String> failedRooms,
    Set<String>? spaceRooms,
  ) {
    final allRooms = [
      for (final room in source)
        room.id == noteId && !room.invited ? presentNoteToSelf(room) : room,
    ];
    FolderRoomFacts facts(ChatRoom room) =>
        _facts(room, favourites, failedRooms);
    final narrowed = folder == null
        ? allRooms
        : [
            for (final room in allRooms)
              if (folderContainsRoom(folder, room, facts(room))) room,
          ];
    final filtered = filterRoomList(
      narrowed,
      _filters,
      RoomListContext(
        favourites: favourites,
        failedRooms: failedRooms,
        spaceRooms: spaceRooms,
      ),
    );
    return {for (final room in filtered) room.id};
  }

  Future<void> _openMessageHit(MessageHit hit) async {
    if (_openingMessage != null || !_owner.isCurrent) return;
    final generation = _messageGeneration;
    final jumpId = hit is LocalMessageHit ? hit.jumpEventId : hit.id;
    final navigation = timelineNavigationOf(widget.backend);
    if (navigation == null || !jumpId.startsWith(r'$')) {
      _open(hit.roomId);
      return;
    }
    setState(() => _openingMessage = hit.id);
    var focused = false;
    try {
      await navigation.openRoomAt(hit.roomId, jumpId);
      focused = true;
    } catch (_) {
      focused = false;
    }
    if (!mounted || generation != _messageGeneration || !_owner.isCurrent) {
      return;
    }
    setState(() => _openingMessage = null);
    if (!focused) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn’t jump to that message. Opening the room instead.',
          ),
        ),
      );
    }
    _open(hit.roomId);
  }

  void _seeAllMessages() {
    Haptics.selection();
    unawaited(_searchMessages());
  }

  Widget _roomTileFor(
    ChatRoom room, {
    required AppPalette p,
    required bool compact,
    required HomeRowStyle rowStyle,
    required HomePreview homePreview,
    required Set<String> favourites,
    required Set<String> failedRooms,
    required bool hideInviteAvatars,
    required String? noteId,
  }) {
    // WhatsApp-style tint on the chat open in the detail pane.
    final selected = _twoPane.wide && room.id == _twoPane.selectedRoomId;
    if (room.id == noteId) {
      return NoteToSelfTile(
        key: ValueKey('room-${room.id}'),
        room: room,
        palette: p,
        compact: compact || rowStyle == HomeRowStyle.compact,
        previewLines: homePreview.maxLines,
        busy: _pendingRoomAction == room.id,
        selected: selected,
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
      selected: selected,
      style: rowStyle,
      preview: homePreview,
      onTap: room.invited ? () => _showInvitation(room) : () => _open(room.id),
      onLongPress: room.invited ? null : () => _showRoomActions(room),
      onAccept: () => _acceptInvite(room),
      onDecline: () => _declineInvite(room),
      onCopyCode: _copyCode,
    );
  }

  /// Search mode: matching rooms first, then message matches from the rooms
  /// the current Space/folder/filters show.
  Widget _searchResultsArea({
    required AppPalette p,
    required List<ChatRoom> rooms,
    required bool compact,
    required HomeRowStyle rowStyle,
    required HomePreview homePreview,
    required Set<String> favourites,
    required Set<String> failedRooms,
    required bool hideInviteAvatars,
    required String? noteId,
  }) {
    if (rooms.isEmpty && _messageHits.isEmpty) {
      return _EmptyRoomList(
        palette: p,
        icon: Icons.search_off_rounded,
        title: 'No matches yet',
        subtitle: 'Try another search.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      children: [
        for (final room in rooms)
          _roomTileFor(
            room,
            p: p,
            compact: compact,
            rowStyle: rowStyle,
            homePreview: homePreview,
            favourites: favourites,
            failedRooms: failedRooms,
            hideInviteAvatars: hideInviteAvatars,
            noteId: noteId,
          ),
        if (_messageHits.isNotEmpty) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Eyebrow('Message matches', palette: p),
          ),
          for (final hit in _messageHits) _messageHitCard(p, hit),
          Center(
            child: TextButton.icon(
              onPressed: _seeAllMessages,
              icon: const Icon(Icons.manage_search_rounded),
              label: const Text('See all message results'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _messageHitCard(AppPalette p, MessageHit hit) {
    final opening = _openingMessage == hit.id;
    final inThread = hit is LocalMessageHit && hit.threadRootId != null;
    return Card(
      key: ValueKey('home-hit-${hit.id}'),
      color: p.surface,
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openMessageHit(hit),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hit.roomName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.secondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    activityLabel(context, hit.time),
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text.rich(
                _highlightedBody(
                  hit.body,
                  TextStyle(color: p.foreground, fontSize: 15),
                  TextStyle(color: p.accent, fontWeight: FontWeight.w700),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      opening ? 'Opening…' : hit.sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                  ),
                  if (inThread)
                    Text(
                      'In a thread',
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [body] with every query word (case-insensitive) emphasised.
  TextSpan _highlightedBody(String body, TextStyle style, TextStyle match) {
    final lower = body.toLowerCase();
    final tokens = searchTokens(_query);
    // Lower-casing must keep offsets aligned for the ranges to be valid.
    if (tokens.isEmpty || lower.length != body.length) {
      return TextSpan(text: body, style: style);
    }
    final marked = List.filled(body.length, false);
    for (final token in tokens) {
      for (var at = lower.indexOf(token); at >= 0;) {
        marked.fillRange(at, at + token.length, true);
        at = lower.indexOf(token, at + token.length);
      }
    }
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = 1; i <= body.length; i++) {
      if (i == body.length || marked[i] != marked[start]) {
        spans.add(
          TextSpan(
            text: body.substring(start, i),
            style: marked[start] ? match : null,
          ),
        );
        start = i;
      }
    }
    return TextSpan(style: style, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = isTwoPaneWindow(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        _scheduleWindowSync(wide);
        final inbox = _buildInbox(context, twoPane: wide);
        if (!wide) return inbox;
        final p = widget.palette;
        final split = twoPaneSplit(
          constraints.maxWidth,
          features: MediaQuery.displayFeaturesOf(context),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: split.listWidth,
              child: MediaQuery.removePadding(
                context: context,
                removeRight: true,
                child: inbox,
              ),
            ),
            // Hairline divider, or the hinge gap on a dual-screen device.
            SizedBox(
              width: split.gapWidth,
              child: ColoredBox(color: p.stroke),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeLeft: true,
                // Re-check the selection when the room list changes: a
                // departed room falls back to the placeholder.
                child: AnimatedBuilder(
                  animation: _changes,
                  builder: (context, _) => _detailPane(context),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The right pane: the selected chat, or a calm placeholder (Messenger /
  /// WhatsApp on tablets). A room that disappeared (left, removed) falls
  /// back to the placeholder instead of an empty timeline.
  Widget _detailPane(BuildContext context) {
    final p = widget.palette;
    final id = _twoPane.selectedRoomId;
    final known =
        id != null && widget.backend.rooms.any((room) => room.id == id);
    if (!known) {
      return GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BrandMark(palette: p, size: 72),
                  const SizedBox(height: 20),
                  Text(
                    'Select a conversation',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose a chat from the list to start reading.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return RoomScreen(
      key: ValueKey('two-pane-$id'),
      backend: widget.backend,
      palette: p,
      roomId: id,
      embedded: true,
      backgroundStore: widget.backgroundStore,
    );
  }

  /// The inbox list itself: the whole screen on phones, the left pane on
  /// tablets and unfolded foldables.
  Widget _buildInbox(BuildContext context, {required bool twoPane}) {
    final p = widget.palette;
    final settings = FeatureSettingsScope.maybeOf(context)?.preferences;
    final compact = settings?.compact ?? false;
    // The tall "Messages" home layout is for the full-screen phone inbox;
    // the list pane keeps its compact header.
    final expandedHome = !twoPane && (settings?.expandedHome ?? false);
    final hideInviteAvatars = settings?.hideInviteAvatars ?? false;
    final rowStyle = settings?.homeRowStyle ?? HomeRowStyle.cards;
    final homePreview = settings?.homePreview ?? HomePreview.long;
    return AnimatedBuilder(
      animation: _changes,
      builder: (context, _) {
        final source = widget.backend.rooms;
        final chatCount = _memo(
          #chatCount,
          source,
          () => source.where((room) => !room.isSpace).length,
        );
        final roomCountLabel = chatCount > 0
            ? '$chatCount ROOMS'
            : switch (widget.backend.roomSyncState) {
                RoomSyncState.loading => 'SYNCING',
                RoomSyncState.error => 'SYNC ERROR',
                RoomSyncState.ready => '0 ROOMS',
              };
        // Reuse equal sets so the memoised list below can compare inputs by
        // identity.
        final failedRooms = _failedSet = _stableSet(_failedRooms(), _failedSet);
        // Live tags for every room (the SDK parses m.tag on each read) and
        // the Spaces (a scan of every room) only change with the room list
        // or after a favourite toggled from the room menu.
        final favourites = _favouriteSet = _memo<Set<String>>(
          #favourites,
          (source, _pendingRoomAction),
          () => _stableSet({
            for (final room in source)
              if (_favourite(room)) room.id,
          }, _favouriteSet),
        );
        final spaces = _memo(#spaces, (source, _spacesRevision), _spaces);
        final spaceId = spaces.any((space) => space.id == _spaceId)
            ? _spaceId
            : null;
        // Saved module: Note to self is pinned first and counts as a DM;
        // a selected chat folder narrows the list before the filters.
        final saved = _saved;
        final noteId = saved?.noteToSelfRoomId;
        final folderList = saved?.folders.folders ?? const <ChatFolder>[];
        final folder = folderList.where((f) => f.id == _folderId).firstOrNull;
        final spaceRooms = _spaceSet = _memo(#spaceRooms, (
          source,
          spaceId,
          _spacesRevision,
        ), () => _stableNullableSet(_spaceRooms(spaceId), _spaceSet));
        // The inbox rebuilds on every backend notification (including each
        // timeline update of a room open above it). Filtering, sorting and
        // folder counts over every room only rerun when an input changed.
        final (:unreadByFolder, :rooms) = _memo(
          #roomList,
          (
            source,
            favourites,
            failedRooms,
            noteId,
            folderList,
            folder,
            _filters,
            _query,
            spaceRooms,
          ),
          () {
            final allRooms = [
              for (final room in source)
                room.id == noteId && !room.invited
                    ? presentNoteToSelf(room)
                    : room,
            ];
            FolderRoomFacts facts(ChatRoom room) =>
                _facts(room, favourites, failedRooms);
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
                spaceRooms: spaceRooms,
                query: _query,
              ),
            );
            return (
              unreadByFolder: {
                for (final f in folderList)
                  f.id: folderUnreadCount(f, allRooms, facts),
              },
              rooms: [
                ...filtered.where((room) => room.id == noteId),
                ...filtered.where((room) => room.id != noteId),
              ],
            );
          },
        );
        // Rooms eligible for message search: the same Space/folder/filters
        // as the list, but ignoring the name query (a message can match in a
        // room whose name does not). Memoised without the query so typing
        // does not re-run it.
        _messageScopeIds = _memo(
          #messageScope,
          (
            source,
            favourites,
            failedRooms,
            noteId,
            folder,
            _filters,
            spaceRooms,
          ),
          () => _computeMessageScope(
            source,
            noteId,
            folder,
            favourites,
            failedRooms,
            spaceRooms,
          ),
        );
        final showNotePrompt =
            saved != null &&
            noteId == null &&
            !saved.noteToSelfPromptDismissed &&
            _filters.isEmpty &&
            _query.isEmpty &&
            spaceId == null &&
            folder == null &&
            widget.backend.roomSyncState == RoomSyncState.ready;
        // A room moving to the top shifts every row above its old place.
        // With each row's index known by key, Flutter moves those rows
        // instead of rebuilding them (and their avatars) from scratch.
        final rowIndex = _memo(
          #rowIndex,
          (rooms, showNotePrompt),
          () => <String, int>{
            if (showNotePrompt) 'note-to-self-prompt': 0,
            for (final (i, room) in rooms.indexed)
              'room-${room.id}': i + (showNotePrompt ? 1 : 0),
          },
        );
        final emptyState = folder != null && _filters.isEmpty && spaceId == null
            ? (
                title: 'No chats in this folder yet',
                subtitle:
                    'Long-press a chat and choose Add to folder…, or '
                    'long-press the folder tab to edit it.',
              )
            : roomListEmptyState(_filters, spaceSelected: spaceId != null);
        final space = spaces.where((s) => s.id == spaceId).firstOrNull;
        final narrowing = _narrowing(space, folder);
        final creationStatus = <Widget>[
          if (_creation.failure != null && _owner.isCurrent)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Room not created'),
              subtitle: Text(_creation.failure!.message),
            ),
          if (_creation.active && _createdRoomId == null && _owner.isCurrent)
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
              // A bounded trailing keeps the title/subtitle from collapsing
              // to zero width in a narrow box (Flutter 3.44 _RenderListTile
              // with an unconstrained trailing). 150dp is safe at the pane
              // floors in two_pane.dart (300dp clamp, 280dp hinge guard);
              // re-check it if those floors ever shrink.
              trailing: SizedBox(
                width: 150,
                child: TextButton(
                  onPressed: _waitingForCreatedRoom ? null : _openCreatedRoom,
                  child: const Text('Open created room'),
                ),
              ),
            ),
        ];
        final savedButton = saved == null
            ? null
            : IconButton(
                tooltip: 'Saved messages',
                onPressed: _openSaved,
                icon: Icon(Icons.bookmarks_outlined, color: p.secondary),
              );
        final roomCountPill = Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
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
        );
        final conversationSearch = TextField(
          key: const ValueKey('home.conversation_search'),
          controller: _search,
          autofocus: true,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: 'Search people, rooms and messages',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              tooltip: 'Search messages',
              onPressed: _searchMessages,
              icon: const Icon(Icons.manage_search_rounded),
            ),
          ),
        );
        final quickLinks = <Widget>[
          TextButton.icon(
            key: const ValueKey('home.explore_rooms'),
            onPressed: _explore,
            icon: const Icon(Icons.travel_explore_rounded),
            label: const Text('Explore rooms'),
          ),
          if (_features != null) ...[
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
        ];
        // Quick links, Space switcher, folders and filters: always shown with
        // "Show all home options", otherwise in the options menu. Conversation
        // search pops in independently from its top-bar button.
        final options = <Widget>[
          if (expandedHome) ...[
            if (quickLinks.isNotEmpty) Wrap(spacing: 12, children: quickLinks),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(child: Wrap(spacing: 4, children: quickLinks)),
                  ?savedButton,
                  const SizedBox(width: 4),
                  roomCountPill,
                ],
              ),
            ),
          if (spaces.isNotEmpty) ...[
            const SizedBox(height: 10),
            SpaceSwitcher(
              spaces: spaces,
              selected: spaceId,
              backend: widget.backend,
              palette: p,
              onSelected: (id) {
                Haptics.selection();
                setState(() => _spaceId = id);
              },
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
              onSelected: (id) {
                Haptics.selection();
                setState(() => _folderId = id);
              },
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
                    onPressed: () => setState(() => _filters = const {}),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const SizedBox(width: 6),
                ],
                // Element X keeps selected filters first.
                for (final filter in [
                  ...RoomListFilter.values.where(_filters.contains),
                  ...RoomListFilter.values.where((f) => !_filters.contains(f)),
                ]) ...[
                  _FilterChip(
                    label: filter.label,
                    selected: _filters.contains(filter),
                    palette: p,
                    onTap: () {
                      Haptics.selection();
                      setState(
                        () => _filters = toggleRoomListFilter(_filters, filter),
                      );
                    },
                  ),
                  const SizedBox(width: 9),
                ],
              ],
            ),
          ),
        ];
        return Scaffold(
          body: GlowBackdrop(
            palette: p,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: twoPane
                        ? const EdgeInsets.fromLTRB(16, 16, 8, 0)
                        : const EdgeInsets.fromLTRB(22, 22, 16, 0),
                    child: Row(
                      children: [
                        if (!twoPane) ...[
                          BrandMark(palette: p, size: 46),
                          const SizedBox(width: 13),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Parallax',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontSize: twoPane ? 20 : 23,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.1,
                                ),
                              ),
                              if (!twoPane)
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
                          key: const ValueKey('home.search_toggle'),
                          tooltip: _searchOpen
                              ? 'Hide conversation search'
                              : 'Search conversations',
                          onPressed: _toggleConversationSearch,
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: Icon(
                              _searchOpen
                                  ? Icons.close_rounded
                                  : Icons.search_rounded,
                              key: ValueKey(_searchOpen),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Create room',
                          onPressed: _creatingRoom || _creation.active
                              ? null
                              : _createRoom,
                          icon: const Icon(Icons.add_home_work_outlined),
                        ),
                        if (!expandedHome)
                          IconButton(
                            key: const ValueKey('home.options'),
                            tooltip: _optionsOpen
                                ? 'Hide options'
                                : 'Show options',
                            onPressed: () {
                              Haptics.selection();
                              setState(() => _optionsOpen = !_optionsOpen);
                            },
                            icon: AnimatedRotation(
                              turns: _optionsOpen ? 0.5 : 0,
                              duration: const Duration(milliseconds: 220),
                              child: const Icon(Icons.expand_more_rounded),
                            ),
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
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _searchOpen
                        ? PopScope<void>(
                            canPop: false,
                            onPopInvokedWithResult: (didPop, _) {
                              if (!didPop) _toggleConversationSearch();
                            },
                            child: Padding(
                              key: const ValueKey('home.search_panel'),
                              padding: EdgeInsets.fromLTRB(
                                24,
                                compact ? 10 : 16,
                                24,
                                0,
                              ),
                              child: conversationSearch,
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  if (expandedHome)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        compact ? 12 : 20,
                        24,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Eyebrow('The good stuff', palette: p),
                          ...creationStatus,
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
                              ?savedButton,
                              roomCountPill,
                            ],
                          ),
                          const SizedBox(height: 19),
                          ...options,
                          const SizedBox(height: 14),
                        ],
                      ),
                    )
                  else ...[
                    if (creationStatus.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                        child: Column(children: creationStatus),
                      ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: _optionsOpen
                          ? Padding(
                              key: const ValueKey('home.options_panel'),
                              padding: EdgeInsets.fromLTRB(
                                24,
                                compact ? 8 : 14,
                                24,
                                12,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: options,
                              ),
                            )
                          : narrowing.isNotEmpty
                          // Collapsed while something narrows the list: say
                          // what, so a short list is never a mystery.
                          ? Padding(
                              key: const ValueKey('home.narrowing'),
                              padding: const EdgeInsets.fromLTRB(24, 8, 12, 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.filter_alt_outlined,
                                    size: 18,
                                    color: p.secondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Showing ${narrowing.join(' · ')}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.muted,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _clearNarrowing,
                                    child: const Text('Clear'),
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox(width: double.infinity, height: 14),
                    ),
                  ],
                  Expanded(
                    child:
                        chatCount == 0 &&
                            widget.backend.roomSyncState != RoomSyncState.ready
                        ? RoomSyncPanel(backend: widget.backend, palette: p)
                        : _searchOpen && _query.trim().isNotEmpty
                        ? _searchResultsArea(
                            p: p,
                            rooms: rooms,
                            compact: compact,
                            rowStyle: rowStyle,
                            homePreview: homePreview,
                            favourites: favourites,
                            failedRooms: failedRooms,
                            hideInviteAvatars: hideInviteAvatars,
                            noteId: noteId,
                          )
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
                            findChildIndexCallback: (key) =>
                                key is ValueKey<String>
                                ? rowIndex[key.value]
                                : null,
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
                              return _roomTileFor(
                                rooms[index],
                                p: p,
                                compact: compact,
                                rowStyle: rowStyle,
                                homePreview: homePreview,
                                favourites: favourites,
                                failedRooms: failedRooms,
                                hideInviteAvatars: hideInviteAvatars,
                                noteId: noteId,
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

/// Forwards [source]'s notifications only while [isCurrent]. The owner
/// rebuilds when its route becomes current again, which catches up.
class _WhileCurrent extends ChangeNotifier {
  _WhileCurrent(this.source, {required this.isCurrent}) {
    source.addListener(_changed);
  }

  final Listenable source;
  final bool Function() isCurrent;

  void _changed() {
    if (isCurrent()) notifyListeners();
  }

  @override
  void dispose() {
    source.removeListener(_changed);
    super.dispose();
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
