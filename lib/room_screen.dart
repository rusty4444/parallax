import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'app_theme.dart';
import 'attachment_picker.dart';
import 'chat_backend.dart';
import 'gallery_bubble.dart';
import 'message_image.dart';
import 'message_groups.dart';
import 'photo_picker.dart';
import 'room_avatar.dart';
import 'room_background_store.dart';
import 'widgets.dart';

class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.backgroundStore,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final RoomBackgroundStore? backgroundStore;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final _draft = TextEditingController();
  Timer? _typingStopTimer;
  DateTime? _lastTypingSent;
  bool _typing = false;
  ChatEntry? _replyingTo;
  ChatEntry? _editing;
  late final _backgroundStore = widget.backgroundStore ?? RoomBackgroundStore();
  File? _background;
  int _backgroundVersion = 0;
  bool _backgroundBusy = false;
  bool _opening = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBackground();
    _open();
  }

  Future<void> _loadBackground() async {
    try {
      final file = await _backgroundStore.fileFor(widget.roomId);
      if (mounted) setState(() => _background = file);
    } catch (_) {
      if (mounted) _showBackgroundError();
    }
  }

  void _showBackgroundError() => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Couldn’t update this room’s background.')),
  );

  Future<void> _chooseBackground() async {
    if (_backgroundBusy) return;
    try {
      final selection = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (selection == null || !mounted) return;
      setState(() => _backgroundBusy = true);
      final file = await _backgroundStore.replace(widget.roomId, selection);
      await FileImage(file).evict();
      if (mounted) {
        setState(() {
          _background = file;
          _backgroundVersion++;
        });
      }
    } catch (_) {
      if (mounted) _showBackgroundError();
    } finally {
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _clearBackground() async {
    if (_backgroundBusy) return;
    setState(() => _backgroundBusy = true);
    try {
      await _backgroundStore.clear(widget.roomId);
      if (mounted) setState(() => _background = null);
    } catch (_) {
      if (mounted) _showBackgroundError();
    } finally {
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _open() async {
    try {
      await widget.backend.openRoom(widget.roomId);
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load this room.');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _typingStopTimer?.cancel();
    _stopTyping();
    widget.backend.closeRoom(widget.roomId);
    _draft.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _draft.text.trim();
    if (body.isEmpty || widget.backend.sending) return;
    final reply = _replyingTo;
    final edit = _editing;
    try {
      await widget.backend.sendText(
        widget.roomId,
        body,
        replyToId: reply?.id,
        editEventId: edit?.id,
      );
      if (mounted && _draft.text.trim() == body) {
        _draft.clear();
        setState(() {
          _replyingTo = null;
          _editing = null;
        });
        _stopTyping();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message not sent. Try again.')),
        );
      }
    }
  }

  Future<void> _heart(ChatEntry entry) async {
    await _react(entry, '❤️');
  }

  Future<void> _react(ChatEntry entry, String emoji) async {
    try {
      await widget.backend.react(widget.roomId, entry.id, emoji: emoji);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t react to this message.')),
        );
      }
    }
  }

  void _onDraftChanged(String text) {
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
    _lastTypingSent = null;
    unawaited(
      widget.backend.setTyping(widget.roomId, false).catchError((Object _) {}),
    );
  }

  Future<void> _showActions(ChatEntry entry) async {
    if (entry.redacted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(sheetContext, 'reply'),
            ),
            for (final emoji in ['❤️', '👍', '😂', '🎉', '😮'])
              ListTile(
                leading: Text(emoji, style: const TextStyle(fontSize: 23)),
                title: Text('React $emoji'),
                onTap: () => Navigator.pop(sheetContext, emoji),
              ),
            if (entry.mine && !entry.isImage && !entry.isAttachment)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit message'),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
            if (entry.mine)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete message'),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'reply') {
      setState(() {
        _replyingTo = entry;
        _editing = null;
      });
    } else if (choice == 'edit') {
      _draft.text = entry.body;
      _draft.selection = TextSelection.collapsed(offset: _draft.text.length);
      setState(() {
        _editing = entry;
        _replyingTo = null;
      });
    } else if (choice == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete this message?'),
          content: const Text(
            'This removes the message for everyone in the room.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await widget.backend.redactMessage(widget.roomId, entry.id);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn’t delete this message.')),
          );
        }
      }
    } else {
      await _react(entry, choice);
    }
  }

  Future<void> _loadOlder() async {
    try {
      await widget.backend.loadOlder(widget.roomId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load older messages.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final room = [
          for (final r in widget.backend.rooms)
            if (r.id == widget.roomId) r,
        ].firstOrNull;
        final entries = widget.backend.activeRoomId == widget.roomId
            ? widget.backend.messages
            : const <ChatEntry>[];
        final rows = groupTimeline(entries);
        return Scaffold(
          body: GlowBackdrop(
            palette: p,
            imageLayer: _background == null
                ? null
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        _background!,
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
                                  Text(
                                    room?.encrypted == true
                                        ? 'Encrypted room'
                                        : 'Encryption not enabled',
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Room background',
                          enabled: !_backgroundBusy,
                          icon: Icon(
                            Icons.wallpaper_outlined,
                            color: p.secondary,
                          ),
                          onSelected: (value) {
                            if (value == 'choose') {
                              _chooseBackground();
                            } else {
                              _clearBackground();
                            }
                          },
                          itemBuilder: (_) => [
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
                  Expanded(
                    child: _opening
                        ? Center(
                            child: CircularProgressIndicator(color: p.accent),
                          )
                        : _error != null
                        ? Center(
                            child: Text(
                              _error!,
                              style: TextStyle(color: p.foreground),
                            ),
                          )
                        : entries.isEmpty
                        ? Center(
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
                                    onPressed: widget.backend.loadingHistory
                                        ? null
                                        : _loadOlder,
                                    child: const Text('Load earlier messages'),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
                            itemCount:
                                rows.length +
                                (widget.backend.canLoadOlder ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == rows.length) {
                                return Center(
                                  child: TextButton(
                                    onPressed: widget.backend.loadingHistory
                                        ? null
                                        : _loadOlder,
                                    child: Text(
                                      widget.backend.loadingHistory
                                          ? 'Loading…'
                                          : 'Load earlier messages',
                                    ),
                                  ),
                                );
                              }
                              final row = rows[rows.length - index - 1];
                              if (row.isGallery) {
                                return GalleryBubble(
                                  key: ValueKey(row.entries.first.id),
                                  entries: row.entries,
                                  backend: widget.backend,
                                  roomId: widget.roomId,
                                  palette: p,
                                  onHeart: _heart,
                                  onAction: _showActions,
                                  onReaction: _react,
                                );
                              }
                              final entry = row.entries.single;
                              final previous = rows.length - index - 2 >= 0
                                  ? rows[rows.length - index - 2].entries.last
                                  : null;
                              final group =
                                  previous?.sender == entry.sender &&
                                  entry.time
                                          .difference(previous!.time)
                                          .inMinutes <
                                      5;
                              return _MessageBubble(
                                key: ValueKey(entry.id),
                                entry: entry,
                                backend: widget.backend,
                                roomId: widget.roomId,
                                palette: p,
                                group: group,
                                onHeart: () => _heart(entry),
                                onAction: () => _showActions(entry),
                                onReaction: (emoji) => _react(entry, emoji),
                                replyPreview: entry.replyToId == null
                                    ? null
                                    : entries
                                          .where(
                                            (item) =>
                                                item.id == entry.replyToId,
                                          )
                                          .firstOrNull,
                              );
                            },
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
                  if (_replyingTo != null || _editing != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: p.surface,
                        border: Border(top: BorderSide(color: p.stroke)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _editing == null
                                ? Icons.reply_rounded
                                : Icons.edit_outlined,
                            color: p.secondary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _editing == null
                                  ? 'Replying to ${_replyingTo!.sender}: ${_replyingTo!.body}'
                                  : 'Editing: ${_editing!.body}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.foreground),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel reply or edit',
                            onPressed: () => setState(() {
                              _replyingTo = null;
                              _editing = null;
                            }),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
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
                      children: [
                        IconButton(
                          tooltip: 'Attach file',
                          onPressed: widget.backend.sending
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
                          onPressed: widget.backend.sending
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
                          child: TextField(
                            controller: _draft,
                            onChanged: _onDraftChanged,
                            minLines: 1,
                            maxLines: 5,
                            textCapitalization: TextCapitalization.sentences,
                            keyboardType: TextInputType.multiline,
                            onSubmitted: (_) => _send(),
                            decoration: const InputDecoration(
                              hintText: 'Write a message…',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 13,
                              ),
                            ),
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
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.entry,
    required this.backend,
    required this.roomId,
    required this.palette,
    required this.group,
    required this.onHeart,
    required this.onAction,
    required this.onReaction,
    this.replyPreview,
  });
  final ChatEntry entry;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final bool group;
  final VoidCallback onHeart;
  final VoidCallback onAction;
  final ValueChanged<String> onReaction;
  final ChatEntry? replyPreview;

  @override
  Widget build(BuildContext context) {
    final mine = entry.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.83,
        ),
        child: Padding(
          padding: EdgeInsets.only(top: group ? 3 : 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? palette.bubble : palette.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(19),
                topRight: const Radius.circular(19),
                bottomLeft: Radius.circular(mine ? 19 : 5),
                bottomRight: Radius.circular(mine ? 5 : 19),
              ),
              border: mine ? null : Border.all(color: palette.stroke),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onDoubleTap: onHeart,
                    onLongPress: onAction,
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!mine && !group) ...[
                          Text(
                            entry.sender,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.secondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                        ],
                        if (entry.replyToId != null) ...[
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: palette.secondary,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Text(
                              replyPreview == null
                                  ? 'In reply to an earlier message'
                                  : '${replyPreview!.sender}: ${replyPreview!.body}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: mine
                                    ? palette.bubbleText
                                    : palette.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                        ],
                        if (entry.isImage) ...[
                          MessageImage(
                            backend: backend,
                            palette: palette,
                            roomId: roomId,
                            eventId: entry.id,
                          ),
                          const SizedBox(height: 4),
                        ],
                        if (entry.isAttachment)
                          InkWell(
                            onTap: () => saveAttachment(
                              context,
                              backend,
                              roomId,
                              entry.id,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.insert_drive_file_outlined,
                                    color: mine
                                        ? palette.bubbleText
                                        : palette.secondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      entry.body,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: mine
                                            ? palette.bubbleText
                                            : palette.foreground,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.download_rounded,
                                    size: 18,
                                    color: mine
                                        ? palette.bubbleText
                                        : palette.secondary,
                                  ),
                                ],
                              ),
                            ),
                          )
                        else if (entry.body.isNotEmpty)
                          Text(
                            entry.edited
                                ? '${entry.body} (edited)'
                                : entry.body,
                            style: TextStyle(
                              color: mine
                                  ? palette.bubbleText
                                  : palette.foreground,
                              fontSize: 15,
                              height: 1.35,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (entry.reactions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 3,
                      children: [
                        for (final reaction in entry.reactions)
                          ActionChip(
                            tooltip: reaction.mine
                                ? 'Remove your ${reaction.emoji} reaction'
                                : 'React with ${reaction.emoji}',
                            label: Text('${reaction.emoji} ${reaction.count}'),
                            backgroundColor: reaction.mine
                                ? palette.accent.withValues(alpha: 0.25)
                                : palette.background,
                            onPressed: () => onReaction(reaction.emoji),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Text(
                      TimeOfDay.fromDateTime(
                        entry.time.toLocal(),
                      ).format(context),
                      style: TextStyle(
                        fontSize: 10,
                        color: mine
                            ? palette.bubbleText.withValues(alpha: 0.77)
                            : palette.muted,
                      ),
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
}
