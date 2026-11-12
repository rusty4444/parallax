import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'role_change.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Roles & permissions": admins, moderators, own role and the
/// power level required for common actions.
class RolesPermissionsScreen extends StatefulWidget {
  const RolesPermissionsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<RolesPermissionsScreen> createState() => _RolesPermissionsScreenState();
}

class _RolesPermissionsScreenState extends State<RolesPermissionsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  RoomDetails? _details;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.backend.getRoomDetails(widget.roomId);
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _details = details);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() {
          _details = null;
          _error = 'Couldn’t load roles. Check your connection and retry.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _write(String failure, Future<void> Function() action) async {
    if (_busy) return;
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

  Future<void> _editRole(RoomRole role) async {
    final details = _details;
    if (details == null || _busy) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeRolesScreen(
          backend: widget.backend,
          palette: widget.palette,
          details: details,
          role: role,
        ),
      ),
    );
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _changeMyRole(RoomDetails details) async {
    final admin = _admin;
    final me = details.member(widget.backend.userId ?? '');
    if (admin == null || me == null) return;
    final level = await chooseRole(context, details: details, member: me);
    if (level == null || !mounted || !_owner.isCurrent) return;
    await _write(
      'Couldn’t change your role.',
      () => admin.setMemberPowerLevels(widget.roomId, {me.id: level}),
    );
  }

  Future<void> _editPermission(RoomDetails details, PermissionItem item) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    final current = permissionLevel(details.powerLevels, item);
    final choices = [
      for (final level in const [100, 50, 0])
        if (level <= details.ownPowerLevel) level,
    ];
    final chosen = await showDialog<int>(
      context: context,
      builder: (_) =>
          _LevelDialog(title: item.label, choices: choices, current: current),
    );
    if (chosen == null || chosen == current || !mounted || !_owner.isCurrent) {
      return;
    }
    await _write(
      'Couldn’t update this permission.',
      () => admin.setPermissionLevel(widget.roomId, item, chosen),
    );
  }

  Future<void> _reset() async {
    final admin = _admin;
    if (admin == null || _busy) return;
    final confirmed = await confirmAction(
      context,
      title: 'Reset permissions?',
      message:
          'Once you reset permissions, you will lose the current settings.',
      confirm: 'Reset',
      destructive: true,
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    await _write(
      'Couldn’t reset permissions.',
      () => admin.resetPermissions(widget.roomId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    final idle = !_busy && !_loading;
    return AdminPage(
      palette: p,
      title: 'Roles & permissions',
      busy: _loading || _busy,
      body: details == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Roles unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: _body(details, idle),
            ),
    );
  }

  List<Widget> _body(RoomDetails details, bool idle) {
    final p = widget.palette;
    final active = [
      for (final member in details.members)
        if (member.status == RoomMemberStatus.joined ||
            member.status == RoomMemberStatus.invited)
          member,
    ];
    final owners = active.where((m) => m.role == RoomRole.owner).length;
    final admins = active.where((m) => m.role == RoomRole.admin).length;
    final moderators = active.where((m) => m.role == RoomRole.moderator).length;
    final me = details.member(widget.backend.userId ?? '');
    final canChangeMine =
        me != null &&
        !(details.creatorsOutrank && me.creator) &&
        me.role != RoomRole.member &&
        details.canChangePowerLevels;
    return [
      AdminSection(
        palette: p,
        title: 'Roles',
        children: [
          if (owners > 0)
            AdminTile(
              palette: p,
              icon: Icons.workspace_premium_outlined,
              title: 'Owners',
              trailing: Text('$owners', style: TextStyle(color: p.muted)),
            ),
          AdminTile(
            palette: p,
            icon: Icons.shield_moon_outlined,
            title: 'Admins',
            trailing: Text('$admins', style: TextStyle(color: p.muted)),
            onTap: idle ? () => _editRole(RoomRole.admin) : null,
          ),
          AdminTile(
            palette: p,
            icon: Icons.gavel_rounded,
            title: 'Moderators',
            trailing: Text('$moderators', style: TextStyle(color: p.muted)),
            onTap: idle ? () => _editRole(RoomRole.moderator) : null,
          ),
          if (canChangeMine)
            AdminTile(
              palette: p,
              icon: Icons.person_outline_rounded,
              title: 'Change my role',
              subtitle: me.role.label,
              onTap: idle ? () => _changeMyRole(details) : null,
            ),
        ],
      ),
      for (final (title, items) in permissionSections)
        AdminSection(
          palette: p,
          title: title,
          children: [
            for (final item in items)
              AdminTile(
                palette: p,
                title: item.label,
                subtitle: roleLevelLabel(
                  permissionLevel(details.powerLevels, item),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap:
                    idle &&
                        permissionLevel(details.powerLevels, item) <=
                            details.ownPowerLevel
                    ? () => _editPermission(details, item)
                    : null,
              ),
          ],
        ),
      AdminSection(
        palette: p,
        children: [
          AdminTile(
            palette: p,
            icon: Icons.restart_alt_rounded,
            title: 'Reset permissions',
            destructive: true,
            onTap: idle ? _reset : null,
          ),
        ],
      ),
    ];
  }
}

class _LevelDialog extends StatefulWidget {
  const _LevelDialog({
    required this.title,
    required this.choices,
    required this.current,
  });
  final String title;
  final List<int> choices;
  final int current;

  @override
  State<_LevelDialog> createState() => _LevelDialogState();
}

class _LevelDialogState extends State<_LevelDialog> {
  late int _level = widget.current;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: RadioGroup<int>(
      groupValue: _level,
      onChanged: (level) => setState(() => _level = level ?? _level),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final level in widget.choices)
            RadioListTile<int>(
              value: level,
              contentPadding: EdgeInsets.zero,
              title: Text(roleLevelLabel(level)),
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
        onPressed: () => Navigator.pop(context, _level),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Element X "Edit Admins" / "Edit Moderators": tick who holds the role.
class ChangeRolesScreen extends StatefulWidget {
  const ChangeRolesScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.details,
    required this.role,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final RoomDetails details;
  final RoomRole role;

  @override
  State<ChangeRolesScreen> createState() => _ChangeRolesScreenState();
}

class _ChangeRolesScreenState extends State<ChangeRolesScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _query = TextEditingController();
  late final Set<String> _initial = {
    for (final member in _candidates)
      if (_holds(member)) member.id,
  };
  late final Set<String> _selected = {..._initial};
  bool _saving = false;

  List<RoomMemberDetails> get _candidates => [
    for (final member in widget.details.members)
      if (member.status == RoomMemberStatus.joined ||
          member.status == RoomMemberStatus.invited)
        member,
  ];

  bool _holds(RoomMemberDetails member) =>
      member.powerLevel >= widget.role.powerLevel;

  /// Higher roles imply this one and cannot be unticked here.
  bool _locked(RoomMemberDetails member) =>
      member.role.index < widget.role.index ||
      !widget.details.canSetPowerLevel(
        member,
        _holds(member) ? 0 : widget.role.powerLevel,
      );

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _owner.release();
    _query.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final admin = roomsAdminFeaturesOf(widget.backend);
    if (admin == null || _saving) return;
    final changes = <String, int>{
      for (final id in _selected.difference(_initial))
        id: widget.role.powerLevel,
      for (final id in _initial.difference(_selected)) id: 0,
    };
    if (changes.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final promotingPeers = changes.entries.any(
      (entry) => entry.value >= widget.details.ownPowerLevel && entry.value > 0,
    );
    if (promotingPeers) {
      final confirmed = await confirmAction(
        context,
        title: 'Add Admin?',
        message:
            'You will not be able to undo this action. You are promoting the '
            'user to have the same power level as you.',
        confirm: 'Add Admin',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      await admin.setMemberPowerLevels(widget.details.roomId, changes);
      if (mounted && _owner.isCurrent) Navigator.pop(context);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t save role changes.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final term = _query.text.trim().toLowerCase();
    final members = [
      for (final member in _candidates)
        if (term.isEmpty ||
            member.name.toLowerCase().contains(term) ||
            member.id.toLowerCase().contains(term))
          member,
    ]..sort((a, b) => b.powerLevel.compareTo(a.powerLevel));
    final dirty =
        _selected.length != _initial.length || !_selected.containsAll(_initial);
    return AdminPage(
      palette: p,
      title: widget.role == RoomRole.admin ? 'Edit Admins' : 'Edit Moderators',
      busy: _saving,
      actions: [
        TextButton(
          onPressed: dirty && !_saving ? _save : null,
          child: const Text('Save'),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Search people',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
            child: Text(
              widget.role == RoomRole.admin
                  ? 'Owners automatically have admin privileges.'
                  : 'Admins automatically have moderator privileges.',
              style: TextStyle(color: p.muted, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: members.length,
              itemBuilder: (context, index) {
                final member = members[index];
                final locked = _locked(member) || _saving;
                return CheckboxListTile(
                  value: _selected.contains(member.id),
                  onChanged: locked
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(member.id);
                          } else {
                            _selected.remove(member.id);
                          }
                        }),
                  secondary: PersonAvatar(
                    backend: widget.backend,
                    palette: p,
                    name: member.name,
                    url: member.avatarUrl,
                    size: 40,
                  ),
                  title: Text(
                    member.status == RoomMemberStatus.invited
                        ? '${member.name} (Pending)'
                        : member.name,
                    style: TextStyle(color: p.foreground),
                  ),
                  subtitle: Text(
                    '${member.id} · ${member.role.label}',
                    style: TextStyle(color: p.muted),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
