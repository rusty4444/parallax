import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../room_details.dart';
import '../../room_screen.dart';
import 'admin_ui.dart';
import 'member_moderation.dart';
import 'role_change.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_hooks.dart' show roomsAdminCallAction;
import 'rooms_admin_models.dart';
import 'share_text.dart';

/// Element X user profile: identity, verification, message, block, and —
/// when opened from a room — that room's role and moderation actions.
class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.userId,
    this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String userId;
  final String? roomId;

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  UserProfileDetails? _profile;
  RoomDetails? _room;
  bool _loading = false;
  bool _busy = false;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  bool get _self => widget.userId == widget.backend.userId;
  bool get _current => mounted && _owner.isCurrent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final admin = _admin;
    final roomId = widget.roomId;
    try {
      final profile = admin == null
          ? UserProfileDetails(userId: widget.userId)
          : await admin.userProfile(widget.userId, roomId: roomId);
      if (!mounted || !_owner.isCurrent || generation != _generation) return;
      setState(() => _profile = profile);
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _profile = UserProfileDetails(userId: widget.userId));
      }
    }
    if (roomId != null) {
      try {
        final details = await widget.backend.getRoomDetails(roomId);
        if (mounted && _owner.isCurrent && generation == _generation) {
          setState(() => _room = details);
        }
      } catch (_) {
        // Moderation stays hidden without fresh permissions.
        if (mounted && _owner.isCurrent && generation == _generation) {
          setState(() => _room = null);
        }
      }
    }
    if (mounted && generation == _generation) {
      setState(() => _loading = false);
    }
  }

  String get _name => _profile?.label ?? widget.userId;

  Future<void> _message() async {
    if (_busy || _self) return;
    final admin = _admin;
    final existing = admin?.existingDirectChat(widget.userId);
    if (existing == null) {
      final confirmed = await confirmAction(
        context,
        title: 'Start chat',
        message: 'Start a chat with $_name?',
        confirm: 'Start chat',
      );
      if (!confirmed || !mounted || !_owner.isCurrent) return;
    }
    setState(() => _busy = true);
    try {
      String? roomId = existing;
      if (roomId == null) {
        if (admin != null) {
          roomId = await admin.startDirectChat(widget.userId);
        } else {
          await widget.backend.createDirectChat(widget.userId);
          roomId = widget.backend.activeRoomId;
        }
      }
      if (!mounted || !_owner.isCurrent || roomId == null) return;
      final navigator = Navigator.of(context);
      navigator.popUntil((route) => route.isFirst);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => RoomScreen(
            backend: widget.backend,
            palette: widget.palette,
            roomId: roomId!,
          ),
        ),
      );
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(
          context,
          'An error occurred when trying to start a chat.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    try {
      await shareText(matrixToLink(widget.userId));
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t open sharing.');
      }
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.backend.startVerification(widget.userId);
      if (mounted && _owner.isCurrent) {
        showAdminMessage(
          context,
          'Verification request sent. Follow the prompts to compare emoji.',
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t start verification.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleBlock() async {
    final admin = _admin;
    if (admin == null || _busy || _self) return;
    final blocked = admin.isIgnored(widget.userId);
    final confirmed = await confirmAction(
      context,
      title: blocked ? 'Unblock user' : 'Block user',
      message: blocked
          ? 'You’ll be able to see all messages from them again.'
          : 'Blocked users won’t be able to send you messages and all their '
                'messages will be hidden. You can unblock them anytime.',
      confirm: blocked ? 'Unblock' : 'Block',
      destructive: !blocked,
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    setState(() => _busy = true);
    try {
      await admin.setIgnored(widget.userId, !blocked);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(
          context,
          blocked ? 'Couldn’t unblock this user.' : 'Couldn’t block this user.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeRole(
    RoomDetails details,
    RoomMemberDetails member,
  ) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    final level = await chooseRole(context, details: details, member: member);
    if (level == null || !mounted || !_owner.isCurrent) return;
    setState(() => _busy = true);
    try {
      await admin.setMemberPowerLevels(details.roomId, {member.id: level});
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t change the role.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _moderate(
    RoomDetails details,
    RoomMemberDetails member,
    MemberChoice choice,
  ) async {
    if (_busy) return;
    final done = await moderateFromChoice(
      context,
      backend: widget.backend,
      roomId: details.roomId,
      member: member,
      choice: choice,
      onBusy: (busy) {
        if (mounted) setState(() => _busy = busy);
      },
    );
    if (done && _current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final admin = _admin;
    final profile = _profile;
    final verification = admin?.verificationOf(widget.userId);
    final blocked = admin?.isIgnored(widget.userId) ?? false;
    final dm = admin?.existingDirectChat(widget.userId);
    final call = dm == null || _self
        ? null
        : roomsAdminCallAction(
            context,
            RoomHookContext(backend: widget.backend, roomId: dm, palette: p),
          );
    final room = _room;
    final member = room?.member(widget.userId);
    final idle = !_busy && !_loading;
    return AdminPage(
      palette: p,
      title: 'Profile',
      busy: _loading || _busy,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              children: [
                PersonAvatar(
                  backend: widget.backend,
                  palette: p,
                  name: _name,
                  url: profile?.avatarUrl,
                  size: 96,
                ),
                const SizedBox(height: 14),
                Text(
                  _name,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.foreground,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  widget.userId,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (verification == UserVerification.verified)
                      AdminBadge(
                        palette: p,
                        icon: Icons.verified_user_outlined,
                        label: 'Verified',
                        highlight: true,
                      ),
                    if (verification == UserVerification.unverified && !_self)
                      AdminBadge(
                        palette: p,
                        icon: Icons.shield_outlined,
                        label: 'Not verified',
                      ),
                    if (member != null && member.role != RoomRole.member)
                      RoleBadge(role: member.role, palette: p),
                    if (blocked)
                      AdminBadge(
                        palette: p,
                        icon: Icons.block_rounded,
                        label: 'Blocked',
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    if (!_self)
                      HeaderAction(
                        palette: p,
                        icon: Icons.chat_bubble_outline_rounded,
                        label: 'Message',
                        onPressed: idle ? _message : null,
                      ),
                    if (call != null)
                      HeaderAction(
                        palette: p,
                        icon: Icons.call_outlined,
                        label: 'Call',
                        onPressed: () => call(context),
                      ),
                    HeaderAction(
                      palette: p,
                      icon: Icons.share_outlined,
                      label: 'Share',
                      onPressed: _share,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!_self)
            AdminSection(
              palette: p,
              children: [
                if (verification != UserVerification.verified)
                  AdminTile(
                    palette: p,
                    icon: Icons.verified_outlined,
                    title: 'Verify $_name',
                    subtitle: 'Compare emoji to confirm it’s really them.',
                    onTap: idle ? _verify : null,
                  ),
                if (admin != null)
                  AdminTile(
                    palette: p,
                    icon: blocked ? Icons.undo_rounded : Icons.block_rounded,
                    title: blocked ? 'Unblock user' : 'Block user',
                    destructive: !blocked,
                    onTap: idle ? _toggleBlock : null,
                  ),
              ],
            ),
          if (room != null && member != null)
            ..._roomSection(room, member, idle),
        ],
      ),
    );
  }

  List<Widget> _roomSection(
    RoomDetails room,
    RoomMemberDetails member,
    bool idle,
  ) {
    final p = widget.palette;
    final canRole =
        _admin != null &&
        RoomRole.values.any(
          (role) =>
              role != RoomRole.owner &&
              role.powerLevel != member.powerLevel &&
              room.canSetPowerLevel(member, role.powerLevel),
        );
    final actions = <Widget>[
      AdminTile(
        palette: p,
        icon: Icons.admin_panel_settings_outlined,
        title: 'Role',
        subtitle: member.role.label,
        trailing: canRole ? const Icon(Icons.chevron_right_rounded) : null,
        onTap: canRole && idle ? () => _changeRole(room, member) : null,
      ),
      if (!_self && room.can(RoomAction.kick, member))
        AdminTile(
          palette: p,
          icon: Icons.person_remove_outlined,
          title: 'Remove from room',
          onTap: idle ? () => _moderate(room, member, MemberChoice.kick) : null,
        ),
      if (!_self && room.can(RoomAction.ban, member))
        AdminTile(
          palette: p,
          icon: Icons.block_rounded,
          title: 'Ban from room',
          destructive: true,
          onTap: idle ? () => _moderate(room, member, MemberChoice.ban) : null,
        ),
      if (!_self && room.can(RoomAction.unban, member))
        AdminTile(
          palette: p,
          icon: Icons.undo_rounded,
          title: 'Unban',
          onTap: idle
              ? () => _moderate(room, member, MemberChoice.unban)
              : null,
        ),
    ];
    return [AdminSection(palette: p, title: 'In this room', children: actions)];
  }
}
