// Opens matrix.to / matrix: links inside Parallax (Element X
// libraries/deeplink + features/joinroom + user profile "Message").
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_join_dialog.dart';
import '../../room_screen.dart';
import '../../widgets.dart';
import 'matrix_links.dart';
import 'platform_features.dart';

/// Opens [uri] in Parallax when it is a Matrix permalink (matrix.to, Element
/// web style or `matrix:`). Returns false when [uri] is not a Matrix link, so
/// the caller can fall back to the browser. Returns true once the link has
/// been handled, including when the user cancels or opening fails (the user
/// has already seen why).
///
/// Room links open the room when joined; otherwise a preview offers to join
/// (aliases are resolved, `via` servers are used). User links offer to start
/// or reopen a direct chat. Event permalinks currently open their room.
Future<bool> openMatrixLink(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  Uri uri,
) async {
  final link = parseMatrixLink(uri);
  if (link == null) return false;
  if (!context.mounted) return true;
  switch (link) {
    case MatrixUserLink():
      await _openUserLink(context, backend, palette, link);
    case MatrixRoomLink():
      await _openRoomLink(context, backend, palette, link);
  }
  return true;
}

/// Pushes the room screen for links and shares. Tests replace it to observe
/// navigation without building a full room.
void Function(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String roomId,
)
openRoomRoute = _pushRoom;

void _pushRoom(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  String roomId,
) {
  unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            RoomScreen(backend: backend, palette: palette, roomId: roomId),
      ),
    ),
  );
}

void _snack(BuildContext context, String message) => ScaffoldMessenger.maybeOf(
  context,
)?.showSnackBar(SnackBar(content: Text(message)));

Future<void> _openRoomLink(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  MatrixRoomLink link,
) async {
  final owner = BackendSessionOwner(backend);
  try {
    if (!link.isAlias) {
      for (final room in backend.rooms) {
        if (room.id == link.roomIdOrAlias && !room.invited) {
          openRoomRoute(context, backend, palette, room.id);
          return;
        }
      }
    }
    final features = platformFeaturesOf(backend);
    if (features == null) {
      // Older backends: only room IDs can be joined, through the core dialog.
      if (link.isAlias) {
        _snack(context, 'Room addresses can’t be opened in this session.');
        return;
      }
      final id = await showRoomJoin(context, backend, link.roomIdOrAlias);
      if (id != null && context.mounted && owner.isCurrent) {
        openRoomRoute(context, backend, palette, id);
      }
      return;
    }
    final roomId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RoomLinkSheet(
        backend: backend,
        features: features,
        palette: palette,
        link: link,
      ),
    );
    if (roomId != null && context.mounted && owner.isCurrent) {
      openRoomRoute(context, backend, palette, roomId);
    }
  } finally {
    owner.release();
  }
}

Future<void> _openUserLink(
  BuildContext context,
  ChatBackend backend,
  AppPalette palette,
  MatrixUserLink link,
) async {
  if (link.userId == backend.userId) {
    _snack(context, 'That link is to your own account.');
    return;
  }
  final owner = BackendSessionOwner(backend);
  try {
    final roomId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UserLinkSheet(
        backend: backend,
        features: platformFeaturesOf(backend),
        palette: palette,
        userId: link.userId,
      ),
    );
    if (roomId != null && context.mounted && owner.isCurrent) {
      openRoomRoute(context, backend, palette, roomId);
    }
  } finally {
    owner.release();
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.palette, required this.children});
  final AppPalette palette;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: palette.stroke,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          ...children,
        ],
      ),
    ),
  );
}

/// Preview and join for a room the user opened from a link.
class RoomLinkSheet extends StatefulWidget {
  const RoomLinkSheet({
    super.key,
    required this.backend,
    required this.features,
    required this.palette,
    required this.link,
  });
  final ChatBackend backend;
  final PlatformFeatures features;
  final AppPalette palette;
  final MatrixRoomLink link;

  @override
  State<RoomLinkSheet> createState() => _RoomLinkSheetState();
}

enum _RoomStage { loading, preview, invited, joining, failed }

