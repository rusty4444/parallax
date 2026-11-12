// Hook implementations for the live location sharing feature module.
//
// MSC3488/MSC3489 beacons: share, view and stop live location.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'live_location_banner.dart';
import 'live_location_features.dart';
import 'live_location_model.dart';
import 'live_location_scope.dart';
import 'live_location_view.dart';
import 'start_live_location.dart';

export 'live_location_scope.dart' show liveLocationBeforeLogout;

Widget? liveLocationEntryBody(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  if (entry.kind != EntryKind.liveLocation || entry.redacted) return null;
  final features = liveLocationFeaturesOf(ctx.backend);
  if (features == null) return null;
  final info = BeaconInfo.fromEvent(
    eventId: entry.id,
    type: entry.eventType,
    stateKey: entry.stateKey,
    sender: entry.sender,
    content: entry.content,
    originServerTs: entry.time,
  );
  if (info == null) return null;
  if (!info.live) {
    // The event that ended a share (`live: false`).
    return LiveLocationEndedLine(
      palette: ctx.palette,
      foreground: ctx.onBubble,
    );
  }
  return LiveLocationBody(
    key: ValueKey('live-location-${entry.id}'),
    features: features,
    backend: ctx.backend,
    palette: ctx.palette,
    roomId: ctx.roomId,
    info: info,
    foreground: ctx.onBubble,
  );
}

List<ComposerAttachmentAction> liveLocationComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = liveLocationFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  return [
    ComposerAttachmentAction(
      id: 'live-location',
      icon: Icons.share_location_rounded,
      label: 'Share live location',
      onSelected: (context) async {
        await startLiveLocationFlow(
          context,
          features: features,
          roomId: ctx.roomId,
          palette: ctx.palette,
        );
      },
    ),
  ];
}

List<Widget> liveLocationRoomBanners(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = liveLocationFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  return [
    LiveLocationBanner(
      key: ValueKey('live-location-banner-${ctx.roomId}'),
      features: features,
      backend: ctx.backend,
      palette: ctx.palette,
      roomId: ctx.roomId,
    ),
  ];
}

/// Wraps the signed-in app (keeps active shares running, resumes after
/// restart, stops them on sign-out).
Widget wrapWithLiveLocation(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) {
  final lifecycle = liveLocationLifecycleOf(ctx.backend);
  if (lifecycle == null) return child;
  return LiveLocationScope(
    backend: ctx.backend,
    lifecycle: lifecycle,
    child: child,
  );
}
