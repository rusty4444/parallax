// Receive shares from other apps (Element X features/share): pick a joined
// room, then queue the shared text and up to ten files through the normal
// outbox so encryption, recipient trust and retries apply. A share aimed at a
// suggested chat (share_shortcuts.dart) offers that chat for one-tap sending.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../messaging_features.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';
import 'platform_intents.dart';

typedef SharedFileReader = Future<Uint8List> Function(SharedFile file);

Future<Uint8List> _readSharedFile(SharedFile file) async {
  final handle = File(file.path);
  final length = await handle.length();
  if (length <= 0 || length > maxSharedFileBytes) {
    throw ArgumentError('Shared file is empty or too large');
  }
  final bytes = await handle.readAsBytes();
  if (bytes.isEmpty || bytes.length > maxSharedFileBytes) {
    throw ArgumentError('Shared file is empty or too large');
  }
  return bytes;
}

@immutable
class ShareSendResult {
  const ShareSendResult({
    required this.sent,
    required this.failed,
    required this.textSent,
  });
  final int sent;
  final int failed;
  final bool textSent;
  bool get complete => failed == 0;
}

class ShareSessionChanged implements Exception {
  const ShareSessionChanged();
}

/// Queues [share] into [roomId]. Files go first (a single file carries the
/// text as its caption, as Element X does); otherwise the text follows as its
/// own message. Throws [ShareSessionChanged] if the account changes.
Future<ShareSendResult> sendSharedContent(
  ChatBackend backend,
  String roomId,
  ShareIntent share, {
  required bool Function() isCurrent,
  SharedFileReader read = _readSharedFile,
}) async {
  final text = share.text?.trim();
  final hasText = text != null && text.isNotEmpty;
  final files = share.files.take(maxSharedFiles).toList();
  final captionFirst = hasText && files.length == 1;
  final features = backend is MessagingFeatures
      ? backend as MessagingFeatures
      : null;
  var sent = 0;
  var failed = 0;
  var textSent = false;
  void check() {
    if (!isCurrent()) throw const ShareSessionChanged();
  }

  for (final file in files) {
    check();
    try {
      if (features != null) {
        final bytes = await read(file);
        check();
        await features.queueMedia(
          roomId,
          MediaSelection(
            bytes: bytes,
            name: file.name,
            mimeType: file.mimeType,
          ),
          caption: captionFirst ? text : null,
        );
      } else {
        await backend.sendAttachment(
          roomId,
          XFile(file.path, name: file.name, mimeType: file.mimeType),
        );
      }
      sent++;
      if (captionFirst) textSent = true;
    } on ShareSessionChanged {
      rethrow;
    } catch (_) {
      failed++;
    }
  }
  if (hasText && !textSent) {
    check();
    try {
      if (features != null) {
        await features.queueMessage(roomId, text);
      } else {
        await backend.sendText(roomId, text);
      }
      textSent = true;
    } catch (_) {
      failed++;
    }
  }
  return ShareSendResult(sent: sent, failed: failed, textSent: textSent);
}

String describeShare(ShareIntent share) {
  final files = share.files;
  if (files.isEmpty) return share.text ?? '';
  final images = files.where((f) => f.isImage).length;
  final videos = files.where((f) => f.isVideo).length;
  if (images == files.length) {
    return images == 1 ? '1 photo' : '$images photos';
  }
  if (videos == files.length) {
    return videos == 1 ? '1 video' : '$videos videos';
  }
  return files.length == 1 ? files.single.name : '${files.length} files';
}

