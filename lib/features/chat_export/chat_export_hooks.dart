// Hook implementations for the chat-export module.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'chat_export_features.dart';
import 'chat_export_screen.dart';

/// Room details → "Export chat".
List<Widget> chatExportRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = chatExportFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  return [
    ListTile(
      key: const ValueKey('chat-export-tile'),
      leading: const Icon(Icons.ios_share_outlined),
      title: const Text('Export chat'),
      subtitle: const Text('Save the conversation as text, HTML or ZIP'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChatExportScreen(
            features: features,
            roomId: ctx.roomId,
            roomName: ctx.room?.name ?? 'this room',
            palette: ctx.palette,
          ),
        ),
      ),
    ),
  ];
}
