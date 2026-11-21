// Hook implementations for the on-device catch-up module.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'catch_up.dart';
import 'catch_up_sheet.dart';

/// Minimum unread messages before offering a catch-up summary.
const catchUpThreshold = 10;

/// A banner offering an on-device summary of a busy unread room.
List<Widget> catchUpRoomBanners(BuildContext context, RoomHookContext ctx) {
  final room = ctx.room;
  if (room == null || room.invited || room.unread < catchUpThreshold) {
    return const [];
  }
  return [
    _CatchUpBanner(
      key: ValueKey('catch-up.banner.${ctx.roomId}'),
      backend: ctx.backend,
      roomId: ctx.roomId,
      roomName: room.name,
      unread: room.unread,
      palette: ctx.palette,
    ),
  ];
}

class _CatchUpBanner extends StatelessWidget {
  const _CatchUpBanner({
    super.key,
    required this.backend,
    required this.roomId,
    required this.roomName,
    required this.unread,
    required this.palette,
  });

  final ChatBackend backend;
  final String roomId;
  final String roomName;
  final int unread;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        color: p.raised.withValues(alpha: 0.94),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
        ),
        child: InkWell(
          key: const ValueKey('catch-up.banner'),
          onTap: () {
            final summary = summarizeCatchUp(
              backend.messages.take(unread).toList(),
              backend.userId,
            );
            showCatchUpSheet(
              context,
              summary: summary,
              roomName: roomName,
              palette: p,
            );
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 18, color: p.secondary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Catch up on $unread unread messages',
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: p.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
