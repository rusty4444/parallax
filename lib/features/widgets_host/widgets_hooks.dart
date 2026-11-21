// Hook implementations for the widgets / integrations module.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'room_widgets_screen.dart';
import 'widgets_host.dart';

/// Room details → "Apps & widgets".
List<Widget> widgetsRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = widgetsFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  final count = features.roomWidgets(ctx.roomId).length;
  return [
    ListTile(
      key: const ValueKey('widgets-room-details-tile'),
      leading: const Icon(Icons.widgets_outlined),
      title: const Text('Apps & widgets'),
      subtitle: Text(
        count == 0 ? 'Integrations and custom widgets' : '$count widgets',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RoomWidgetsScreen(
            backend: ctx.backend,
            roomId: ctx.roomId,
            roomName: ctx.room?.name ?? 'this room',
            palette: ctx.palette,
            features: features,
          ),
        ),
      ),
    ),
  ];
}
