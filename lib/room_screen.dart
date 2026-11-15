import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'app_theme.dart';
import 'attachment_picker.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/reactions/reaction_hooks.dart';
import 'features/reactions/emoji_picker_sheet.dart';
import 'features/reactions/quick_reaction_settings.dart';
import 'features/rich_timeline/rich_timeline_hooks.dart';
import 'features/scheduled/undo_send.dart';
import 'hooks/registry.dart';
import 'media_viewer.dart';
import 'message_draft_store.dart';
import 'message_receipts_sheet.dart';
import 'messaging_features.dart';
import 'rich_message_composer.dart';
import 'thread_screen.dart';
import 'photo_picker.dart';
import 'room_avatar.dart';
import 'room_background_store.dart';
import 'room_details_screen.dart';
import 'room_draft_owner.dart';
import 'timeline/timeline_view.dart';
import 'widgets.dart';
import 'features/composer/edit_markdown.dart';
import 'haptics.dart';
import 'timeline/double_tap_react.dart';
import 'features/appearance/bubble_colours.dart';
import 'features/appearance/bubble_colours_screen.dart';
import 'pending_failure.dart';
import 'package:flutter/services.dart';

class RoomScreen extends StatelessWidget {
  const RoomScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.backgroundStore,
    this.draftStore,
    this.bubbleColourStore,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final RoomBackgroundStore? backgroundStore;
  final MessageDraftStore? draftStore;

  /// Per-room bubble colours (defaults to the shared store).
  final RoomBubbleColourStore? bubbleColourStore;

  @override
  Widget build(BuildContext context) => _OwnedRoomScreen(
    key: ValueKey((
      backend,
      BackendSessionOwner.keyFor(backend),
      backend.userId,
      roomId,
    )),
    backend: backend,
    palette: palette,
    roomId: roomId,
    backgroundStore: backgroundStore,
    draftStore: draftStore,
    bubbleColourStore: bubbleColourStore,
  );
}

/// Changing the room/backend replaces the entire owner, including pending
/// reads, edit buffers and timers, even when a caller reuses the public widget.
class _OwnedRoomScreen extends StatefulWidget {
  const _OwnedRoomScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.backgroundStore,
    this.draftStore,
    this.bubbleColourStore,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final RoomBackgroundStore? backgroundStore;
  final MessageDraftStore? draftStore;

  /// Per-room bubble colours (defaults to the shared store).
  final RoomBubbleColourStore? bubbleColourStore;

  @override
  State<_OwnedRoomScreen> createState() => _RoomScreenState();
}

class _RoomTimelineScope {
  _RoomTimelineOwner? current;
}

/// The newest mounted route for one room owns its shared backend timeline.
/// Replacing a room route can mount the new state before the old state is
/// disposed; the old state must not close the replacement's timeline.
class _RoomTimelineOwner {
  _RoomTimelineOwner._(this._key, this._scope);

  factory _RoomTimelineOwner.claim(BackendSessionOwner session, String roomId) {
    final key = (session.backend, session.accountKey, session.userId, roomId);
    final scope = _scopes.putIfAbsent(key, _RoomTimelineScope.new);
    final owner = _RoomTimelineOwner._(key, scope);
    scope.current = owner;
    return owner;
  }

  static final _scopes =
      <(ChatBackend, String?, String?, String), _RoomTimelineScope>{};
  final (ChatBackend, String?, String?, String) _key;
  final _RoomTimelineScope _scope;

  bool get isCurrent => identical(_scope.current, this);

  void release() {
    if (!isCurrent) return;
    _scope.current = null;
    _scopes.remove(_key);
  }
}

