import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'appearance_preferences.dart';
import 'chat_backend.dart';
import 'created_room_wait.dart';
import 'features/home/home_features.dart';
import 'features/home/room_list_filters.dart';
import 'features/home/room_list_menu.dart';
import 'features/home/room_list_tile.dart';
import 'features/chat_lock/chat_lock_gate.dart';
import 'features/message_requests/message_requests.dart';
import 'features/message_requests/message_requests_screen.dart';
import 'features/stories/stories.dart';
import 'features/stories/stories_bar.dart';
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

  /// User-chosen list pane width from dragging the divider (desktop).
  double? _paneWidthOverride;

  void _savePaneWidth() {
    final width = _paneWidthOverride;
    if (width == null) return;
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setDouble(kTwoPaneWidthPref, width))
          .catchError((Object _) => false),
    );
  }

  void _resetPaneWidth() {
    setState(() => _paneWidthOverride = null);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) => prefs.remove(kTwoPaneWidthPref))
          .catchError((Object _) => false),
    );
  }

  bool _windowSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _twoPane.register(widget.backend);
    _twoPane.addListener(_twoPaneChanged);
    unawaited(
      SharedPreferences.getInstance()
          .then((prefs) {
            final width = prefs.getDouble(kTwoPaneWidthPref);
            if (mounted && width != null) {
              setState(() => _paneWidthOverride = width);
            }
          })
          .catchError((Object _) {}),
    );
    _creation.addListener(_creationChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _creationChanged());
    _messageIndex = localMessageSearchOf(widget.backend);
    try {
      _messageIndex?.ensureStarted();
    } catch (_) {}
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
      // Multiple window-class flips can arrive before this frame. Apply the
      // current metrics, not the first queued fold/unfold snapshot.
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
      // A departed room (including a later re-invitation) is not a joined
      // detail selection and must not become a phone error route on fold.
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
  // synchronous; message results arrive asynchronously (debounced, off the UI
  // thread) with encrypted local-index search and server search in parallel.
  LocalMessageSearch? _messageIndex;
  Timer? _messageDebounce;
  int _messageGeneration = 0;
  bool _messageSearchPending = false;
  bool _localSearching = false;
  bool _serverSearching = false;
  bool _localLoadingMore = false;
  bool _serverLoadingMore = false;
  List<LocalMessageHit> _localMessageHits = const [];
  List<MessageHit> _serverMessageHits = const [];
  int? _localNextOffset;
  String? _serverNextBatch;
  String? _localSearchError;
  String? _serverSearchError;
  List<MessageHit> _messageHits = const [];
  String? _openingMessage;
  bool _showAllMatchingRooms = false;
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
    final saved = _saved;
    final isNote = saved != null && room.id == saved.noteToSelfRoomId;
    final choice = await showRoomListMenu(
      context,
      room: room,
      favourite: favourite,
      pinned: isNote ? saved.noteToSelfPinned : null,
      capabilities: RoomMenuCapabilities(
        favourites: roomList != null || _features != null,
        tags: roomList != null,
        notifications: roomList != null,
        folders: saved != null,
      ),
    );
    if (!mounted ||
        !_owner.isCurrent ||
        choice == null ||
        _pendingRoomAction != null) {
      return;
    }
    if (choice == RoomMenuAction.addToFolder) {
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
    if (choice == RoomMenuAction.lockChat ||
        choice == RoomMenuAction.unlockChat) {
      final store = ChatLockScope.maybeOf(context);
      if (store != null) {
        final lock = choice == RoomMenuAction.lockChat;
        if (lock && !store.canLock) {
          await store.refreshCredential();
          if (!store.canLock) {
            if (mounted && _owner.isCurrent) {
              _showError(
                'Set up an app lock PIN in Settings → Security first.',
              );
            }
            return;
          }
        }
        await store.setLocked(room.id, lock);
      }
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
        case RoomMenuAction.pin || RoomMenuAction.unpin:
          await saved!.setNoteToSelfPinned(choice == RoomMenuAction.pin);
        case RoomMenuAction.lowPriority:
          await roomList!.setLowPriority(room.id, !room.lowPriority);
        case RoomMenuAction.mute || RoomMenuAction.unmute:
          await roomList!.setRoomMuted(room.id, choice == RoomMenuAction.mute);
        case RoomMenuAction.markUnread:
          await widget.backend.setRoomUnread(room.id, true);
        case RoomMenuAction.markRead:
          await _markRoomRead(room);
        case RoomMenuAction.copyLink ||
            RoomMenuAction.addToFolder ||
            RoomMenuAction.chatPicture ||
            RoomMenuAction.lockChat ||
            RoomMenuAction.unlockChat:
          break;
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _showError(switch (choice) {
          RoomMenuAction.leave => 'Couldn’t leave this room.',
          RoomMenuAction.favourite => 'Couldn’t update favourites.',
          RoomMenuAction.lowPriority => 'Couldn’t update low priority.',
          RoomMenuAction.pin || RoomMenuAction.unpin =>
            'Couldn’t change whether Note to self is pinned.',
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

  /// Clears a manual unread mark and sends the read receipt for the room's
  /// latest message, without opening it.
  Future<void> _markRoomRead(ChatRoom room) async {
    final publicReceipt =
        FeatureSettingsScope.maybeOf(context)?.preferences.sendReadReceipts ??
        true;
    if (room.manuallyUnread) {
      await widget.backend.setRoomUnread(room.id, false);
    }
    if (!mounted || !_owner.isCurrent) return;
    await _roomList?.markAsRead(room.id, publicReceipt: publicReceipt);
  }

  /// Copies the one-time code offered on an unread row and marks the chat
  /// read: the code was the message. The chat is not opened. A code that
  /// could not be copied leaves the chat unread, with its button.
  Future<void> _copyCode(ChatRoom room, String code) async {
    Haptics.selection();
    try {
      await Clipboard.setData(ClipboardData(text: code));
    } catch (_) {
      if (mounted && _owner.isCurrent) _showError('Couldn’t copy the code.');
      return;
    }
    if (!mounted || !_owner.isCurrent) return;
    _showError('Code copied');
    try {
      await _markRoomRead(room);
    } catch (_) {
      // The code is on the clipboard. The chat stays unread and keeps its
      // button; opening it or "Mark as read" still works.
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
      if (_searchOpen) {
        try {
          _messageIndex?.ensureStarted();
        } catch (_) {}
      } else {
        // Never leave an invisible query narrowing the room list.
        _search.clear();
        _query = '';
        _resetMessageSearch();
      }
    });
  }

  void _clearSearchQuery() {
    Haptics.selection();
    _search.clear();
    setState(() {
      _query = '';
      _resetMessageSearch();
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

  /// Room results shown above Message matches before "Show all N chats".
  static const _collapsedRoomResultLimit = 3;

  /// Number of local message hits fetched per page.
  static const _messagePageSize = 20;

  bool get _searchingMessages =>
      _messageSearchPending || _localSearching || _serverSearching;

  bool get _loadingMoreMessages => _localLoadingMore || _serverLoadingMore;

  bool get _hasMoreMessages =>
      _localNextOffset != null || _serverNextBatch != null;

  bool get _hasActiveScopeFilter =>
      _spaceId != null || _folderId != null || _filters.isNotEmpty;

  void _resetMessageSearch() {
    _messageDebounce?.cancel();
    _messageGeneration++;
    _messageSearchPending = false;
    _localSearching = false;
    _serverSearching = false;
    _localLoadingMore = false;
    _serverLoadingMore = false;
    _localMessageHits = const [];
    _serverMessageHits = const [];
    _localNextOffset = null;
    _serverNextBatch = null;
    _localSearchError = null;
    _serverSearchError = null;
    _messageHits = const [];
    _openingMessage = null;
    _showAllMatchingRooms = false;
  }

  void _onSearchChanged(String value) {
    _messageDebounce?.cancel();
    final query = value.trim();
    final generation = ++_messageGeneration;
    final active = _searchOpen && query.length >= 2;
    setState(() {
      _query = value;
      _messageSearchPending = active;
      _localSearching = false;
      _serverSearching = false;
      _localLoadingMore = false;
      _serverLoadingMore = false;
      _localMessageHits = const [];
      _serverMessageHits = const [];
      _localNextOffset = null;
      _serverNextBatch = null;
      _localSearchError = null;
      _serverSearchError = null;
      _messageHits = const [];
      _openingMessage = null;
      _showAllMatchingRooms = false;
    });
    if (!active) return;
    // Debounced so a burst of keystrokes costs one search, not one per key.
    _messageDebounce = Timer(const Duration(milliseconds: 350), () {
      _dispatchMessageSearch(query, generation);
    });
  }

  void _submitSearch(String value) {
    final query = value.trim();
    if (!_searchOpen || query.length < 2) return;
    if (_messageSearchPending) {
      _messageDebounce?.cancel();
      _dispatchMessageSearch(query, _messageGeneration);
    } else if (!_searchingMessages &&
        (_localSearchError != null || _serverSearchError != null)) {
      _retryMessageSearch();
    }
  }

  void _retryMessageSearch() {
    final query = _query.trim();
    if (!_searchOpen || query.length < 2) return;
    _messageDebounce?.cancel();
    final generation = ++_messageGeneration;
    setState(() {
      _localLoadingMore = false;
      _serverLoadingMore = false;
      _localMessageHits = const [];
      _serverMessageHits = const [];
      _localNextOffset = null;
      _serverNextBatch = null;
      _localSearchError = null;
      _serverSearchError = null;
      _messageHits = const [];
      _openingMessage = null;
    });
    _dispatchMessageSearch(query, generation);
  }

  bool _messageSearchCurrent(int generation) =>
      mounted &&
      generation == _messageGeneration &&
      _searchOpen &&
      _owner.isCurrent;

  void _dispatchMessageSearch(String query, int generation) {
    if (!_messageSearchCurrent(generation)) return;
    final index = _messageIndex;
    setState(() {
      _messageSearchPending = false;
      _localSearching = index != null;
      _serverSearching = true;
    });
    // Run encrypted local-index search and homeserver search in parallel so
    // neither waits on the other.
    if (index != null) {
      unawaited(_searchLocalMessages(index, query, generation));
    }
    unawaited(_searchServerMessages(query, generation));
  }

  Future<void> _searchLocalMessages(
    LocalMessageSearch index,
    String query,
    int generation,
  ) async {
    if (!_messageSearchCurrent(generation)) return;
    bool enabled;
    try {
      enabled = await index.isEnabled();
    } catch (_) {
      enabled = false;
    }
    if (!_messageSearchCurrent(generation)) return;
    if (!enabled) {
      setState(() => _localSearching = false);
      return;
    }
    try {
      final page = await index.search(query, limit: _messagePageSize);
      if (!_messageSearchCurrent(generation)) return;
      _localMessageHits = page.hits;
      _localNextOffset = page.nextOffset;
      _localSearchError = null;
      _localSearching = false;
      _publishMessageHits();
    } catch (_) {
      if (!_messageSearchCurrent(generation)) return;
      setState(() {
        _localSearching = false;
        _localSearchError = 'Couldn’t search this device’s history.';
      });
    }
  }

  Future<void> _searchServerMessages(String query, int generation) async {
    if (!_messageSearchCurrent(generation)) return;
    try {
      final page = await widget.backend.searchMessages(query);
      if (!_messageSearchCurrent(generation)) return;
      _serverMessageHits = page.hits;
      _serverNextBatch = page.nextBatch;
      _serverSearchError = null;
      _serverSearching = false;
      _publishMessageHits();
    } catch (_) {
      if (!_messageSearchCurrent(generation)) return;
      setState(() {
        _serverSearching = false;
        _serverSearchError = 'Couldn’t search messages on this server.';
      });
    }
  }

  void _loadMoreMessages() {
    if (_searchingMessages || _loadingMoreMessages || !_owner.isCurrent) return;
    final query = _query.trim();
    if (!_searchOpen || query.length < 2) return;
    final generation = _messageGeneration;
    final index = _messageIndex;
    final localOffset = _localNextOffset;
    final serverToken = _serverNextBatch;
    if ((index == null || localOffset == null) && serverToken == null) return;
    Haptics.selection();
    setState(() {
      if (index != null && localOffset != null) _localLoadingMore = true;
      if (serverToken != null) _serverLoadingMore = true;
    });
    if (index != null && localOffset != null) {
      unawaited(_loadMoreLocalMessages(index, query, localOffset, generation));
    }
    if (serverToken != null) {
      unawaited(_loadMoreServerMessages(query, serverToken, generation));
    }
  }

  Future<void> _loadMoreLocalMessages(
    LocalMessageSearch index,
    String query,
    int offset,
    int generation,
  ) async {
    try {
      final page = await index.search(
        query,
        offset: offset,
        limit: _messagePageSize,
      );
      if (!_messageSearchCurrent(generation)) return;
      final known = {for (final hit in _localMessageHits) hit.id};
      _localMessageHits = [
        ..._localMessageHits,
        for (final hit in page.hits)
          if (known.add(hit.id)) hit,
      ];
      _localNextOffset = (page.nextOffset != null && page.nextOffset! > offset)
          ? page.nextOffset
          : null;
      _localLoadingMore = false;
      _publishMessageHits();
    } catch (_) {
      if (!_messageSearchCurrent(generation)) return;
      setState(() => _localLoadingMore = false);
      _showError('Couldn’t load more matches.');
    }
  }

  Future<void> _loadMoreServerMessages(
    String query,
    String token,
    int generation,
  ) async {
    try {
      final page = await widget.backend.searchMessages(query, nextBatch: token);
      if (!_messageSearchCurrent(generation)) return;
      final known = {for (final hit in _serverMessageHits) hit.id};
      _serverMessageHits = [
        ..._serverMessageHits,
        for (final hit in page.hits)
          if (known.add(hit.id)) hit,
      ];
      _serverNextBatch = page.nextBatch == token ? null : page.nextBatch;
      _serverLoadingMore = false;
      _publishMessageHits();
    } catch (_) {
      if (!_messageSearchCurrent(generation)) return;
      setState(() => _serverLoadingMore = false);
      _showError('Couldn’t load more matches.');
    }
  }

  void _publishMessageHits() {
    final seen = <String>{};
    final combined = <MessageHit>[];
    for (final hit in [..._localMessageHits, ..._serverMessageHits]) {
      if (!seen.add(hit.id)) continue;
      combined.add(hit);
    }
    combined.sort((a, b) => b.time.compareTo(a.time));
    setState(() {
      _messageHits = combined;
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

  Future<void> _openMessageHit(int generation, MessageHit hit) async {
    if (_openingMessage != null || !_messageSearchCurrent(generation)) return;
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
    if (!mounted || !_messageSearchCurrent(generation)) return;
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
        pinned: _saved?.noteToSelfPinned ?? true,
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
      style: rowStyle,
      preview: homePreview,
      selected: selected,
      onTap: room.invited ? () => _showInvitation(room) : () => _open(room.id),
      onLongPress: room.invited ? null : () => _showRoomActions(room),
      onAccept: () => _acceptInvite(room),
      onDecline: () => _declineInvite(room),
      onCopyCode: (code) => _copyCode(room, code),
    );
  }

  /// Search mode: matching chats (capped so message hits stay in view), then
  /// inline message matches with live searching animation and pagination.
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
    final trimmed = _query.trim();
    final generation = _messageGeneration;
    final hits = _hasActiveScopeFilter
        ? [
            for (final hit in _messageHits)
              if (_messageScopeIds.contains(hit.roomId)) hit,
          ]
        : _messageHits;
    final searching = _searchingMessages;
    final canSearchMessages = trimmed.length >= 2;
    final hasErrors = _localSearchError != null || _serverSearchError != null;
    if (rooms.isEmpty &&
        hits.isEmpty &&
        !searching &&
        !hasErrors &&
        canSearchMessages) {
      return _EmptyRoomList(
        palette: p,
        icon: Icons.search_off_rounded,
        title: 'No matches yet',
        subtitle: 'Try another search.',
      );
    }
    final showAllRooms =
        _showAllMatchingRooms || rooms.length <= _collapsedRoomResultLimit;
    final visibleRooms = showAllRooms
        ? rooms
        : rooms.take(_collapsedRoomResultLimit).toList();
    final hiddenRoomCount = rooms.length - visibleRooms.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      children: [
        if (visibleRooms.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Eyebrow('Chats', palette: p),
          ),
          for (final room in visibleRooms)
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
          if (hiddenRoomCount > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('home.search_show_all_chats'),
                onPressed: () {
                  Haptics.selection();
                  setState(() => _showAllMatchingRooms = true);
                },
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: Text('Show all ${rooms.length} chats'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Eyebrow('Message matches', palette: p),
              if (searching)
                _SearchingDots(
                  key: const ValueKey('home.message_search_spinner'),
                  palette: p,
                ),
            ],
          ),
        ),
        if (!canSearchMessages)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
            child: Text(
              'Type at least two characters to search messages.',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          )
        else ...[
          if (searching && hits.isEmpty)
            _MessageSearchShimmer(
              key: const ValueKey('home.message_search_shimmer'),
              palette: p,
            ),
          for (final hit in hits) _messageHitCard(p, generation, hit),
          if (!searching && hits.isEmpty && !hasErrors)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
              child: Text(
                'No matching messages.',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
          if (_localSearchError != null)
            _messageSearchNotice(p, _localSearchError!),
          if (_serverSearchError != null)
            _messageSearchNotice(p, _serverSearchError!),
          if (!searching && hasErrors)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('home.search_retry'),
                onPressed: _retryMessageSearch,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try again'),
              ),
            ),
          if (!searching && _hasMoreMessages)
            Center(
              child: TextButton.icon(
                key: const ValueKey('home.search_load_more'),
                onPressed: _loadingMoreMessages ? null : _loadMoreMessages,
                icon: _loadingMoreMessages
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.accent,
                        ),
                      )
                    : const Icon(Icons.expand_more_rounded),
                label: Text(
                  _loadingMoreMessages ? 'Loading…' : 'Load more messages',
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _messageSearchNotice(AppPalette p, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
    child: Text(text, style: TextStyle(color: p.muted, fontSize: 13)),
  );

  Widget _messageHitCard(AppPalette p, int generation, MessageHit hit) {
    final opening = _openingMessage == hit.id;
    final inThread = hit is LocalMessageHit && hit.threadRootId != null;
    return Card(
      key: ValueKey('home-hit-${hit.id}'),
      color: p.surface,
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openMessageHit(generation, hit),
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
        // A physical hinge keeps the hardware-aligned gap; otherwise the
        // divider is drag-resizable and the chosen width persists.
        final hinge = split.gapWidth > 1;
        final listWidth = hinge
            ? split.listWidth
            : clampTwoPaneWidth(
                _paneWidthOverride ?? split.listWidth,
                constraints.maxWidth,
              );
        // Resolve the per-pane MediaQueries below the macOS top-inset
        // opt-out; copying the outer context here would restore that inset.
        final panes = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: listWidth,
              child: Builder(
                builder: (context) => MediaQuery.removePadding(
                  context: context,
                  removeRight: true,
                  child: inbox,
                ),
              ),
            ),
            if (hinge)
              SizedBox(
                width: split.gapWidth,
                child: ColoredBox(color: p.stroke),
              )
            else
              PaneDivider(
                palette: p,
                onDrag: (dx) => setState(() {
                  _paneWidthOverride = clampTwoPaneWidth(
                    listWidth + dx,
                    constraints.maxWidth,
                  );
                }),
                onDragEnd: _savePaneWidth,
                onReset: _resetPaneWidth,
              ),
            Expanded(
              child: Builder(
                builder: (context) => MediaQuery.removePadding(
                  context: context,
                  removeLeft: true,
                  // Room membership changes must also rebuild the detail:
                  // leaving a selected room restores the placeholder.
                  child: AnimatedBuilder(
                    animation: _changes,
                    builder: (context, _) => _detailPane(context),
                  ),
                ),
              ),
            ),
          ],
        );
        // The wide macOS header shares the native traffic-light strip.
        // Opt out of the root route inset for BOTH panes, including the
        // embedded room, without changing Windows/Android layout.
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
          return MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: panes,
          );
        }
        return panes;
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
        id != null &&
        widget.backend.rooms.any((room) => room.id == id && !room.invited);
    if (!known) {
      // The detail pane has no Scaffold of its own; without a Material the
      // placeholder text inherits the framework fallback style (48px, yellow
      // underline). A transparent Material supplies the theme text style.
      return Material(
        type: MaterialType.transparency,
        child: GlowBackdrop(
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
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Choose a chat from the list to start reading.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 13,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
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

  Widget _inboxHeader({required bool twoPane, required bool expandedHome}) {
    final p = widget.palette;
    final macWide =
        twoPane && !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final brand = twoPane
        ? Row(
            key: const ValueKey('home.header_brand'),
            children: [
              BrandMark(palette: p, size: 44),
              const SizedBox(width: 13),
              Flexible(
                child: Text(
                  'Parallax',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          )
        : Column(
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
          );
    final actions = <Widget>[
      IconButton(
        key: const ValueKey('home.search_toggle'),
        tooltip: _searchOpen
            ? 'Hide conversation search'
            : 'Search conversations',
        onPressed: _toggleConversationSearch,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _searchOpen ? Icons.close_rounded : Icons.search_rounded,
            key: ValueKey(_searchOpen),
          ),
        ),
      ),
      IconButton(
        tooltip: 'Create room',
        onPressed: _creatingRoom || _creation.active ? null : _createRoom,
        icon: const Icon(Icons.add_home_work_outlined),
      ),
      if (!expandedHome)
        IconButton(
          key: const ValueKey('home.options'),
          tooltip: _optionsOpen ? 'Hide options' : 'Show options',
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
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // The native traffic lights consume 84dp on the brand row. In a
        // narrow list pane the four actions cannot share that row, even if
        // the title ellipsizes completely. Reflow only macOS; keep the
        // flush Windows/tablet header and all touch targets unchanged.
        if (macWide && constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(84, 4, 8, 0),
                child: brand,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  key: const ValueKey('home.header_actions'),
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ),
            ],
          );
        }
        return Padding(
          padding: twoPane
              ? EdgeInsets.fromLTRB(macWide ? 84 : 16, 4, 8, 0)
              : const EdgeInsets.fromLTRB(22, 22, 16, 0),
          child: Row(
            children: [
              if (!twoPane) ...[
                BrandMark(palette: p, size: 46),
                const SizedBox(width: 13),
              ],
              Expanded(child: brand),
              ...actions,
            ],
          ),
        );
      },
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
        final requestsCtrl = MessageRequestsScope.maybeOf(context);
        final separateRequests = requestsCtrl?.separate ?? false;
        final storiesCtrl = StoriesScope.maybeOf(context);
        final showStories = storiesCtrl?.enabled ?? false;
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
        // Unpinned, Note to self sorts with the other chats.
        final notePinned = saved?.noteToSelfPinned ?? true;
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
            notePinned,
            folderList,
            folder,
            _filters,
            _query,
            spaceRooms,
            separateRequests,
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
            // Message requests from unknown senders live in their own inbox.
            final requestIds = separateRequests
                ? (requestsCtrl?.requestIds(allRooms) ?? const <String>{})
                : const <String>{};
            final visible = requestIds.isEmpty
                ? filtered
                : filtered
                      .where((room) => !requestIds.contains(room.id))
                      .toList();
            return (
              unreadByFolder: {
                for (final f in folderList)
                  f.id: folderUnreadCount(f, allRooms, facts),
              },
              rooms: notePinned
                  ? [
                      ...visible.where((room) => room.id == noteId),
                      ...visible.where((room) => room.id != noteId),
                    ]
                  : visible,
            );
          },
        );
        // Invitations from unknown senders, shown in their own inbox banner.
        final requestRooms = separateRequests
            ? (requestsCtrl?.requests(source) ?? const <ChatRoom>[])
            : const <ChatRoom>[];
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
              // to zero width in a narrow (tablet list pane) box.
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
          textInputAction: TextInputAction.search,
          onChanged: _onSearchChanged,
          onSubmitted: _submitSearch,
          decoration: InputDecoration(
            hintText: 'Search people, rooms and messages',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    key: const ValueKey('home.search_clear'),
                    tooltip: 'Clear search',
                    onPressed: _clearSearchQuery,
                    icon: const Icon(Icons.close_rounded),
                  )
                : null,
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
              // Narrow macOS window: keep the phone-style header below the
              // traffic-light strip (the native title bar is hidden).
              minimum:
                  (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.macOS &&
                      !twoPane)
                  ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
                  : EdgeInsets.zero,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _inboxHeader(twoPane: twoPane, expandedHome: expandedHome),
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
                  if (showStories && !_searchOpen)
                    StoriesBar(
                      backend: widget.backend,
                      controller: storiesCtrl!,
                      palette: p,
                    ),
                  if (requestRooms.isNotEmpty && !_searchOpen)
                    _MessageRequestsBanner(
                      palette: p,
                      count: requestRooms.length,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => MessageRequestsScreen(
                            backend: widget.backend,
                            palette: p,
                            controller: requestsCtrl!,
                          ),
                        ),
                      ),
                    ),
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

/// Inbox banner opening the dedicated message-requests inbox.
class _MessageRequestsBanner extends StatelessWidget {
  const _MessageRequestsBanner({
    required this.palette,
    required this.count,
    required this.onTap,
  });
  final AppPalette palette;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: p.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
        ),
        child: InkWell(
          key: const ValueKey('home.message_requests'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
            child: Row(
              children: [
                Icon(
                  Icons.mark_email_unread_outlined,
                  color: p.secondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    count == 1
                        ? '1 message request'
                        : '$count message requests',
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Animated three-dot wave shown next to "Message matches" while local or
/// server message searches are running.
class _SearchingDots extends StatefulWidget {
  const _SearchingDots({super.key, required this.palette});
  final AppPalette palette;

  @override
  State<_SearchingDots> createState() => _SearchingDotsState();
}

class _SearchingDotsState extends State<_SearchingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final colors = [
      p.accent,
      Color.lerp(p.accent, p.secondary, 0.5) ?? p.secondary,
      p.secondary,
    ];
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Builder(
              builder: (_) {
                final phase =
                    (_controller.value * 2 * math.pi) - (i * math.pi / 2.2);
                final wave = (math.sin(phase) + 1) / 2;
                return Transform.translate(
                  offset: Offset(0, -2.5 * wave),
                  child: Opacity(
                    opacity: 0.35 + (0.65 * wave),
                    child: Container(
                      width: 5.5,
                      height: 5.5,
                      decoration: BoxDecoration(
                        color: colors[i],
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
          const SizedBox(width: 7),
          Text(
            'Searching…',
            style: TextStyle(
              color: p.muted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pulsing placeholder cards shown while inline message search is running and
/// no hits have arrived yet.
class _MessageSearchShimmer extends StatefulWidget {
  const _MessageSearchShimmer({super.key, required this.palette});
  final AppPalette palette;

  @override
  State<_MessageSearchShimmer> createState() => _MessageSearchShimmerState();
}

class _MessageSearchShimmerState extends State<_MessageSearchShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        final bar = Color.lerp(p.raised, p.accent.withValues(alpha: 0.16), t)!;
        final faint = Color.lerp(
          p.raised.withValues(alpha: 0.7),
          p.secondary.withValues(alpha: 0.12),
          t,
        )!;
        Widget card(double titleWidth, double lineWidth) => Card(
          color: p.surface,
          margin: const EdgeInsets.only(bottom: 9),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: titleWidth,
                  height: 10,
                  decoration: BoxDecoration(
                    color: faint,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  height: 13,
                  decoration: BoxDecoration(
                    color: bar,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: lineWidth,
                  height: 13,
                  decoration: BoxDecoration(
                    color: bar,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: 72,
                  height: 9,
                  decoration: BoxDecoration(
                    color: faint,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
        );
        return Column(children: [card(110, 210), card(88, 165)]);
      },
    );
  }
}
