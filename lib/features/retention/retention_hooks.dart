// Hook implementations for the disappearing-messages (retention) module.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../matrix_backend.dart';
import 'retention_features.dart';
import 'retention_model.dart';
import 'retention_screen.dart';

/// A subtle banner in rooms with a retention policy, plus a periodic refresh
/// so messages vanish while the room stays open.
List<Widget> retentionRoomBanners(BuildContext context, RoomHookContext ctx) {
  if (retentionFeaturesOf(ctx.backend) == null) return const [];
  return [
    RetentionBanner(
      key: ValueKey('retention.banner.${ctx.roomId}'),
      backend: ctx.backend,
      palette: ctx.palette,
      roomId: ctx.roomId,
      roomName: ctx.room?.name ?? 'this room',
    ),
  ];
}

/// Room details → "Disappearing messages" row.
List<Widget> retentionRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = retentionFeaturesOf(ctx.backend);
  if (features == null) return const [];
  final retention = features.cachedRetention(ctx.roomId);
  return [
    ListTile(
      key: const ValueKey('retention-room-details-tile'),
      leading: const Icon(Icons.timer_outlined),
      title: const Text('Disappearing messages'),
      subtitle: Text(
        retention == null || !retention.enabled
            ? 'Off'
            : 'Messages disappear after ${retentionLabel(retention.maxLifetime)}',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final changed = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            builder: (_) => RetentionScreen(
              features: features,
              roomId: ctx.roomId,
              roomName: ctx.room?.name ?? 'this room',
              palette: ctx.palette,
            ),
          ),
        );
        if (changed == true && context.mounted) {
          // Re-project so the new policy applies to the open timeline.
          final backend = ctx.backend;
          if (backend is MatrixBackend) backend.refreshOpenRoom();
        }
      },
    ),
  ];
}

class RetentionBanner extends StatefulWidget {
  const RetentionBanner({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    required this.roomName,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final String roomName;

  @override
  State<RetentionBanner> createState() => _RetentionBannerState();
}

class _RetentionBannerState extends State<RetentionBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(RetentionBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId ||
        !identical(oldWidget.backend, widget.backend)) {
      _arm();
    }
  }

  void _arm() {
    _ticker?.cancel();
    _ticker = null;
    final retention = retentionFeaturesOf(
      widget.backend,
    )?.cachedRetention(widget.roomId);
    if (retention == null || !retention.enabled) return;
    // Re-project periodically so expired messages leave the open timeline.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      final backend = widget.backend;
      if (mounted && backend is MatrixBackend) backend.refreshOpenRoom();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final features = retentionFeaturesOf(widget.backend);
    final retention = features?.cachedRetention(widget.roomId);
    if (retention == null || !retention.enabled) return const SizedBox.shrink();
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        color: p.raised.withValues(alpha: 0.94),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.stroke),
        ),
        child: InkWell(
          key: const ValueKey('retention.banner'),
          onTap: () async {
            final changed = await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => RetentionScreen(
                  features: features!,
                  roomId: widget.roomId,
                  roomName: widget.roomName,
                  palette: p,
                ),
              ),
            );
            if (changed == true && mounted) {
              final backend = widget.backend;
              if (backend is MatrixBackend) backend.refreshOpenRoom();
              setState(_arm);
            }
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Icon(Icons.timer_outlined, size: 18, color: p.secondary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Disappearing messages: ${retentionLabel(retention.maxLifetime)}',
                    style: TextStyle(
                      color: p.foreground,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
