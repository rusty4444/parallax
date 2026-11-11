// Hook implementations for the Element Call feature module.
//
// Embedded Element Call widget, call buttons, banners and ringing.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

List<Widget> callRoomHeaderActions(BuildContext context, RoomHookContext ctx) =>
    const [];

List<Widget> callRoomBanners(BuildContext context, RoomHookContext ctx) =>
    const [];

Widget? callEntryBody(BuildContext context, EntryHookContext ctx) => null;

/// Wraps the signed-in app (incoming-call overlay, ongoing-call pill …).
Widget wrapWithCallOverlay(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;

List<Widget> callSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
