// Hook implementations for the security feature module.
//
// Session verification, identity warnings, key backup and recovery.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Banners under the room header (for example identity-change warnings).
List<Widget> securityRoomBanners(BuildContext context, RoomHookContext ctx) =>
    const [];

/// Wraps the signed-in app (for example a post-login verification gate).
Widget wrapWithSecurityGate(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;

List<Widget> securitySettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