class _RoomLinkSheetState extends State<RoomLinkSheet> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  _RoomStage _stage = _RoomStage.loading;
  ResolvedRoom? _resolved;
  RoomLinkPreview? _preview;
  String? _error;
  int _generation = 0;

  bool _current(int generation) =>
      mounted && generation == _generation && _owner.isCurrent;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_sessionChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    widget.backend.removeListener(_sessionChanged);
    _owner.release();
    super.dispose();
  }

  bool _closed = false;

  void _sessionChanged() {
    if (!mounted || _closed || _owner.isCurrent) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _stage = _RoomStage.loading;
      _error = null;
    });
    final link = widget.link;
    ResolvedRoom? resolved;
    try {
      resolved = await widget.features.resolveRoom(
        link.roomIdOrAlias,
        via: link.via,
      );
    } catch (_) {
      if (!_current(generation)) return;
      // Joining by alias can still succeed when the directory is unreachable.
    }
    if (!mounted || !_current(generation)) return;
    if (resolved != null) {
      switch (widget.features.membership(resolved.roomId)) {
        case LinkedRoomMembership.joined:
          Navigator.of(context).pop(resolved.roomId);
          return;
        case LinkedRoomMembership.invited:
          setState(() {
            _resolved = resolved;
            _stage = _RoomStage.invited;
          });
          return;
        case LinkedRoomMembership.none:
          break;
      }
    }
    RoomLinkPreview? preview;
    try {
      preview = await widget.features.previewRoom(
        resolved?.roomId ?? link.roomIdOrAlias,
        via: resolved?.via ?? link.via,
      );
    } catch (_) {
      preview = null;
    }
    if (!_current(generation)) return;
    if (resolved == null && preview == null && link.isAlias) {
      setState(() {
        _stage = _RoomStage.failed;
        _error =
            'Couldn’t find ${link.roomIdOrAlias}. Check the address or try '
            'again later.';
      });
      return;
    }
    setState(() {
      _resolved = resolved;
      _preview = preview;
      _stage = _RoomStage.preview;
    });
  }

  Future<void> _join() async {
    final generation = ++_generation;
    setState(() {
      _stage = _RoomStage.joining;
      _error = null;
    });
    final link = widget.link;
    try {
      final roomId = await widget.features.joinRoom(
        _resolved?.roomId ?? link.roomIdOrAlias,
        via: _resolved?.via ?? link.via,
      );
      if (!mounted || !_current(generation)) return;
      Navigator.of(context).pop(roomId);
    } catch (error) {
      if (!_current(generation)) return;
      setState(() {
        _stage = _RoomStage.preview;
        _error = _joinError(error);
      });
    }
  }

  Future<void> _accept() async {
    final roomId = _resolved?.roomId;
    if (roomId == null) return;
    final generation = ++_generation;
    setState(() {
      _stage = _RoomStage.joining;
      _error = null;
    });
    try {
      await widget.backend.acceptInvite(roomId);
      if (!mounted || !_current(generation)) return;
      Navigator.of(context).pop(roomId);
    } catch (_) {
      if (!_current(generation)) return;
      setState(() {
        _stage = _RoomStage.invited;
        _error = 'Couldn’t accept the invitation. Try again.';
      });
    }
  }

  static String _joinError(Object error) {
    if (error is TimeoutException) {
      return 'Joining is taking longer than expected. The room will appear in '
          'your list once your server confirms it.';
    }
    if (error is matrix.MatrixException) {
      if (error.errcode == 'M_FORBIDDEN') {
        return 'You can’t join this room. It may need an invitation.';
      }
      if (error.errcode == 'M_NOT_FOUND' ||
          error.errcode == 'M_UNKNOWN' &&
              error.errorMessage.contains('No known servers')) {
        return 'This room couldn’t be found from your server.';
      }
    }
    return 'Couldn’t join this room. Check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final link = widget.link;
    final preview = _preview;
    final title =
        preview?.name ??
        preview?.alias ??
        (link.isAlias ? link.roomIdOrAlias : 'Room');
    final subtitle =
        preview?.alias ?? (link.isAlias ? null : _shortId(link.roomIdOrAlias));
    final busy = _stage == _RoomStage.loading || _stage == _RoomStage.joining;
    return _SheetFrame(
      palette: p,
      children: [
        Eyebrow(
          preview?.isSpace == true ? 'Space link' : 'Room link',
          palette: p,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            InitialAvatar(
              name: title.replaceFirst(RegExp(r'^[#!]'), ''),
              palette: p,
              size: 56,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null && subtitle != title)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                  if (preview?.members case final members?)
                    Text(
                      members == 1 ? '1 member' : '$members members',
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (preview?.topic case final topic?) ...[
          const SizedBox(height: 12),
          Text(
            topic,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.foreground.withValues(alpha: 0.85)),
          ),
        ],
        if (link.eventId != null) ...[
          const SizedBox(height: 10),
          Text(
            'This link points to a message in this room.',
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
        ],
        if (_stage == _RoomStage.preview && preview?.joinRule == 'invite') ...[
          const SizedBox(height: 10),
          Text(
            'This room is invite-only, so joining may not work without an '
            'invitation.',
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
        ],
        if (_stage == _RoomStage.invited) ...[
          const SizedBox(height: 10),
          Text(
            'You’ve been invited to this room.',
            style: TextStyle(color: p.muted),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(_error!, style: TextStyle(color: p.accent)),
          ),
        ],
        const SizedBox(height: 20),
        if (busy)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: CircularProgressIndicator(color: p.accent),
            ),
          )
        else if (_stage == _RoomStage.failed)
          AccentButton(
            palette: p,
            label: 'Try again',
            icon: Icons.refresh_rounded,
            onPressed: () => unawaited(_load()),
          )
        else if (_stage == _RoomStage.invited)
          AccentButton(
            palette: p,
            label: 'Accept invitation',
            icon: Icons.check_rounded,
            onPressed: () => unawaited(_accept()),
          )
        else
          AccentButton(
            palette: p,
            label: preview?.isSpace == true ? 'Join space' : 'Join room',
            icon: Icons.login_rounded,
            onPressed: () => unawaited(_join()),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_stage == _RoomStage.joining ? 'Close' : 'Cancel'),
        ),
      ],
    );
  }
}

