// Hook implementations for the Space administration feature module.
//
// Create Spaces, manage children, Space settings and leaving.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import '../rooms_admin/admin_ui.dart';
import 'manage_space_screen.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

/// Room details sections (for example "Manage rooms" when the room is a Space,
/// or "Add to Space" for ordinary rooms).
List<Widget> spacesAdminRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final spaces = spacesAdminFeaturesOf(ctx.backend);
  if (spaces == null) return const [];
  try {
    final room = ctx.room;
    if (room?.isSpace ?? spaces.isJoinedSpace(ctx.roomId)) {
      return [_SpaceRoomsSection(ctx: ctx)];
    }
    if (room == null || room.isDirect || room.invited) return const [];
    final targets = spaces.spacesAcceptingChild(ctx.roomId);
    if (targets.isEmpty) return const [];
    return [_AddToSpaceSection(ctx: ctx, targets: targets)];
  } catch (_) {
    return const []; // A malformed cached Space must not break room info.
  }
}

class _SpaceRoomsSection extends StatelessWidget {
  const _SpaceRoomsSection({required this.ctx});
  final RoomHookContext ctx;

  @override
  Widget build(BuildContext context) => AdminSection(
    palette: ctx.palette,
    title: 'Rooms',
    children: [
      AdminTile(
        palette: ctx.palette,
        icon: Icons.dashboard_customize_outlined,
        title: 'Manage rooms',
        subtitle: 'Add, remove, suggest and reorder this space’s rooms',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ManageSpaceScreen(
              backend: ctx.backend,
              palette: ctx.palette,
              spaceId: ctx.roomId,
              showSettings: false,
            ),
          ),
        ),
      ),
    ],
  );
}

class _AddToSpaceSection extends StatefulWidget {
  const _AddToSpaceSection({required this.ctx, required this.targets});
  final RoomHookContext ctx;
  final List<SpaceRef> targets;

  @override
  State<_AddToSpaceSection> createState() => _AddToSpaceSectionState();
}

class _AddToSpaceSectionState extends State<_AddToSpaceSection> {
  bool _busy = false;

  Future<void> _add() async {
    final ctx = widget.ctx;
    final spaces = spacesAdminFeaturesOf(ctx.backend);
    if (spaces == null || _busy) return;
    final userId = ctx.backend.userId;
    final space = await showModalBottomSheet<SpaceRef>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text(
                'Add to space',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('Adding a room will not affect the room access.'),
            ),
            for (final target in widget.targets)
              ListTile(
                leading: const Icon(Icons.workspaces_outline),
                title: Text(
                  target.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, target),
              ),
          ],
        ),
      ),
    );
    if (space == null || !mounted || ctx.backend.userId != userId) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = (await spaces.addChildren(space.id, [ctx.roomId])).isEmpty;
    } catch (_) {
      ok = false;
    }
    if (!mounted || ctx.backend.userId != userId) return;
    setState(() => _busy = false);
    showAdminMessage(
      context,
      ok
          ? 'Added to ${space.name}.'
          : 'Couldn’t add the room to ${space.name}. Try again.',
    );
  }

  @override
  Widget build(BuildContext context) => AdminSection(
    palette: widget.ctx.palette,
    children: [
      AdminTile(
        palette: widget.ctx.palette,
        icon: Icons.workspaces_outline,
        title: 'Add to space',
        trailing: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: _busy ? null : _add,
      ),
    ],
  );
}
