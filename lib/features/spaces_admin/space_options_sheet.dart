import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_details_screen.dart';
import '../../space_browser_screen.dart';
import 'create_space_screen.dart';
import 'leave_space_screen.dart';
import 'manage_space_screen.dart';

enum _SpaceOption { explore, manage, settings, leave }

/// Element X Space menu (Space switcher long-press, Space browser): explore,
/// manage rooms, settings and leave. [onOpenRoom] receives a room the user
/// opened or joined while exploring; [onLeft] runs after leaving.
Future<void> showSpaceOptionsSheet(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required String spaceId,
  required String spaceName,
  ValueChanged<String>? onOpenRoom,
  VoidCallback? onLeft,
}) async {
  final choice = await showModalBottomSheet<_SpaceOption>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final error = Theme.of(sheetContext).colorScheme.error;
      // Scrolls on short screens (landscape, large text).
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  spaceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Space'),
              ),
              if (onOpenRoom != null)
                ListTile(
                  leading: const Icon(Icons.travel_explore_rounded),
                  title: const Text('Explore rooms'),
                  onTap: () =>
                      Navigator.pop(sheetContext, _SpaceOption.explore),
                ),
              ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined),
                title: const Text('Manage rooms'),
                onTap: () => Navigator.pop(sheetContext, _SpaceOption.manage),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Space settings'),
                onTap: () => Navigator.pop(sheetContext, _SpaceOption.settings),
              ),
              ListTile(
                leading: Icon(Icons.exit_to_app_rounded, color: error),
                title: Text('Leave space', style: TextStyle(color: error)),
                onTap: () => Navigator.pop(sheetContext, _SpaceOption.leave),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return;
  final navigator = Navigator.of(context);
  switch (choice) {
    case _SpaceOption.explore:
      final roomId = await navigator.push<String>(
        MaterialPageRoute(
          builder: (_) => SpaceBrowserScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
      if (roomId != null && context.mounted) onOpenRoom?.call(roomId);
    case _SpaceOption.manage:
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ManageSpaceScreen(
            backend: backend,
            palette: palette,
            spaceId: spaceId,
          ),
        ),
      );
    case _SpaceOption.settings:
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => RoomDetailsScreen(
            backend: backend,
            palette: palette,
            roomId: spaceId,
          ),
        ),
      );
    case _SpaceOption.leave:
      final left = await openLeaveSpace(
        context,
        backend: backend,
        palette: palette,
        spaceId: spaceId,
      );
      if (left && context.mounted) onLeft?.call();
  }
}

/// Element X LeaveSpace. Returns true once the Space was left.
Future<bool> openLeaveSpace(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
  required String spaceId,
}) async {
  final left = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => LeaveSpaceScreen(
        backend: backend,
        palette: palette,
        spaceId: spaceId,
      ),
    ),
  );
  return left == true;
}

/// Element X "Create space". Returns the new Space's ID.
Future<String?> openCreateSpace(
  BuildContext context, {
  required ChatBackend backend,
  required AppPalette palette,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => CreateSpaceScreen(backend: backend, palette: palette),
  ),
);