/// Room picker for a share. Pops with the room ID after queueing.
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.share,
    this.read = _readSharedFile,
    this.targetRoomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final ShareIntent share;
  final SharedFileReader read;

  /// The chat picked in Android's share suggestions. It is offered on its own
  /// with a Send button, so one tap confirms what is sent and where; the other
  /// rooms stay listed below. Ignored when it is not a joined room.
  final String? targetRoomId;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  final _search = TextEditingController();
  String _query = '';
  String? _sendingTo;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
  }

  @override
  void dispose() {
    widget.backend.removeListener(_changed);
    _owner.release();
    _search.dispose();
    super.dispose();
  }

  bool _closed = false;

  void _changed() {
    if (!mounted) return;
    if (!_owner.isCurrent && !_closed) {
      _closed = true;
      Navigator.of(context).pop();
      return;
    }
    setState(() {});
  }

  ChatRoom? get _target {
    final id = widget.targetRoomId;
    if (id == null) return null;
    for (final room in widget.backend.rooms) {
      if (room.id == id && !room.invited) return room;
    }
    return null;
  }

  static String _describe(ChatRoom room) => [
    if (room.isDirect) 'Direct chat',
    if (room.encrypted) 'Encrypted',
  ].join(' · ');

  /// Every other joined room matching the search.
  List<ChatRoom> _roomsExcept(ChatRoom? target) {
    final query = _query.trim().toLowerCase();
    final rooms = [
      for (final room in widget.backend.rooms)
        if (!room.invited &&
            room.id != target?.id &&
            (query.isEmpty ||
                room.name.toLowerCase().contains(query) ||
                room.id.toLowerCase().contains(query)))
          room,
    ]..sort(compareRooms);
    return rooms;
  }

  Future<void> _send(ChatRoom room) async {
    if (_sendingTo != null || !_owner.isCurrent) return;
    setState(() => _sendingTo = room.id);
    try {
      final result = await sendSharedContent(
        widget.backend,
        room.id,
        widget.share,
        isCurrent: () => mounted && _owner.isCurrent,
        read: widget.read,
      );
      if (!mounted || !_owner.isCurrent) return;
      if (result.sent == 0 && !result.textSent) {
        _snack('Couldn’t share to ${room.name}. Try again.');
        setState(() => _sendingTo = null);
        return;
      }
      if (!result.complete) {
        _snack('Some items couldn’t be shared.');
      }
      _closed = true;
      Navigator.of(context).pop(room.id);
    } on ShareSessionChanged {
      // The route closes itself on account change.
    } catch (_) {
      if (!mounted || !_owner.isCurrent) return;
      _snack('Couldn’t share to ${room.name}. Try again.');
      setState(() => _sendingTo = null);
    }
  }

  void _snack(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Widget _targetCard(ChatRoom room) {
    final p = widget.palette;
    final description = _describe(room);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Material(
        color: p.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: p.accent, width: 1.5),
        ),
        child: ListTile(
          key: ValueKey('share-target-${room.id}'),
          enabled: _sendingTo == null,
          contentPadding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
          leading: RoomAvatar(
            room: room,
            backend: widget.backend,
            palette: p,
            size: 44,
          ),
          title: Text(
            room.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.foreground, fontWeight: FontWeight.w700),
          ),
          subtitle: description.isEmpty
              ? null
              : Text(
                  description,
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
          trailing: _sendingTo == room.id
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: p.accent,
                  ),
                )
              : FilledButton.icon(
                  key: const ValueKey('share-target-send'),
                  onPressed: _sendingTo == null
                      ? () => unawaited(_send(room))
                      : null,
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send'),
                ),
          onTap: () => unawaited(_send(room)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final share = widget.share;
    final target = _target;
    final rooms = _roomsExcept(target);
    final dropped = share.skipped + share.tooLarge;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Cancel',
                      onPressed: _sendingTo == null
                          ? () => Navigator.of(context).pop()
                          : null,
                      icon: const Icon(Icons.close_rounded),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Eyebrow('Share', palette: p),
                          const SizedBox(height: 2),
                          Text(
                            target == null
                                ? 'Send to a room'
                                : 'Send to ${target.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: p.stroke),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      share.files.isEmpty
                          ? Icons.notes_rounded
                          : share.files.every((f) => f.isImage)
                          ? Icons.photo_library_outlined
                          : Icons.attach_file_rounded,
                      color: p.secondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            describeShare(share),
                            maxLines: share.files.isEmpty ? 4 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (share.files.isNotEmpty && share.text != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                share.text!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: p.muted, fontSize: 13),
                              ),
                            ),
                          if (dropped > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                share.tooLarge > 0
                                    ? '$dropped item${dropped == 1 ? '' : 's'} '
                                          'left out: files must be 20 MB or '
                                          'smaller, up to $maxSharedFiles at a time.'
                                    : '$dropped item${dropped == 1 ? '' : 's'} '
                                          'couldn’t be read and will be left out.',
                                style: TextStyle(color: p.accent, fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (target != null) _targetCard(target),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: TextField(
                  controller: _search,
                  enabled: _sendingTo == null,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: target == null
                        ? 'Search rooms'
                        : 'Or send to another room',
                  ),
                ),
              ),
              if (_sendingTo != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: LinearProgressIndicator(color: p.accent),
                ),
              Expanded(
                child: rooms.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text(
                            _query.trim().isNotEmpty
                                ? 'No rooms match “${_query.trim()}”.'
                                : target != null
                                ? ''
                                : 'No rooms yet. Join or start a conversation first.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: p.muted),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
                        itemCount: rooms.length,
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          final sending = _sendingTo == room.id;
                          return ListTile(
                            key: ValueKey('share-room-${room.id}'),
                            enabled: _sendingTo == null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            leading: RoomAvatar(
                              room: room,
                              backend: widget.backend,
                              palette: p,
                              size: 44,
                            ),
                            title: Text(
                              room.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.foreground,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              _describe(room),
                              style: TextStyle(color: p.muted, fontSize: 12),
                            ),
                            trailing: sending
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: p.accent,
                                    ),
                                  )
                                : Icon(Icons.send_rounded, color: p.secondary),
                            onTap: () => unawaited(_send(room)),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