String _shortId(String id) => id.length > 28
    ? '${id.substring(0, 14)}…${id.substring(id.length - 10)}'
    : id;

/// A user's profile from a link, with a "Message" action that opens the
/// existing direct chat or starts one (Element X user profile).
class UserLinkSheet extends StatefulWidget {
  const UserLinkSheet({
    super.key,
    required this.backend,
    required this.features,
    required this.palette,
    required this.userId,
  });
  final ChatBackend backend;
  final PlatformFeatures? features;
  final AppPalette palette;
  final String userId;

  @override
  State<UserLinkSheet> createState() => _UserLinkSheetState();
}

class _UserLinkSheetState extends State<UserLinkSheet> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  LinkedUserProfile? _profile;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_sessionChanged);
    unawaited(_loadProfile());
  }

  @override
  void dispose() {
    widget.backend.removeListener(_sessionChanged);
    _owner.release();
    super.dispose();
  }

  bool _closed = false;

  void _sessionChanged() {
    if (!mounted || _closed || _owner.isCurrent) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _loadProfile() async {
    final features = widget.features;
    if (features == null) return;
    try {
      final profile = await features.userProfile(widget.userId);
      if (mounted && _owner.isCurrent) setState(() => _profile = profile);
    } catch (_) {
      // The Matrix ID is enough to start a chat.
    }
  }

  Future<void> _message() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await widget.backend.createDirectChat(widget.userId);
      if (!mounted || !_owner.isCurrent) return;
      final roomId = widget.backend.activeRoomId;
      if (roomId == null) throw StateError('No direct chat');
      Navigator.of(context).pop(roomId);
    } catch (_) {
      if (!mounted || !_owner.isCurrent) return;
      setState(() {
        _starting = false;
        _error = 'Couldn’t start this conversation. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final label = _profile?.label ?? widget.userId;
    return _SheetFrame(
      palette: p,
      children: [
        Eyebrow('Matrix user', palette: p),
        const SizedBox(height: 14),
        Row(
          children: [
            InitialAvatar(
              name: label.replaceFirst('@', ''),
              palette: p,
              size: 56,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (label != widget.userId)
                    Text(
                      widget.userId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: p.accent)),
        ],
        const SizedBox(height: 20),
        if (_starting)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: CircularProgressIndicator(color: p.accent),
            ),
          )
        else
          AccentButton(
            palette: p,
            label: 'Message',
            icon: Icons.chat_bubble_outline_rounded,
            onPressed: () => unawaited(_message()),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
