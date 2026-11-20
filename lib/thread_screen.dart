import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'features/rich_timeline/rich_timeline_hooks.dart';
import 'features/threads/event_projection.dart';
import 'features/threads/thread_features.dart';
import 'features/threads/thread_widgets.dart';
import 'features/threads/timeline_navigation.dart';
import 'hooks/hook_types.dart';
import 'media_viewer.dart';
import 'messaging_features.dart';
import 'haptics.dart';

/// A thread: its root, the replies (oldest first) and an in-thread composer.
/// Replies are sent with `m.thread` relations through the outbox; viewing the
/// thread sends a threaded read receipt for its latest reply.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.backend,
    required this.roomId,
    required this.root,
    this.palette,
  });
  final ChatBackend backend;
  final String roomId;
  final ChatEntry root;

  /// Defaults to the palette of the active app theme.
  final AppPalette? palette;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _draft = TextEditingController();
  final _composeFocus = FocusNode(debugLabel: 'ThreadComposer');
  StreamSubscription<String>? _activity;
  int _generation = 0;
  int _sendGeneration = 0;
  int _draftRevision = 0;
  bool _loading = false;
  bool _paging = false;
  bool _sending = false;
  bool _expired = false;
  String? _account;
  String? _userId;
  String? _error;
  String? _sendError;
  String? _nextBatch;
  String? _lastReceipt;
  ChatEntry? _replyingTo;
  List<ChatEntry> _replies = const [];

  /// Keys for scrolling to a reply's quoted source within the thread.
  final _entryKeys = <String, GlobalKey>{};
  GlobalKey _keyFor(String id) => _entryKeys.putIfAbsent(id, GlobalKey.new);

  MessagingFeatures? get _features => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };
  bool get _ownerCurrent =>
      !_expired &&
      _account == _features?.accountKey &&
      _userId == widget.backend.userId;
  bool _current(int generation) =>
      mounted && _ownerCurrent && generation == _generation;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_draftChanged);
    _bind();
    unawaited(_refresh());
  }

  void _bind() {
    _account = _features?.accountKey;
    _userId = widget.backend.userId;
    widget.backend.addListener(_changed);
    try {
      _activity = threadFeaturesOf(widget.backend)
          ?.threadActivity(widget.roomId)
          .where((root) => root == widget.root.id)
          .listen((_) => unawaited(_refresh(quiet: true)));
    } catch (_) {
      _activity = null;
    }
  }

  void _unbind(ChatBackend backend) {
    backend.removeListener(_changed);
    unawaited(_activity?.cancel());
    _activity = null;
  }

  void _draftChanged() {
    _draftRevision++;
  }

  void _changed() {
    if (_expired || _ownerCurrent) return;
    _generation++;
    _sendGeneration++;
    _draft.clear();
    setState(() {
      _expired = true;
      _loading = _paging = _sending = false;
      _replies = const [];
      _replyingTo = null;
      _nextBatch = _error = _sendError = null;
    });
  }

  @override
  void didUpdateWidget(covariant ThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend &&
        oldWidget.roomId == widget.roomId &&
        oldWidget.root.id == widget.root.id) {
      return;
    }
    _unbind(oldWidget.backend);
    _generation++;
    _sendGeneration++;
    _draft.clear();
    _expired = _sending = false;
    _sendError = _lastReceipt = null;
    _replyingTo = null;
    _replies = const [];
    _bind();
    unawaited(_refresh());
  }

  List<ChatEntry> _merge(Iterable<ChatEntry> entries) {
    final byId = <String, ChatEntry>{};
    for (final entry in entries) {
      if (entry.id != widget.root.id) byId[entry.id] = entry;
    }
    return byId.values.toList()..sort((a, b) {
      final time = a.time.compareTo(b.time);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
  }

  /// Loads the newest page. A [quiet] refresh (new activity, after sending)
  /// keeps the displayed replies and older-page cursor.
  Future<void> _refresh({bool quiet = false}) async {
    if (!_ownerCurrent || _features == null) return;
    if (quiet && (_loading || _paging)) return;
    final generation = ++_generation;
    setState(() {
      if (!quiet) {
        _loading = true;
        _nextBatch = null;
        _replies = const [];
      }
      _paging = false;
      _error = null;
    });
    try {
      final page = await _features!.loadThread(widget.roomId, widget.root.id);
      if (!_current(generation)) return;
      setState(() {
        if (quiet) {
          _replies = _merge([..._replies, ...page.messages]);
          _nextBatch ??= page.nextBatch;
        } else {
          _replies = _merge(page.messages);
          _nextBatch = page.nextBatch;
        }
      });
      _markRead();
    } catch (_) {
      if (_current(generation) && !quiet) {
        setState(() => _error = 'Couldn’t load this thread. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    if (!_ownerCurrent || _loading || _paging || token == null) return;
    final generation = _generation;
    setState(() {
      _paging = true;
      _error = null;
    });
    try {
      final page = await _features!.loadThread(
        widget.roomId,
        widget.root.id,
        nextBatch: token,
      );
      if (!_current(generation)) return;
      setState(() {
        // Keep already displayed entries on overlapping backwards pages.
        _replies = _merge([...page.messages, ..._replies]);
        _nextBatch = page.nextBatch == token ? null : page.nextBatch;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = 'Couldn’t load older replies. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _paging = false);
    }
  }

  /// Threaded read receipt for the latest server-acknowledged reply.
  void _markRead() {
    final threads = threadFeaturesOf(widget.backend);
    if (threads == null || !mounted || !_ownerCurrent) return;
    final latest = _replies.lastWhere(
      (entry) => entry.id.startsWith(r'$'),
      orElse: () => widget.root,
    );
    if (latest.id == widget.root.id || latest.id == _lastReceipt) return;
    _lastReceipt = latest.id;
    final public = publicReceiptsAllowed(context);
    unawaited(
      threads
          .markThreadRead(
            widget.roomId,
            widget.root.id,
            latest.id,
            public: public,
          )
          .catchError((Object _) {
            if (_lastReceipt == latest.id) _lastReceipt = null;
          }),
    );
  }

  Future<void> _send() async {
    if (!_ownerCurrent || _sending || _features == null) return;
    final text = _draft.text;
    if (text.trim().isEmpty) return;
    final revision = _draftRevision;
    final reply = _replyingTo;
    final generation = ++_sendGeneration;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await _features!.queueMessage(
        widget.roomId,
        text,
        replyToId: reply?.id,
        threadRootId: widget.root.id,
      );
      if (!mounted || !_ownerCurrent || generation != _sendGeneration) return;
      if (_draftRevision == revision) _draft.clear();
      if (identical(_replyingTo, reply)) setState(() => _replyingTo = null);
      unawaited(_refresh(quiet: true));
    } catch (_) {
      if (mounted && _ownerCurrent && generation == _sendGeneration) {
        setState(
          () => _sendError =
              'Couldn’t send this reply. Your draft is kept; tap send to retry.',
        );
      }
    } finally {
      if (mounted && _ownerCurrent && generation == _sendGeneration) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _actions(ChatEntry entry) async {
    if (!mounted || !_ownerCurrent || entry.redacted) return;
    Haptics.longPress();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.id != widget.root.id && entry.id.startsWith(r'$'))
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Quote in reply'),
                onTap: () => Navigator.pop(sheetContext, 'reply'),
              ),
            if (entry.body.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Copy text'),
                onTap: () => Navigator.pop(sheetContext, 'copy'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !_ownerCurrent || choice == null) return;
    if (choice == 'reply') {
      setState(() => _replyingTo = entry);
      _scheduleComposeFocus();
    } else if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: entry.body));
    }
  }

  @override
  void dispose() {
    _generation++;
    _sendGeneration++;
    _unbind(widget.backend);
    _draft.removeListener(_draftChanged);
    _draft.dispose();
    _composeFocus.dispose();
    super.dispose();
  }

  void _scheduleComposeFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ownerCurrent) _composeFocus.requestFocus();
    });
  }

  ChatRoom? get _room {
    try {
      for (final room in widget.backend.rooms) {
        if (room.id == widget.roomId) return room;
      }
    } catch (_) {
      // Minimal backends may not project rooms.
    }
    return null;
  }

  String get _roomName => _room?.name ?? '';

  /// Tapping a reply quote goes to the original message: scroll to it when
  /// it is loaded in this thread, otherwise focus the room timeline on it
  /// (the search/permalink jump) and leave the thread.
  Future<void> _jumpToQuoted(String replyToId) async {
    final sourceContext = _entryKeys[replyToId]?.currentContext;
    if (sourceContext != null) {
      await Scrollable.ensureVisible(
        sourceContext,
        alignment: 0.2,
        duration: const Duration(milliseconds: 250),
      );
      return;
    }
    final navigation = timelineNavigationOf(widget.backend);
    if (navigation == null || !replyToId.startsWith(r'$')) return;
    if (navigation.focusedEventIn(widget.roomId) == replyToId) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await navigation.openRoomAt(widget.roomId, replyToId);
      if (mounted) navigator.pop();
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Couldn’t jump to that message.')),
        );
      }
    }
  }

  Widget _bubble(AppPalette p, ChatEntry entry, {bool root = false}) {
    final mine = entry.mine && !root;
    final textColor = mine ? p.bubbleText : p.foreground;
    final hook = EntryHookContext(
      backend: widget.backend,
      roomId: widget.roomId,
      palette: p,
      entry: entry,
      room: _room,
      entries: _replies,
    );
    final quoted = entry.replyToId == null
        ? null
        : [
            widget.root,
            ..._replies,
          ].where((item) => item.id == entry.replyToId).firstOrNull;
    final hasMedia = !entry.redacted && (entry.isImage || entry.isAttachment);
    final body = entry.redacted
        ? Text(
            'Message removed',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontStyle: FontStyle.italic,
            ),
          )
        : entry.body.isEmpty && !hasMedia
        ? Text('Message', style: TextStyle(color: textColor))
        : buildMessageText(
            context,
            hook,
            style: TextStyle(color: textColor, fontSize: 15, height: 1.35),
          );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: root
              ? double.infinity
              : MediaQuery.sizeOf(context).width * 0.83,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => _actions(entry),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: mine ? p.bubble : p.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(19),
                  topRight: const Radius.circular(19),
                  bottomLeft: Radius.circular(mine || root ? 19 : 5),
                  bottomRight: Radius.circular(mine && !root ? 5 : 19),
                ),
                border: mine
                    ? null
                    : Border.all(
                        color: root
                            ? p.accent.withValues(alpha: 0.6)
                            : p.stroke,
                      ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!mine)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          entry.senderLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    if (entry.replyToId != null)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _jumpToQuoted(entry.replyToId!),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 5),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(color: p.secondary, width: 3),
                              ),
                            ),
                            child: Text(
                              quoted == null
                                  ? 'In reply to an earlier message'
                                  : '${quoted.senderLabel}: ${entryPreview(quoted)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: mine ? p.bubbleText : p.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (hasMedia)
                      InkWell(
                        onTap: () => openMediaViewer(
                          context,
                          backend: widget.backend,
                          roomId: widget.roomId,
                          eventId: entry.id,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                entry.isImage
                                    ? Icons.image_outlined
                                    : Icons.insert_drive_file_outlined,
                                color: mine ? p.bubbleText : p.secondary,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  entryPreview(entry),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: textColor),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      body,
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Text(
                        MaterialLocalizations.of(context).formatTimeOfDay(
                          TimeOfDay.fromDateTime(entry.time.toLocal()),
                        ),
                        style: TextStyle(
                          fontSize: 10,
                          color: mine
                              ? p.bubbleText.withValues(alpha: 0.77)
                              : p.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider(AppPalette p) {
    final count = _replies.length > widget.root.threadReplyCount
        ? _replies.length
        : widget.root.threadReplyCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: p.stroke)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              count == 0 ? 'Replies' : replyCountLabel(count),
              style: TextStyle(
                color: p.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Divider(color: p.stroke)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteFromTheme(context, widget.palette);
    final roomName = _roomName;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: p.surface.withValues(alpha: 0.9),
                  border: Border(bottom: BorderSide(color: p.stroke)),
                ),
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Icon(Icons.forum_rounded, color: p.accent, size: 20),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Thread',
                            style: TextStyle(
                              color: p.foreground,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (roomName.isNotEmpty)
                            Text(
                              roomName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.muted, fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _expired || _features == null
                          ? null
                          : _refresh,
                      icon: Icon(Icons.refresh_rounded, color: p.secondary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _expired
                    ? Center(
                        child: Text(
                          'Account changed. Reopen this thread.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : _features == null
                    ? Center(
                        child: Text(
                          'Threads are unavailable for this account.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : _thread(p),
              ),
              if (!_expired && _features != null) _composer(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thread(AppPalette p) => RefreshIndicator(
    onRefresh: _refresh,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      // Keep every loaded reply built so a quote can scroll to its source
      // even when it is far off screen (GlobalKey lookup needs a live
      // element). Threads are paginated, so this stays bounded.
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000000),
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        KeyedSubtree(
          key: _keyFor(widget.root.id),
          child: _bubble(p, widget.root, root: true),
        ),
        _divider(p),
        if (_loading)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(color: p.accent)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.foreground),
                ),
                TextButton(
                  onPressed: _nextBatch == null ? _refresh : _more,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        if (_nextBatch != null && !_paging && !_loading)
          Center(
            child: TextButton(
              onPressed: _more,
              child: const Text('Load older replies'),
            ),
          ),
        if (_paging)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(color: p.accent)),
          ),
        if (!_loading && _replies.isEmpty && _error == null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'No replies yet. Start the conversation.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted),
            ),
          ),
        for (final entry in _replies)
          KeyedSubtree(key: _keyFor(entry.id), child: _bubble(p, entry)),
      ],
    ),
  );

  Widget _composer(AppPalette p) => Container(
    decoration: BoxDecoration(
      color: p.surface.withValues(alpha: 0.92),
      border: Border(top: BorderSide(color: p.stroke)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_replyingTo case final reply?)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 6, 0),
            child: Row(
              children: [
                Icon(Icons.reply_rounded, size: 16, color: p.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Replying to ${reply.senderLabel}: ${entryPreview(reply)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel reply',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _replyingTo = null),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
          ),
        if (_sendError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _sendError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _draft,
                  focusNode: _composeFocus,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Reply in thread',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Send reply',
                onPressed: _sending ? null : _send,
                icon: Icon(
                  _sending ? Icons.hourglass_top_rounded : Icons.send_rounded,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