class _RoomScreenState extends State<_OwnedRoomScreen>
    with WidgetsBindingObserver {
  final _draft = TextEditingController();
  late final _owner = BackendSessionOwner(widget.backend);
  late final _timelineOwner = _RoomTimelineOwner.claim(_owner, widget.roomId);
  MessageDraftStore? _draftStore;
  RoomDraftOwner? _draftOwner;
  Future<void>? _draftLoading;
  Timer? _draftTimer;
  bool _draftLoaded = false;
  bool _draftReadFailed = false;
  bool _draftDirty = false;
  bool _settingDraft = false;
  bool _draftStarted = false;
  bool _sending = false;
  int _draftRevision = 0;
  int _normalRevision = 0;
  int _composerContext = 0;
  String _normalDraft = '';
  String _lastDraftText = '';
  final _pendingActions = <String>{};

  MessagingFeatures? get _features => widget.backend is MessagingFeatures
      ? widget.backend as MessagingFeatures
      : null;
  Timer? _typingStopTimer;
  DateTime? _lastTypingSent;
  bool _typing = false;
  ChatEntry? _replyingTo;
  ChatEntry? _editing;
  late final _backgroundStore = widget.backgroundStore ?? RoomBackgroundStore();
  late final _bubbleStore =
      widget.bubbleColourStore ?? RoomBubbleColourStore.shared;
  late BubbleColours _bubbleColours =
      _bubbleStore.cached(widget.roomId) ?? BubbleColours.none;
  File? _background;
  int _backgroundVersion = 0;
  bool _backgroundBusy = false;
  bool _opening = true;
  bool _loadingOlder = false;
  double _emptyPullDistance = 0;
  bool _emptyPullTriggered = false;
  bool _emptyPullArmed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draft.addListener(_draftChanged);
    _loadBackground();
    _bubbleStore.addListener(_bubbleColoursChanged);
    unawaited(
      _bubbleStore.load(widget.roomId).then((_) => _bubbleColoursChanged()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _owner.isCurrent && _timelineOwner.isCurrent) {
        unawaited(_open());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_draftStarted || _features == null) return;
    _draftStarted = true;
    _draftStore =
        widget.draftStore ??
        FeatureSettingsScope.maybeOf(context)?.draftStore ??
        MessageDraftStore();
    final account = _owner.accountKey;
    if (account != null && account.isNotEmpty) {
      _draftOwner = RoomDraftOwner.claim(account, widget.roomId);
    }
    unawaited(_loadDraft());
  }

  Future<void> _loadDraft() => _draftLoading ??= _readDraft().whenComplete(() {
    _draftLoading = null;
  });

  Future<void> _readDraft() async {
    final account = _owner.accountKey;
    final store = _draftStore;
    final draftOwner = _draftOwner;
    if (!mounted ||
        !_owner.isCurrent ||
        account == null ||
        account.isEmpty ||
        store == null ||
        draftOwner == null ||
        !draftOwner.isCurrent) {
      return;
    }
    final revision = _draftRevision;
    try {
      final saved = await draftOwner.read(store) ?? '';
      if (!_owner.isCurrent || !draftOwner.isCurrent) return;
      _draftLoaded = true;
      _draftReadFailed = false;
      // Hydration (including a retry) never replaces a user-edited normal
      // buffer. Keep the saved buffer available to detached flush/edit owners
      // without accessing the controller after route disposal.
      final restoreNormal = _normalRevision == 0;
      if (restoreNormal) _normalDraft = saved;
      if (!mounted) return;
      if (restoreNormal && revision == _draftRevision && _editing == null) {
        if (_draft.text != saved) _draftRevision++;
        _setDraft(saved);
      } else if (_editing == null) {
        _draftDirty = true;
        _scheduleDraft();
      }
      setState(() {});
    } catch (_) {
      if (_owner.isCurrent && draftOwner.isCurrent) {
        _draftReadFailed = true;
        if (mounted) setState(() {});
      }
    }
  }

  void _setDraft(String text) {
    _settingDraft = true;
    _lastDraftText = text;
    _draft.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _settingDraft = false;
  }

  void _draftChanged() {
    if (_settingDraft || !_owner.isCurrent || _lastDraftText == _draft.text) {
      return;
    }
    _lastDraftText = _draft.text;
    _draftRevision++;
    if (_editing != null) return;
    _normalRevision++;
    _draftOwner?.revise();
    _normalDraft = _draft.text;
    _draftDirty = true;
    _scheduleDraft();
  }

  void _scheduleDraft() {
    _draftTimer?.cancel();
    if (!_draftLoaded || _draftReadFailed) return;
    _draftTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushDraft());
    });
  }

  Future<void> _flushClosingDraft() async {
    // State.dispose cannot await hydration. Capture the ordinary buffer now,
    // and retain both owners through the read and its fenced storage write.
    // A replacement route/session can revoke this work even for identical text.
    final text = _normalDraft;
    final edited = _normalRevision != 0;
    final owner = _owner;
    final draftOwner = _draftOwner;
    owner.retain();
    draftOwner?.retain();
    try {
      final loading = _draftLoading;
      if (loading != null) await loading;
      await _flushDraft(snapshot: edited ? text : null);
    } finally {
      draftOwner?.release();
      owner.release();
    }
  }

  Future<void> _flushDraft({bool accepted = false, String? snapshot}) async {
    _draftTimer?.cancel();
    final account = _owner.accountKey;
    final store = _draftStore;
    final draftOwner = _draftOwner;
    if (!_owner.isCurrent ||
        !_draftLoaded ||
        _draftReadFailed ||
        !_draftDirty ||
        account == null ||
        store == null ||
        draftOwner == null ||
        !draftOwner.isCurrent) {
      return;
    }
    // Acceptance may remove the durable snapshot, but must not replace the
    // live buffer before the composer's acknowledgement. A context change
    // during this write can then re-persist even an identical visible body.
    final text = accepted ? '' : snapshot ?? _normalDraft;
    final revision = draftOwner.revision;
    _draftDirty = false;
    final owner = _owner;
    owner.retain();
    try {
      await draftOwner.write(
        store,
        text,
        revision: revision,
        sessionIsCurrent: () => owner.isCurrent,
      );
    } catch (_) {
      final current =
          owner.isCurrent &&
          draftOwner.isCurrent &&
          draftOwner.revision == revision;
      if (current) _draftDirty = true;
      if (mounted && current) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t save this draft on this device.'),
          ),
        );
      }
    } finally {
      owner.release();
    }
  }

  void _cancelComposerContext() {
    if (!mounted || !_owner.isCurrent) return;
    setState(() {
      _advanceComposerContext();
      if (_editing != null) _setDraft(_normalDraft);
      _replyingTo = null;
      _editing = null;
    });
  }

  void _advanceComposerContext() {
    _composerContext++;
    _draftOwner?.revise();
    _draftDirty = true;
    _scheduleDraft();
  }

  Object? _sendContext() =>
      mounted && _owner.isCurrent && (_draftOwner?.isCurrent ?? true)
      ? _composerContext
      : null;

  void _acknowledgeComposer(int contextRevision, bool textCleared) {
    if (!textCleared ||
        !mounted ||
        !_owner.isCurrent ||
        contextRevision != _composerContext) {
      return;
    }
    setState(() {
      // Run after the composer's clear, while edits remain isolated from the
      // ordinary draft. Equal text must not become a second clear.
      if (_editing != null) _setDraft(_normalDraft);
      _editing = null;
      _replyingTo = null;
      _composerContext++;
    });
    _stopTyping();
  }

  void _bubbleColoursChanged() {
    final colours = _bubbleStore.cached(widget.roomId);
    if (!mounted || colours == null || colours == _bubbleColours) return;
    setState(() => _bubbleColours = colours);
  }

  Future<void> _openBubbleColours(String roomName) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BubbleColoursScreen(
            roomId: widget.roomId,
            roomName: roomName,
            palette: widget.palette,
            store: _bubbleStore,
          ),
        ),
      );

  Future<void> _loadBackground() async {
    try {
      final file = await _backgroundStore.fileFor(widget.roomId);
      if (mounted && _owner.isCurrent) setState(() => _background = file);
    } catch (_) {
      if (mounted && _owner.isCurrent) _showBackgroundError();
    }
  }

  void _showBackgroundError() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Couldn’t update this room’s background.')),
  );

  Future<void> _chooseBackground() async {
    if (!mounted || !_owner.isCurrent || _backgroundBusy) return;
    try {
      final selection = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (selection == null || !mounted || !_owner.isCurrent) return;
      setState(() => _backgroundBusy = true);
      final file = await _backgroundStore.replace(widget.roomId, selection);
      await FileImage(file).evict();
      if (mounted && _owner.isCurrent) {
        setState(() {
          _background = file;
          _backgroundVersion++;
        });
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) _showBackgroundError();
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _clearBackground() async {
    if (!mounted || !_owner.isCurrent || _backgroundBusy) return;
    setState(() => _backgroundBusy = true);
    try {
      await _backgroundStore.clear(widget.roomId);
      if (mounted && _owner.isCurrent) setState(() => _background = null);
    } catch (_) {
      if (mounted && _owner.isCurrent) _showBackgroundError();
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _open() async {
    if (!_timelineOwner.isCurrent) return;
    try {
      await widget.backend.openRoom(widget.roomId);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        setState(() => _error = 'Couldn’t load this room.');
      }
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _opening = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_flushDraft());
    } else if (_owner.isCurrent) {
      // Messages that arrived while Parallax was in the background.
      widget.backend.markActiveRoomRead();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bubbleStore.removeListener(_bubbleColoursChanged);
    _draftTimer?.cancel();
    unawaited(_flushClosingDraft());
    _draftOwner?.release();
    _typingStopTimer?.cancel();
    _stopTyping();
    if (_owner.isCurrent && _timelineOwner.isCurrent) {
      widget.backend.closeRoom(widget.roomId);
    }
    _timelineOwner.release();
    _owner.release();
    _draft.removeListener(_draftChanged);
    _draft.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    // Legacy button/submission callbacks have no acknowledgement consumer.
    // The send boundary still rejects nonacceptance; consume only at this UI.
    try {
      await _sendContent(_draft.text, null);
    } catch (_) {
      // Owned send failures already show a snackbar in _sendContent.
    }
  }

  Future<void> _sendContent(String text, MediaSelection? media) async {
    final body = text.trim();
    if (!mounted ||
        !_owner.isCurrent ||
        !(_draftOwner?.isCurrent ?? true) ||
        _sending ||
        widget.backend.isRoomSending(widget.roomId) ||
        (body.isEmpty && media == null)) {
      // A completed Future<void> means acceptance to RichMessageComposer.
      // Busy, stale and empty submissions must never acknowledge its buffer.
      throw StateError(
        'Message not accepted: the room is busy or unavailable.',
      );
    }
    if (_editing != null && media != null) {
      throw StateError('Attachments cannot replace a text edit.');
    }
    final owner = _owner;
    owner.retain();
    final draftOwner = _draftOwner;
    draftOwner?.retain();
    final sharedRevision = draftOwner?.revision;
    final features = _features;
    final roomId = widget.roomId;
    final backend = widget.backend;
    final revision = _draftRevision;
    final composerContext = _composerContext;
    final reply = _replyingTo;
    final edit = _editing;
    _draftTimer?.cancel();
    setState(() => _sending = true);
    try {
      // Join an in-flight read before queueing: a late hydration must never
      // restore an already accepted outgoing message as a fresh draft.
      if (features != null && _draftLoading != null) await _draftLoading;
      if (!owner.isCurrent) throw StateError('This session has ended.');
      if (backend.isRoomSending(roomId) || !(draftOwner?.isCurrent ?? true)) {
        throw StateError(
          'Message not accepted: the room is busy or unavailable.',
        );
      }
      if (features != null) {
        if (media == null) {
          await features.queueMessage(
            roomId,
            body,
            replyToId: reply?.id,
            editEventId: edit?.id,
          );
        } else {
          await features.queueMedia(
            roomId,
            media,
            caption: body.isEmpty ? null : body,
            replyToId: reply?.id,
          );
        }
      } else {
        await backend.sendText(
          roomId,
          body,
          replyToId: reply?.id,
          editEventId: edit?.id,
        );
      }
      if (owner.isCurrent &&
          revision == _draftRevision &&
          composerContext == _composerContext &&
          (draftOwner == null ||
              (draftOwner.isCurrent &&
                  draftOwner.revision == sharedRevision))) {
        // Queue acceptance, not delivery, owns this text now. Clear storage
        // even when the route closed while enqueue was suspended.
        if (edit == null) {
          _draftDirty = true;
          await _flushDraft(accepted: true);
        }
        // Rich input acknowledges and restores buffers only after its own
        // revision-aware clear. The legacy input has no composer ack phase.
        if (features == null &&
            mounted &&
            owner.isCurrent &&
            composerContext == _composerContext &&
            _draftRevision == revision) {
          setState(() {
            _setDraft(edit == null ? '' : _normalDraft);
            _replyingTo = null;
            _editing = null;
          });
          _stopTyping();
        }
      }
    } catch (_) {
      if (mounted &&
          owner.isCurrent &&
          composerContext == _composerContext &&
          revision == _draftRevision) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message not sent. Try again.')),
        );
        _scheduleDraft();
      }
      // Reject acknowledgement so the rich composer retains staged media.
      rethrow;
    } finally {
      if (mounted && _owner.isCurrent) setState(() => _sending = false);
      owner.release();
      draftOwner?.release();
    }
  }

  /// This room's projection, looked up once per room list (the list keeps
  /// its identity until a room changes; the screen rebuilds far more often).
  ChatRoom? get _currentRoom {
    final rooms = widget.backend.rooms;
    final cached = _roomLookup;
    if (cached != null &&
        identical(cached.rooms, rooms) &&
        cached.id == widget.roomId) {
      return cached.room;
    }
    final room = [
      for (final r in rooms)
        if (r.id == widget.roomId) r,
    ].firstOrNull;
    _roomLookup = (rooms: rooms, id: widget.roomId, room: room);
    return room;
  }

  ({List<ChatRoom> rooms, String id, ChatRoom? room})? _roomLookup;

  RoomHookContext _roomContext(ChatRoom? room) => RoomHookContext(
    backend: widget.backend,
    roomId: widget.roomId,
    palette: widget.palette,
    room: room,
  );

  EntryHookContext _entryContext(ChatEntry entry) => EntryHookContext(
    backend: widget.backend,
    roomId: widget.roomId,
    palette: widget.palette,
    entry: entry,
    room: _currentRoom,
    entries: widget.backend.activeRoomId == widget.roomId
        ? widget.backend.messages
        : const [],
  );

  /// Double tap: react with the chosen quick reaction (Settings → Chats →
  /// Double-tap reaction; ❤️ by default).
  Future<void> _heart(ChatEntry entry) async {
    await _react(entry, quickReactionOf(context));
  }

  Future<void> _react(ChatEntry entry, String emoji) async {
    if (!mounted || !_owner.isCurrent) return;
    if (!reactionsAllowed(_roomContext(_currentRoom))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You can’t react to messages in this room.'),
        ),
      );
      return;
    }
    Haptics.selection();
    try {
      await widget.backend.react(widget.roomId, entry.id, emoji: emoji);
      unawaited(EmojiRecents.instance.record(emoji, reaction: true));
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t react to this message.')),
        );
      }
    }
  }

  void _onDraftChanged(String text) {
    if (!mounted || !_owner.isCurrent || _settingDraft) return;
    _typingStopTimer?.cancel();
    if (text.trim().isEmpty) {
      _stopTyping();
      return;
    }
    final now = DateTime.now();
    if (!_typing ||
        _lastTypingSent == null ||
        now.difference(_lastTypingSent!) > const Duration(seconds: 3)) {
      _typing = true;
      _lastTypingSent = now;
      unawaited(
        widget.backend.setTyping(widget.roomId, true).catchError((Object _) {}),
      );
    }
    _typingStopTimer = Timer(const Duration(seconds: 4), _stopTyping);
  }

  void _stopTyping() {
    _typingStopTimer?.cancel();
    if (!_typing) return;
    _typing = false;
    if (!_owner.isCurrent) return;
    _lastTypingSent = null;
    unawaited(
      widget.backend.setTyping(widget.roomId, false).catchError((Object _) {}),
    );
  }

  void _replyToEntry(ChatEntry entry) {
    if (!mounted || !_owner.isCurrent || entry.redacted) return;
    Haptics.selection();
    setState(() {
      _advanceComposerContext();
      if (_editing != null) _setDraft(_normalDraft);
      _replyingTo = entry;
      _editing = null;
    });
  }

  Future<void> _showActions(ChatEntry entry) async {
    if (!mounted || !_owner.isCurrent || entry.redacted) return;
    Haptics.longPress();
    final unsent = !entry.id.startsWith(r'$');
    final hookActions = messageActionsFor(context, _entryContext(entry));
    final forwardAction = hookActions
        .where((item) => item.id == 'reactions.forward')
        .firstOrNull;
    final copyTextAction = hookActions
        .where((item) => item.id == 'rich-timeline-copy-text')
        .firstOrNull;
    final remainingHookActions = [
      for (final item in hookActions)
        if (item.id != 'reactions.forward' &&
            item.id != 'rich-timeline-copy-text')
          item,
    ];
    final canEdit =
        entry.mine &&
        const {
          EntryKind.text,
          EntryKind.emote,
          EntryKind.notice,
        }.contains(entry.kind);
    final verifySender =
        !entry.mine &&
        widget.backend.rooms.any(
          (room) => room.id == widget.roomId && room.encrypted,
        );
    final hasMoreActions =
        verifySender ||
        _features != null ||
        entry.isImage ||
        entry.isAttachment ||
        entry.mine ||
        remainingHookActions.isNotEmpty;
    var expanded = false;
    final choice = await showModalBottomSheet<String>(
      isScrollControlled: true,
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          ListTile hookTile(MessageActionItem item) => ListTile(
            leading: Icon(
              item.icon,
              color: item.destructive ? Colors.redAccent : null,
            ),
            title: Text(
              item.label,
              style: item.destructive
                  ? const TextStyle(color: Colors.redAccent)
                  : null,
            ),
            onTap: () => Navigator.pop(sheetContext, 'hook:${item.id}'),
          );

          return SafeArea(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (reactionsAllowed(_roomContext(_currentRoom)))
                    _QuickReactions(
                      palette: widget.palette,
                      onPick: (emoji) => Navigator.pop(sheetContext, emoji),
                      onMore: emojiPickerAvailable
                          ? () => Navigator.pop(sheetContext, _moreReactions)
                          : null,
                    ),
                  ListTile(
                    leading: const Icon(Icons.reply_rounded),
                    title: const Text('Reply'),
                    onTap: () => Navigator.pop(sheetContext, 'reply'),
                  ),
                  if (forwardAction != null) hookTile(forwardAction),
                  if (canEdit)
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('Edit message'),
                      onTap: () => Navigator.pop(sheetContext, 'edit'),
                    ),
                  if (copyTextAction != null) hookTile(copyTextAction),
                  if (!expanded && hasMoreActions)
                    ListTile(
                      key: const ValueKey('message-actions-more'),
                      leading: const Icon(Icons.expand_more_rounded),
                      title: const Text('More'),
                      onTap: () => setSheetState(() => expanded = true),
                    )
                  else if (expanded) ...[
                    if (verifySender)
                      ListTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: const Text('Verify sender'),
                        onTap: () => Navigator.pop(sheetContext, 'verify'),
                      ),
                    if (_features != null) ...[
                      ListTile(
                        leading: const Icon(Icons.forum_outlined),
                        title: const Text('Open thread'),
                        onTap: () => Navigator.pop(sheetContext, 'thread'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.done_all_rounded),
                        title: const Text('Read receipts'),
                        onTap: () => Navigator.pop(sheetContext, 'receipts'),
                      ),
                    ],
                    if (entry.isImage || entry.isAttachment)
                      ListTile(
                        leading: const Icon(Icons.open_in_full_rounded),
                        title: const Text('Open media'),
                        onTap: () => Navigator.pop(sheetContext, 'media'),
                      ),
                    if (entry.isAttachment)
                      ListTile(
                        leading: const Icon(Icons.download_rounded),
                        title: const Text('Save attachment'),
                        onTap: () => Navigator.pop(sheetContext, 'save'),
                      ),
                    if (entry.mine)
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(
                          unsent ? 'Discard unsent message' : 'Delete message',
                        ),
                        onTap: () => Navigator.pop(sheetContext, 'delete'),
                      ),
                    for (final item in remainingHookActions) hookTile(item),
                    ListTile(
                      key: const ValueKey('message-actions-less'),
                      leading: const Icon(Icons.expand_less_rounded),
                      title: const Text('Less'),
                      onTap: () => setSheetState(() => expanded = false),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || !_owner.isCurrent || choice == null) return;
    if (choice.startsWith('hook:')) {
      final id = choice.substring(5);
      final item = hookActions.where((action) => action.id == id).firstOrNull;
      if (item == null) return;
      try {
        await item.onSelected(context);
      } catch (_) {
        if (mounted && _owner.isCurrent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Couldn’t ${item.label.toLowerCase()}.')),
          );
        }
      }
      return;
    }
    if (choice == _moreReactions) {
      final emoji = await pickEmoji(
        context,
        palette: widget.palette,
        forReaction: true,
      );
      if (emoji != null && mounted && _owner.isCurrent) {
        await _react(entry, emoji);
      }
      return;
    }
    if (choice == 'thread') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ThreadScreen(
            backend: widget.backend,
            roomId: widget.roomId,
            root: entry,
          ),
        ),
      );
    } else if (choice == 'receipts') {
      await showMessageReceipts(
        context,
        backend: widget.backend,
        roomId: widget.roomId,
        eventId: entry.id,
        palette: widget.palette,
      );
    } else if (choice == 'media') {
      await openMediaViewer(
        context,
        backend: widget.backend,
        roomId: widget.roomId,
        eventId: entry.id,
      );
    } else if (choice == 'save') {
      await saveAttachment(context, widget.backend, widget.roomId, entry.id);
    } else if (choice == 'verify') {
      try {
        await widget.backend.startVerification(entry.sender);
      } catch (_) {
        if (mounted && _owner.isCurrent) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn’t start verification.')),
          );
        }
      }
    } else if (choice == 'reply') {
      _replyToEntry(entry);
    } else if (choice == 'edit') {
      unawaited(_flushDraft());
      setState(() {
        _advanceComposerContext();
        _editing = entry;
        _replyingTo = null;
        // Element X formatting survives editing (HTML → composer markdown).
        _setDraft(composerTextForEdit(entry));
      });
    } else if (choice == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            unsent ? 'Discard unsent message?' : 'Delete this message?',
          ),
          content: Text(
            unsent
                ? 'This removes the unsent message only from this device.'
                : 'This removes the message for everyone in the room.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(unsent ? 'Discard' : 'Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !_owner.isCurrent) return;
      try {
        await widget.backend.redactMessage(widget.roomId, entry.id);
      } catch (_) {
        if (mounted && _owner.isCurrent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                unsent
                    ? 'Couldn’t discard this unsent message.'
                    : 'Couldn’t delete this message.',
              ),
            ),
          );
        }
      }
    } else {
      await _react(entry, choice);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder ||
        widget.backend.loadingHistory ||
        !widget.backend.canLoadOlder) {
      return;
    }
    _loadingOlder = true;
    try {
      await widget.backend.loadOlder(widget.roomId);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load older messages.')),
        );
      }
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> _pendingAction(PendingSend pending, String action) async {
    final features = _features;
    if (!mounted ||
        !_owner.isCurrent ||
        features == null ||
        !_pendingActions.add(pending.id)) {
      return;
    }
    setState(() {});
    try {
      // The backend owns the stable transaction ID and retry payload. Never
      // rebuild an outgoing message from its display-only PendingSend summary.
      if (action == 'retry') {
        await features.retryPending(pending.id);
      } else if (action == 'discard') {
        await features.discardPending(pending.id);
      } else {
        features.cancelPending(pending.id);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t update this pending message.'),
          ),
        );
      }
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingActions.remove(pending.id));
      }
    }
  }

  /// The full error behind "Not sent", for reporting.
  void _showSendError(PendingSend pending) {
    final error = (pending.error ?? '').trim();
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Why it wasn’t sent'),
          content: SelectableText(
            error.isEmpty
                ? 'No error was recorded.'
                : error.length > 600
                ? '${error.substring(0, 600)}…'
                : error,
          ),
          actions: [
            TextButton(
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: error)));
                Navigator.pop(dialogContext);
              },
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  /// Undo send: withdraws a held send and puts its text back in the composer.
  Future<void> _undoPending(PendingSend pending) async {
    final undo = undoSendFeaturesOf(widget.backend);
    if (!mounted ||
        !_owner.isCurrent ||
        undo == null ||
        !_pendingActions.add(pending.id)) {
      return;
    }
    setState(() {});
    void say(String text) => ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
    try {
      final restored = await undo.undoSend(pending.id);
      if (!mounted || !_owner.isCurrent) return;
      if (restored == null) {
        say('Too late to undo. This message is already sending.');
      } else {
        _restoreUndone(restored, say);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) say('Couldn’t undo this message.');
    } finally {
      if (mounted && _owner.isCurrent) {
        setState(() => _pendingActions.remove(pending.id));
      }
    }
  }

  void _restoreUndone(UndoneSend restored, void Function(String) say) {
    final text = restored.text.trim();
    if (restored.attachmentName != null) {
      say(
        text.isEmpty
            ? 'Attachment removed. Attach it again to send it.'
            : 'Attachment removed. Its caption is back in the composer.',
      );
    }
    if (text.isEmpty) return;
    setState(() {
      if (_editing != null) {
        // Leave the edit buffer alone; restore into the ordinary draft.
        _normalDraft = _normalDraft.trim().isEmpty
            ? text
            : '$text\n$_normalDraft';
        _normalRevision++;
        _draftOwner?.revise();
        _draftDirty = true;
        _scheduleDraft();
        return;
      }
      // Like typing: the draft listener records and persists the text.
      final current = _draft.text;
      final merged = current.trim().isEmpty ? text : '$text\n$current';
      _draft.value = TextEditingValue(
        text: merged,
        selection: TextSelection.collapsed(offset: merged.length),
      );
      final replyId = restored.replyToId;
      if (replyId != null && _replyingTo == null) {
        final target = widget.backend.messages
            .where((entry) => entry.id == replyId && !entry.redacted)
            .firstOrNull;
        if (target != null) {
          _advanceComposerContext();
          _replyingTo = target;
        }
      }
    });
  }

  Widget _pendingPanel(AppPalette palette) {
    final pending = _features!.pendingSends
        .where((item) => item.roomId == widget.roomId)
        .toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    final undo = undoSendFeaturesOf(widget.backend);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: pending.length,
        itemBuilder: (context, index) {
          final item = pending[index];
          final busy = _pendingActions.contains(item.id);
          final active =
              item.state == DeliveryState.queued ||
              item.state == DeliveryState.sending;
          // Undo send: still inside its grace period.
          final heldUntil = item.state == DeliveryState.queued
              ? undo?.undoDeadline(item.id)
              : null;
          final statusStyle = TextStyle(color: palette.muted, fontSize: 12);
          return Padding(
            key: ValueKey('pending-${item.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.fileName ?? item.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.foreground),
                ),
                if (item.progress != null)
                  LinearProgressIndicator(value: item.progress!.clamp(0, 1)),
                Row(
                  children: [
                    Expanded(
                      child: heldUntil != null
                          // Undo send: "Sending in 4 s · Undo".
                          ? Row(
                              children: [
                                Flexible(
                                  child: HeldSendCountdown(
                                    deadline: heldUntil,
                                    builder: (context, seconds) => Text(
                                      'Sending in $seconds s ·',
                                      style: statusStyle,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: busy || _sending
                                      ? null
                                      : () => _undoPending(item),
                                  child: const Text('Undo'),
                                ),
                              ],
                            )
                          : item.state == DeliveryState.failed
                          // Says why; tap for the full error.
                          ? GestureDetector(
                              key: ValueKey('pending-reason-${item.id}'),
                              onTap: () => _showSendError(item),
                              child: Text(
                                'Not sent: '
                                '${pendingFailureReason(item.error)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: statusStyle.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            )
                          : Text(switch (item.state) {
                              DeliveryState.queued => 'Queued',
                              DeliveryState.sending => 'Sending…',
                              DeliveryState.failed => 'Not sent',
                              DeliveryState.sent => 'Sent',
                            }, style: statusStyle),
                    ),
                    if (item.state == DeliveryState.failed)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _pendingAction(item, 'retry'),
                        child: const Text('Retry'),
                      ),
                    if (heldUntil == null)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _pendingAction(
                                item,
                                active ? 'cancel' : 'discard',
                              ),
                        child: Text(active ? 'Cancel' : 'Discard'),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static int _backgroundDecodeSize(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final longest = size.width > size.height ? size.width : size.height;
    return (longest * MediaQuery.devicePixelRatioOf(context)).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final preferences = FeatureSettingsScope.maybeOf(context)?.preferences;
    final compact = preferences?.compact ?? false;
    final composerContext = _composerContext;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final room = _currentRoom;
        final entries = widget.backend.activeRoomId == widget.roomId
            ? widget.backend.messages
            : const <ChatEntry>[];
        final roomCtx = _roomContext(room);
        // Per-room bubble colours (header menu → Bubble colours).
        return BubbleColoursScope(
          colours: _bubbleColours,
          child: Scaffold(
            body: GlowBackdrop(
              palette: p,
              imageLayer: _background == null
                  ? null
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image(
                          // Decoded no larger than the screen's longer side
                          // (still enough to cover it): the stored picture
                          // is the gallery original, and a 12 MP photo is
                          // ~48 MB decoded, pushing avatars and thumbnails
                          // out of the image cache.
                          image: ResizeImage(
                            FileImage(_background!),
                            width: _backgroundDecodeSize(context),
                            height: _backgroundDecodeSize(context),
                            policy: ResizeImagePolicy.fit,
                          ),
                          key: ValueKey(_backgroundVersion),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              ColoredBox(color: p.background),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                p.background.withValues(alpha: 0.94),
                                p.background.withValues(alpha: 0.73),
                                p.background.withValues(alpha: 0.58),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              child: SafeArea(
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: p.surface.withValues(
                          alpha: _background == null ? 0.9 : 0.4,
                        ),
                        border: Border(bottom: BorderSide(color: p.stroke)),
                      ),
                      padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back to rooms',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          if (room == null)
                            InitialAvatar(
                              name: widget.roomId,
                              palette: p,
                              size: 42,
                            )
                          else
                            RoomAvatar(
                              room: room,
                              backend: widget.backend,
                              palette: p,
                              size: 42,
                            ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  room?.name ?? widget.roomId,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 17,
                                    color: p.foreground,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Row(
                                  children: [
                                    Icon(
                                      room?.encrypted == true
                                          ? Icons.lock_outline
                                          : Icons.lock_open_outlined,
                                      size: 13,
                                      color: p.secondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        room?.encrypted == true
                                            ? 'Encrypted room'
                                            : 'Encryption not enabled',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: p.muted,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          ...roomHeaderActionsFor(context, roomCtx),
                          IconButton(
                            tooltip: 'Room details',
                            icon: Icon(
                              Icons.info_outline_rounded,
                              color: p.secondary,
                            ),
                            onPressed: _opening || _error != null
                                ? null
                                : () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => RoomDetailsScreen(
                                          backend: widget.backend,
                                          palette: widget.palette,
                                          roomId: widget.roomId,
                                        ),
                                      ),
                                    );
                                  },
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Room background',
                            enabled: !_backgroundBusy,
                            icon: Icon(
                              Icons.wallpaper_outlined,
                              color: p.secondary,
                            ),
                            onSelected: (value) {
                              if (value == 'bubbles') {
                                unawaited(
                                  _openBubbleColours(room?.name ?? 'this room'),
                                );
                              } else if (value == 'choose') {
                                _chooseBackground();
                              } else {
                                _clearBackground();
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'bubbles',
                                child: Text('Bubble colours…'),
                              ),
                              const PopupMenuItem(
                                value: 'choose',
                                child: Text('Choose background'),
                              ),
                              if (_background != null)
                                const PopupMenuItem(
                                  value: 'clear',
                                  child: Text('Remove background'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    ...roomBannersFor(context, roomCtx),
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _opening
                              ? Center(
                                  child: CircularProgressIndicator(
                                    color: p.accent,
                                  ),
                                )
                              : _error != null
                              ? Center(
                                  child: Text(
                                    _error!,
                                    style: TextStyle(color: p.foreground),
                                  ),
                                )
                              : entries.isEmpty
                              ? GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragStart:
                                      widget.backend.canLoadOlder
                                      ? (_) {
                                          _emptyPullDistance = 0;
                                          _emptyPullTriggered = false;
                                          _emptyPullArmed =
                                              widget.backend.canLoadOlder &&
                                              !widget.backend.loadingHistory &&
                                              !_loadingOlder;
                                        }
                                      : null,
                                  onVerticalDragUpdate:
                                      widget.backend.canLoadOlder
                                      ? (details) {
                                          final dy = details.delta.dy;
                                          if (dy < 0 ||
                                              !_emptyPullArmed ||
                                              !widget.backend.canLoadOlder ||
                                              widget.backend.loadingHistory) {
                                            if (dy < 0) _emptyPullDistance = 0;
                                            return;
                                          }
                                          if (_emptyPullTriggered) return;
                                          _emptyPullDistance += dy;
                                          if (_emptyPullDistance >=
                                              pullToLoadOlderThreshold) {
                                            _emptyPullTriggered = true;
                                            _emptyPullDistance = 0;
                                            unawaited(_loadOlder());
                                          }
                                        }
                                      : null,
                                  onVerticalDragEnd: widget.backend.canLoadOlder
                                      ? (_) {
                                          _emptyPullDistance = 0;
                                          _emptyPullTriggered = false;
                                          _emptyPullArmed = false;
                                        }
                                      : null,
                                  onVerticalDragCancel:
                                      widget.backend.canLoadOlder
                                      ? () {
                                          _emptyPullDistance = 0;
                                          _emptyPullTriggered = false;
                                          _emptyPullArmed = false;
                                        }
                                      : null,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        BrandMark(palette: p, size: 53),
                                        const SizedBox(height: 18),
                                        Text(
                                          'Start something good.',
                                          style: TextStyle(
                                            color: p.foreground,
                                            fontSize: 21,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Messages in this room will appear here.',
                                          style: TextStyle(color: p.muted),
                                        ),
                                        if (widget.backend.canLoadOlder) ...[
                                          const SizedBox(height: 14),
                                          TextButton(
                                            onPressed:
                                                widget.backend.loadingHistory
                                                ? null
                                                : _loadOlder,
                                            child: Text(
                                              widget.backend.loadingHistory
                                                  ? 'Loading…'
                                                  : 'Load earlier messages',
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                )
                              : TimelineView(
                                  backend: widget.backend,
                                  roomId: widget.roomId,
                                  palette: p,
                                  entries: entries,
                                  compact: compact,
                                  room: room,
                                  onHeart: _heart,
                                  onAction: _showActions,
                                  onReaction: _react,
                                  onReply: _replyToEntry,
                                  onLoadOlder: _loadOlder,
                                ),
                          // Chat effects and other full-screen overlays.
                          ...roomOverlaysFor(context, roomCtx),
                        ],
                      ),
                    ),
                    if (_features != null) _pendingPanel(p),
                    if (_draftReadFailed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Saved draft unavailable. Not overwriting storage.',
                              ),
                            ),
                            TextButton(
                              onPressed: _loadDraft,
                              child: const Text('Retry draft'),
                            ),
                          ],
                        ),
                      ),
                    if (widget.backend.typingUsers.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 5, 18, 5),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${widget.backend.typingUsers.take(2).join(', ')} typing…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.secondary, fontSize: 12),
                          ),
                        ),
                      ),
                    if (_features != null) ...[
                      RichMessageComposer(
                        extraAttachments: [
                          ComposerAttachmentAction(
                            id: 'media.photo-gallery',
                            icon: Icons.photo_library_outlined,
                            label: 'Photo gallery',
                            onSelected: (context) => pickAndSendImages(
                              context,
                              widget.backend,
                              widget.roomId,
                            ),
                          ),
                          ...composerAttachmentsFor(context, roomCtx),
                        ],
                        mentionSource: richTimelineMentionSource(roomCtx),
                        hookContext: roomCtx,
                        replyToId: _replyingTo?.id,
                        editing: _editing != null,
                        contextLabel: _editing != null
                            ? 'Editing: ${_editing!.body}'
                            : _replyingTo != null
                            ? 'Replying to ${_replyingTo!.senderLabel}: ${_replyingTo!.body}'
                            : null,
                        controller: _draft,
                        sendContext: _sendContext,
                        onAcknowledged: (textCleared) =>
                            _acknowledgeComposer(composerContext, textCleared),
                        sending:
                            _sending ||
                            widget.backend.isRoomSending(widget.roomId) ||
                            !_owner.isCurrent,
                        onChanged: _onDraftChanged,
                        onSend: _sendContent,
                        onCancel: _replyingTo != null || _editing != null
                            ? _cancelComposerContext
                            : null,
                      ),
                    ] else
                      Container(
                        decoration: BoxDecoration(
                          color: p.surface,
                          border: Border(top: BorderSide(color: p.stroke)),
                        ),
                        padding: EdgeInsets.fromLTRB(
                          14,
                          12,
                          14,
                          12 + MediaQuery.paddingOf(context).bottom * 0.25,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'Attach file',
                              onPressed:
                                  widget.backend.isRoomSending(widget.roomId)
                                  ? null
                                  : () => pickAndSendAttachment(
                                      context,
                                      widget.backend,
                                      widget.roomId,
                                    ),
                              icon: Icon(
                                Icons.attach_file_rounded,
                                color: p.secondary,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Attach photos',
                              onPressed:
                                  widget.backend.isRoomSending(widget.roomId)
                                  ? null
                                  : () => pickAndSendImages(
                                      context,
                                      widget.backend,
                                      widget.roomId,
                                    ),
                              icon: Icon(
                                Icons.add_photo_alternate_outlined,
                                color: p.secondary,
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_replyingTo != null || _editing != null)
                                    Container(
                                      padding: const EdgeInsets.fromLTRB(
                                        12,
                                        6,
                                        4,
                                        6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: p.surface,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                              top: Radius.circular(18),
                                            ),
                                        border: Border(
                                          top: BorderSide(color: p.stroke),
                                          left: BorderSide(color: p.stroke),
                                          right: BorderSide(color: p.stroke),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            _editing == null
                                                ? Icons.reply_rounded
                                                : Icons.edit_outlined,
                                            size: 18,
                                            color: p.secondary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _editing == null
                                                  ? 'Replying to ${_replyingTo!.senderLabel}: ${_replyingTo!.body}'
                                                  : 'Editing: ${_editing!.body}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: p.foreground,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: 'Cancel reply or edit',
                                            visualDensity:
                                                VisualDensity.compact,
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 32,
                                                  height: 32,
                                                ),
                                            padding: EdgeInsets.zero,
                                            onPressed: _cancelComposerContext,
                                            icon: const Icon(
                                              Icons.close_rounded,
                                              size: 18,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  TextField(
                                    controller: _draft,
                                    onChanged: _onDraftChanged,
                                    minLines: 1,
                                    maxLines: 5,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    keyboardType: TextInputType.multiline,
                                    onSubmitted: (_) => _send(),
                                    decoration: InputDecoration(
                                      hintText: 'Write a message…',
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 13,
                                          ),
                                      border:
                                          _replyingTo != null ||
                                              _editing != null
                                          ? OutlineInputBorder(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    bottom: Radius.circular(18),
                                                  ),
                                              borderSide: BorderSide(
                                                color: p.stroke,
                                              ),
                                            )
                                          : null,
                                      enabledBorder:
                                          _replyingTo != null ||
                                              _editing != null
                                          ? OutlineInputBorder(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    bottom: Radius.circular(18),
                                                  ),
                                              borderSide: BorderSide(
                                                color: p.stroke,
                                              ),
                                            )
                                          : null,
                                      focusedBorder:
                                          _replyingTo != null ||
                                              _editing != null
                                          ? OutlineInputBorder(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    bottom: Radius.circular(18),
                                                  ),
                                              borderSide: BorderSide(
                                                color: p.accent,
                                                width: 1.4,
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 9),
                            IconButton.filled(
                              tooltip: 'Send message',
                              style: IconButton.styleFrom(
                                backgroundColor: p.accent,
                                foregroundColor: p.accentOn,
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: widget.backend.sending ? null : _send,
                              icon: widget.backend.sending
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: p.accentOn,
                                      ),
                                    )
                                  : const Icon(Icons.arrow_upward_rounded),
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
    );
  }
}

const _moreReactions = '__more_reactions__';

/// Six quick reactions, ordered by the user's setting (most used by default,
/// or recent, or a manual list). The full picker remains available through
/// the + button.
class _QuickReactions extends StatefulWidget {
  const _QuickReactions({
    required this.palette,
    required this.onPick,
    this.onMore,
  });
  final AppPalette palette;
  final ValueChanged<String> onPick;
  final VoidCallback? onMore;

  @override
  State<_QuickReactions> createState() => _QuickReactionsState();
}

class _QuickReactionsState extends State<_QuickReactions> {
  List<String> _emojis = defaultQuickEmojis.take(6).toList();

  @override
  void initState() {
    super.initState();
    unawaited(_loadEmojis());
  }

  Future<void> _loadEmojis() async {
    final emojis = await resolveQuickReactions();
    if (!mounted) return;
    setState(() => _emojis = emojis.take(6).toList());
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final emoji in _emojis)
          IconButton(
            tooltip: 'React $emoji',
            onPressed: () => widget.onPick(emoji),
            icon: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
        if (widget.onMore != null)
          IconButton(
            tooltip: 'More reactions',
            onPressed: widget.onMore,
            icon: Icon(
              Icons.add_reaction_outlined,
              color: widget.palette.secondary,
            ),
          ),
      ],
    ),
  );
}
