import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import '../../room_details.dart';
import '../../widgets.dart';
import '../rooms_admin/admin_ui.dart';
import '../rooms_admin/roles_permissions_screen.dart';
import '../rooms_admin/rooms_admin_features.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

/// Element X LeaveSpace: choose which of the Space's rooms to leave too.
/// Rooms where the user is the only administrator are not selectable; when
/// the user is the Space's only administrator they are warned and offered
/// "Choose admins" first. Pops true once the Space was left.
class LeaveSpaceScreen extends StatefulWidget {
  const LeaveSpaceScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.spaceId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String spaceId;

  @override
  State<LeaveSpaceScreen> createState() => _LeaveSpaceScreenState();
}

class _LeaveSpaceScreenState extends State<LeaveSpaceScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  LeaveSpacePlan? _plan;
  final _selected = <String>{};
  bool _loading = false;
  bool _leaving = false;
  String? _error;
  int _generation = 0;

  SpacesAdminFeatures? get _spaces => spacesAdminFeaturesOf(widget.backend);
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
    final spaces = _spaces;
    if (spaces == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final plan = await spaces.leavePlan(widget.spaceId);
      if (_current && generation == _generation) {
        setState(() {
          _plan = plan;
          // Element X selects every room that can be left by default.
          _selected
            ..clear()
            ..addAll(plan.selectable.map((room) => room.id));
        });
      }
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() {
          _plan = null;
          _error = 'Couldn’t load this space’s rooms. Check your connection.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _chooseAdmins(RoomDetails details) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeRolesScreen(
          backend: widget.backend,
          palette: widget.palette,
          details: details,
          role: RoomRole.admin,
        ),
      ),
    );
    if (_current) await _load();
  }

  Future<void> _leave(LeaveSpacePlan plan) async {
    final spaces = _spaces;
    if (spaces == null || _leaving || !_owner.isCurrent) return;
    if (plan.lastAdmin) {
      final confirmed = await confirmAction(
        context,
        title: 'Leave anyway?',
        message:
            'You’re the only administrator of ${plan.spaceName}. If you '
            'leave, nobody will be able to change its settings or manage its '
            'rooms.',
        confirm: 'Leave anyway',
        destructive: true,
      );
      if (!confirmed || !_current) return;
    }
    final rooms = [
      for (final room in plan.selectable)
        if (_selected.contains(room.id)) room.id,
    ];
    setState(() => _leaving = true);
    try {
      await spaces.leaveSpaceAndRooms(widget.spaceId, rooms);
      if (mounted && _owner.isCurrent) Navigator.pop(context, true);
    } on LeaveSpaceFailure catch (failure) {
      if (!mounted || !_owner.isCurrent) return;
      final name = failure.roomId == widget.spaceId
          ? plan.spaceName
          : plan.rooms
                    .where((room) => room.id == failure.roomId)
                    .firstOrNull
                    ?.name ??
                failure.roomId;
      showAdminMessage(context, 'Couldn’t leave $name. Try again.');
      setState(() => _leaving = false);
      await _load();
    } catch (_) {
      if (!mounted || !_owner.isCurrent) return;
      showAdminMessage(context, 'Couldn’t leave the space. Try again.');
      setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final plan = _plan;
    return AdminPage(
      palette: p,
      title: 'Leave space',
      busy: _loading || _leaving,
      body: _spaces == null
          ? AdminPlaceholder(
              palette: p,
              icon: Icons.workspaces_outline,
              title: 'Spaces are unavailable for this account.',
            )
          : plan == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Couldn’t prepare to leave',
                    message: _error,
                    onRetry: _load,
                  ))
          : _body(plan),
    );
  }

  Widget _body(LeaveSpacePlan plan) {
    final p = widget.palette;
    final selectable = plan.selectable;
    final adminRooms = plan.adminRooms;
    final count = selectable.where((r) => _selected.contains(r.id)).length;
    final allSelected = count == selectable.length;
    final idle = !_loading && !_leaving;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Text(
            plan.lastAdmin
                ? 'You are the only administrator for ${plan.spaceName}'
                : 'Leave ${plan.spaceName}?',
            style: TextStyle(
              color: p.foreground,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (plan.lastAdmin)
          AdminSection(
            palette: p,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFFF6B5E),
                ),
                title: Text(
                  'You need to assign another administrator for this space '
                  'before you can leave.',
                  style: TextStyle(color: p.foreground),
                ),
                subtitle: Text(
                  'Otherwise nobody will be able to manage it.',
                  style: TextStyle(color: p.muted),
                ),
              ),
              if (roomsAdminFeaturesOf(widget.backend) != null &&
                  plan.details.canChangePowerLevels)
                AdminTile(
                  palette: p,
                  icon: Icons.admin_panel_settings_outlined,
                  title: 'Choose admins',
                  onTap: idle ? () => _chooseAdmins(plan.details) : null,
                ),
            ],
          ),
        if (selectable.isNotEmpty)
          AdminSection(
            palette: p,
            title: 'Rooms',
            footer:
                'Select the rooms you’d like to leave which you’re not the '
                'only administrator for.',
            children: [
              ListTile(
                title: Text(
                  count == 1 ? '1 room selected' : '$count rooms selected',
                  style: TextStyle(color: p.muted),
                ),
                trailing: TextButton(
                  onPressed: idle
                      ? () => setState(() {
                          if (allSelected) {
                            _selected.clear();
                          } else {
                            _selected.addAll(selectable.map((r) => r.id));
                          }
                        })
                      : null,
                  child: Text(allSelected ? 'Deselect all' : 'Select all'),
                ),
              ),
              for (final room in selectable)
                CheckboxListTile(
                  value: _selected.contains(room.id),
                  onChanged: idle
                      ? (value) => setState(() {
                          if (value == true) {
                            _selected.add(room.id);
                          } else {
                            _selected.remove(room.id);
                          }
                        })
                      : null,
                  secondary: _avatar(room),
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
                    [
                      if (room.isSpace) 'Space',
                      room.members == 1
                          ? '1 member'
                          : '${room.members} members',
                    ].join(' · '),
                    style: TextStyle(color: p.muted),
                  ),
                ),
            ],
          ),
        if (adminRooms.isNotEmpty)
          AdminSection(
            palette: p,
            title: 'Rooms you’ll stay in',
            footer:
                'You will not be removed from these rooms because you’re the '
                'only administrator.',
            children: [
              for (final room in adminRooms)
                ListTile(
                  leading: _avatar(room),
                  title: Text(
                    '${room.name} (Admin)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.foreground),
                  ),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: AccentButton(
            palette: p,
            icon: Icons.logout_rounded,
            label: plan.lastAdmin
                ? 'Leave anyway'
                : count == 0
                ? 'Leave space'
                : count == 1
                ? 'Leave 1 room and space'
                : 'Leave $count rooms and space',
            onPressed: idle ? () => _leave(plan) : null,
          ),
        ),
      ],
    );
  }

  Widget _avatar(LeaveSpaceRoom room) => RoomAvatar(
    room: ChatRoom(
      id: room.id,
      name: room.name,
      preview: '',
      lastActivity: null,
      avatarUrl: room.avatarUrl,
      isSpace: room.isSpace,
    ),
    backend: widget.backend,
    palette: widget.palette,
    size: 40,
  );
}
