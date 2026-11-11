import 'package:flutter/material.dart';

import '../../room_details.dart';
import 'admin_ui.dart';

/// Lets the user pick Admin / Moderator / Member for [member]. Returns the
/// new power level, or null when cancelled. Irreversible changes (promoting
/// to your own level, demoting yourself) need a second confirmation, with
/// Element X wording.
Future<int?> chooseRole(
  BuildContext context, {
  required RoomDetails details,
  required RoomMemberDetails member,
}) async {
  final options = [
    for (final role in const [
      RoomRole.admin,
      RoomRole.moderator,
      RoomRole.member,
    ])
      if (role.powerLevel == member.powerLevel ||
          details.canSetPowerLevel(member, role.powerLevel))
        role,
  ];
  if (options.isEmpty) return null;
  final chosen = await showDialog<RoomRole>(
    context: context,
    builder: (_) =>
        _RoleDialog(name: member.name, options: options, current: member.role),
  );
  if (chosen == null || chosen.powerLevel == member.powerLevel) return null;
  if (!context.mounted) return null;
  final self = member.id == details.ownUserId;
  if (self && chosen.powerLevel < member.powerLevel) {
    final confirmed = await confirmAction(
      context,
      title: 'Demote yourself?',
      message:
          'You will not be able to undo this change as you are demoting '
          'yourself. If you are the last privileged user in the room it will '
          'be impossible to regain privileges.',
      confirm: 'Demote',
      destructive: true,
    );
    return confirmed ? chosen.powerLevel : null;
  }
  if (!self && chosen.powerLevel >= details.ownPowerLevel) {
    final confirmed = await confirmAction(
      context,
      title: 'Add Admin?',
      message:
          'You will not be able to undo this action. You are promoting the '
          'user to have the same power level as you.',
      confirm: 'Add Admin',
    );
    return confirmed ? chosen.powerLevel : null;
  }
  return chosen.powerLevel;
}

class _RoleDialog extends StatefulWidget {
  const _RoleDialog({
    required this.name,
    required this.options,
    required this.current,
  });
  final String name;
  final List<RoomRole> options;
  final RoomRole current;

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  late RoomRole _role = widget.current;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Role for ${widget.name}'),
    content: RadioGroup<RoomRole>(
      groupValue: _role,
      onChanged: (role) => setState(() => _role = role ?? _role),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final role in widget.options)
            RadioListTile<RoomRole>(
              value: role,
              contentPadding: EdgeInsets.zero,
              title: Text(role.label),
              subtitle: Text(switch (role) {
                RoomRole.admin => 'Full control of the room.',
                RoomRole.moderator => 'Can remove people and messages.',
                _ => 'Can chat and take part.',
              }),
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
        onPressed: () => Navigator.pop(context, _role),
        child: const Text('Save'),
      ),
    ],
  );
}
