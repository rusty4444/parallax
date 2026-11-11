// Hook implementations for the security feature module.
//
// Session verification, identity warnings, key backup and recovery.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'identity_change_banner.dart';
import 'security_features.dart';
import 'security_gate.dart';
import 'security_settings.dart';

export 'security_features.dart'
    show
        SecurityFeatures,
        UserTrust,
        UserTrustLevel,
        securityFeaturesOf,
        trustOf;

/// Banners under the room header (for example identity-change warnings).
List<Widget> securityRoomBanners(BuildContext context, RoomHookContext ctx) {
  final security = securityFeaturesOf(ctx.backend);
  if (security == null) return const [];
  return [
    IdentityChangeBanner(
      key: ValueKey('security.identityBanner.${ctx.roomId}'),
      backend: ctx.backend,
      security: security,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}

/// Wraps the signed-in app (for example a post-login verification gate).
Widget wrapWithSecurityGate(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) {
  final security = securityFeaturesOf(ctx.backend);
  if (security == null) return child;
  return SecurityGate(
    backend: ctx.backend,
    security: security,
    palette: ctx.palette,
    child: child,
  );
}

List<Widget> securitySettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final security = securityFeaturesOf(ctx.backend);
  if (security == null) return const [];
  return [
    SecuritySettingsSection(
      backend: ctx.backend,
      security: security,
      palette: ctx.palette,
    ),
  ];
}
