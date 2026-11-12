// Hook implementations for the live location sharing feature module.
//
// MSC3488/MSC3489 beacons: share, view and stop live location.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

Widget? liveLocationEntryBody(BuildContext context, EntryHookContext ctx) =>
    null;

List<ComposerAttachmentAction> liveLocationComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<Widget> liveLocationRoomBanners(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

/// Wraps the signed-in app (keeps active shares running, resumes after
/// restart, stops them on sign-out).
Widget wrapWithLiveLocation(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;
