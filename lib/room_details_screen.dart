import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/rooms_admin/admin_ui.dart';
import 'features/rooms_admin/edit_room_details_screen.dart';
import 'features/rooms_admin/invite_people_screen.dart';
import 'features/rooms_admin/knock_requests_screen.dart';
import 'features/rooms_admin/leave_room.dart';
import 'features/rooms_admin/report_room_screen.dart';
import 'features/rooms_admin/roles_permissions_screen.dart';
import 'features/rooms_admin/room_members_screen.dart';
import 'features/rooms_admin/room_notifications_screen.dart';
import 'features/rooms_admin/rooms_admin_features.dart';
import 'features/rooms_admin/rooms_admin_hooks.dart' show roomsAdminCallAction;
import 'features/rooms_admin/rooms_admin_models.dart';
import 'features/rooms_admin/security_privacy_screen.dart';
import 'features/rooms_admin/share_text.dart';
import 'features/spaces_admin/space_options_sheet.dart' show openLeaveSpace;
import 'features/spaces_admin/spaces_admin_features.dart';
import 'features/spaces_admin/spaces_admin_hooks.dart';
import 'hooks/registry.dart';
import 'messaging_features.dart';
import 'room_avatar.dart';
import 'room_details.dart';

/// Element X style "Room info": header, quick actions and the room's
/// settings sections. Everything permission-related comes from a fresh server
/// state read; failures clear the controls rather than keep stale ones.
///
/// For a Space (`m.room.create` type `m.space`) this is Element X
/// SpaceSettings: room-only items (encryption, notifications, favourite,
/// calls, report and timeline sections) are hidden and leaving offers to
/// leave the Space's rooms too.
class RoomDetailsScreen extends StatefulWidget {
  const RoomDetailsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

class _RoomDetailsScreenState extends State<RoomDetailsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  RoomDetails? _details;
  RoomNotificationSettings? _notifications;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  MessagingFeatures? get _messaging => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };

  ChatRoom? get _room => [
    for (final room in widget.backend.rooms)
      if (room.id == widget.roomId) room,
  ].firstOrNull;

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
    if (_loading || _busy) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.backend.getRoomDetails(widget.roomId);
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _details = details);
        // Per-room notification rules are not meaningful for a Space.
        if (!details.isSpace) _loadNotifications(generation);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() {
          _details = null; // Never retain stale permissions on fetch failure.
          _error =
              'Couldn’t load room details. Check your connection and retry.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadNotifications(int generation) async {
    final admin = _admin;
    if (admin == null) return;
    try {
      final settings = await admin.notificationSettings(widget.roomId);
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _notifications = settings);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _notifications = null);
      }
    }
  }

  /// Runs a quick action; success is not optimistic — the server's state is
  /// shown afterwards, or a refresh error.
  Future<void> _run(String failure, Future<void> Function() action) async {
    if (_busy || _loading) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && _owner.isCurrent) showAdminMessage(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _invite() async {
    if (_details?.can(RoomAction.invite) != true || _busy) return;
    final invited = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => InvitePeopleScreen(
          backend: widget.backend,
          palette: widget.palette,
          roomId: widget.roomId,
          excluded: {
            for (final member in _details?.members ?? <RoomMemberDetails>[])
              if (member.status != RoomMemberStatus.knocking) member.id,
          },
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent) return;
    if (invited != null && invited > 0) {
      showAdminMessage(
        context,
        invited == 1 ? 'Invitation sent.' : '$invited invitations sent.',
      );
    }
    await _load();
  }

  Future<void> _share(RoomDetails details) async {
    final server = serverNameOf(widget.backend.userId);
    final alias = details.canonicalAlias;
    final link = alias != null
        ? matrixToLink(alias)
        : matrixToLink(widget.roomId, via: [?server]);
    try {
      await shareText(link, subject: details.name);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t open sharing.');
      }
    }
  }

  Future<void> _toggleFavourite() async {
    final messaging = _messaging;
    if (messaging == null) return;
    final favourite = _isFavourite;
    await _run(
      'Couldn’t update favourites. Try again.',
      () => messaging.setFavourite(widget.roomId, !favourite),
    );
  }

  bool get _isFavourite {
    try {
      return _messaging?.isFavourite(widget.roomId) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleMute() async {
    final admin = _admin;
    final settings = _notifications;
    if (admin == null || settings == null) return;
    final muted = settings.effectiveMode == RoomNotificationMode.mute;
    await _run(
      muted
          ? 'Failed unmuting this room, please try again.'
          : 'Failed muting this room, please try again.',
      () => admin.setNotificationMode(
        widget.roomId,
        muted ? null : RoomNotificationMode.mute,
      ),
    );
  }

  Future<void> _leave(RoomDetails details) async {
    if (details.isSpace && spacesAdminFeaturesOf(widget.backend) != null) {
      final left = await openLeaveSpace(
        context,
        backend: widget.backend,
        palette: widget.palette,
        spaceId: widget.roomId,
      );
      if (left && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      return;
    }
    final left = await leaveRoomFlow(
      context,
      backend: widget.backend,
      palette: widget.palette,
      details: details,
      isDirect: _room?.isDirect ?? false,
    );
    if (left && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  RoomHookContext get _hookContext => RoomHookContext(
    backend: widget.backend,
    roomId: widget.roomId,
    palette: widget.palette,
    room: _room,
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    final idle = !_busy && !_loading;
    final space = details?.isSpace ?? false;
    return AdminPage(
      palette: p,
      title: space ? 'Space settings' : 'Room info',
      backTooltip: space ? 'Back' : 'Back to room',
      busy: _loading || _busy,
      actions: [
        if (details != null && details.canEditDetails && idle)
          IconButton(
            tooltip: 'Edit details',
            onPressed: () => _push(
              EditRoomDetailsScreen(
                backend: widget.backend,
                palette: p,
                details: details,
                room: _room,
              ),
            ),
            icon: const Icon(Icons.edit_outlined),
          ),
        IconButton(
          tooltip: 'Refresh room details',
          onPressed: idle ? _load : null,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: details == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Room details unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: [
                _header(details, idle),
                ..._sections(details, idle),
                // Timeline features (pins, threads, media, polls) do not
                // apply to a Space; only Space management does.
                if (space)
                  ...spacesAdminRoomDetailsSections(context, _hookContext)
                else
                  ...roomDetailsSectionsFor(context, _hookContext),
              ],
            ),
    );
  }

  Widget _header(RoomDetails details, bool idle) {
    final p = widget.palette;
    final room = _room;
    final space = details.isSpace;
    final notifications = space ? null : _notifications;
    final call = idle && !space
        ? roomsAdminCallAction(context, _hookContext)
        : null;
    final avatarRoom = ChatRoom(
      id: widget.roomId,
      name: details.hasName ? details.name : (room?.name ?? details.name),
      preview: '',
      lastActivity: null,
      avatarUrl: details.avatarUrl ?? room?.avatarUrl,
      heroes: details.avatarUrl == null ? room?.heroes ?? const [] : const [],
      isSpace: space,
    );
    final subtitle = details.canonicalAlias ?? widget.roomId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        children: [
          RoomAvatar(
            room: avatarRoom,
            backend: widget.backend,
            palette: p,
            size: 96,
          ),
          const SizedBox(height: 14),
          Text(
            avatarRoom.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.foreground,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            details.joinedCount == 1
                ? '1 person'
                : '${details.joinedCount} people',
            style: TextStyle(color: p.muted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              if (space)
                AdminBadge(
                  palette: p,
                  icon: Icons.workspaces_outline,
                  label: 'Space',
                )
              else
                AdminBadge(
                  palette: p,
                  icon: details.encrypted
                      ? Icons.lock_outline_rounded
                      : Icons.lock_open_rounded,
                  label: details.encrypted ? 'Encrypted' : 'Not encrypted',
                  highlight: details.encrypted,
                ),
              if (details.isPublic)
                AdminBadge(
                  palette: p,
                  icon: Icons.public_rounded,
                  label: space ? 'Public space' : 'Public room',
                ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 10,
            children: [
              if (_messaging != null && !space)
                HeaderAction(
                  palette: p,
                  icon: _isFavourite
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  label: _isFavourite ? 'Unfavourite' : 'Favourite',
                  onPressed: idle ? _toggleFavourite : null,
                ),
              if (notifications != null)
                HeaderAction(
                  palette: p,
                  icon: notifications.effectiveMode == RoomNotificationMode.mute
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_none_rounded,
                  label:
                      notifications.effectiveMode == RoomNotificationMode.mute
                      ? 'Unmute'
                      : 'Mute',
                  onPressed: idle ? _toggleMute : null,
                ),
              if (call != null)
                HeaderAction(
                  palette: p,
                  icon: Icons.call_outlined,
                  label: 'Call',
                  onPressed: () => call(context),
                ),
              if (details.can(RoomAction.invite))
                HeaderAction(
                  palette: p,
                  icon: Icons.person_add_alt_1_outlined,
                  label: 'Invite',
                  onPressed: idle ? _invite : null,
                ),
              HeaderAction(
                palette: p,
                icon: Icons.share_outlined,
                label: 'Share',
                onPressed: () => _share(details),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(RoomDetails details, bool idle) {
    final p = widget.palette;
    final admin = _admin;
    final direct = _room?.isDirect ?? false;
    final space = details.isSpace;
    final notifications = _notifications;
    final knocks = details.knockRequests.length;
    return [
      if (details.topic.isNotEmpty || details.can(RoomAction.topic))
        AdminSection(
          palette: p,
          title: 'Topic',
          children: [
            if (details.topic.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    details.topic,
                    style: TextStyle(color: p.foreground, height: 1.35),
                  ),
                ),
              )
            else
              AdminTile(
                palette: p,
                icon: Icons.short_text_rounded,
                title: 'Add topic',
                onTap: idle
                    ? () => _push(
                        EditRoomDetailsScreen(
                          backend: widget.backend,
                          palette: p,
                          details: details,
                          room: _room,
                        ),
                      )
                    : null,
              ),
          ],
        ),
      AdminSection(
        palette: p,
        children: [
          AdminTile(
            palette: p,
            icon: Icons.groups_2_outlined,
            title: 'People',
            trailing: Text(
              '${details.joinedCount}',
              style: TextStyle(color: p.muted),
            ),
            onTap: idle
                ? () => _push(
                    RoomMembersScreen(
                      backend: widget.backend,
                      palette: p,
                      roomId: widget.roomId,
                    ),
                  )
                : null,
          ),
          if (!direct && details.isKnockable && details.canManageKnocks)
            AdminTile(
              palette: p,
              icon: Icons.front_hand_outlined,
              title: 'Requests to join',
              trailing: knocks == 0
                  ? null
                  : Badge(
                      label: Text('$knocks'),
                      backgroundColor: p.accent,
                      textColor: p.accentOn,
                    ),
              onTap: idle
                  ? () => _push(
                      KnockRequestsScreen(
                        backend: widget.backend,
                        palette: p,
                        roomId: widget.roomId,
                      ),
                    )
                  : null,
            ),
          if (!direct && admin != null && details.canChangePowerLevels)
            AdminTile(
              palette: p,
              icon: Icons.admin_panel_settings_outlined,
              title: 'Roles & permissions',
              onTap: idle
                  ? () => _push(
                      RolesPermissionsScreen(
                        backend: widget.backend,
                        palette: p,
                        roomId: widget.roomId,
                      ),
                    )
                  : null,
            ),
        ],
      ),
      if (!space || (admin != null && details.canManageSecurity))
        AdminSection(
          palette: p,
          children: [
            if (admin != null && !space)
              AdminTile(
                palette: p,
                icon: Icons.notifications_none_rounded,
                title: 'Notifications',
                subtitle: notifications == null
                    ? null
                    : notifications.isDefault
                    ? 'Default · ${notifications.defaultMode.label}'
                    : 'Custom · ${notifications.customMode!.label}',
                onTap: idle
                    ? () => _push(
                        RoomNotificationsScreen(
                          backend: widget.backend,
                          palette: p,
                          roomId: widget.roomId,
                        ),
                      )
                    : null,
              ),
            if (!direct && admin != null && details.canManageSecurity)
              AdminTile(
                palette: p,
                icon: Icons.shield_outlined,
                title: 'Security & privacy',
                onTap: idle
                    ? () => _push(
                        SecurityPrivacyScreen(
                          backend: widget.backend,
                          palette: p,
                          roomId: widget.roomId,
                        ),
                      )
                    : null,
              ),
          ],
        ),
      if (details.encrypted && !space)
        AdminSection(
          palette: p,
          title: 'Security',
          children: [
            AdminTile(
              palette: p,
              icon: Icons.lock_outline_rounded,
              title: 'Message encryption enabled',
              subtitle:
                  'Messages are secured with locks. Only you and the '
                  'recipients have the unique keys to unlock them.',
            ),
          ],
        ),
      AdminSection(
        palette: p,
        children: [
          if (admin != null && !space)
            AdminTile(
              palette: p,
              icon: Icons.flag_outlined,
              title: 'Report room',
              destructive: true,
              onTap: idle
                  ? () => _push(
                      ReportRoomScreen(
                        backend: widget.backend,
                        palette: p,
                        details: details,
                        isDirect: direct,
                      ),
                    )
                  : null,
            ),
          AdminTile(
            palette: p,
            icon: Icons.logout_rounded,
            title: space
                ? 'Leave space'
                : direct
                ? 'Leave conversation'
                : 'Leave room',
            destructive: true,
            onTap: idle ? () => _leave(details) : null,
          ),
        ],
      ),
    ];
  }
}
