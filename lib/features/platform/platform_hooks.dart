// Hook implementations for the platform integration feature module.
//
// Share intents, deep links and UnifiedPush.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Wraps the signed-in app to route share intents and matrix.to links.
Widget wrapWithPlatformIntents(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;

List<Widget> platformSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
