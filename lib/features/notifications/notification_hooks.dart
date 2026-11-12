// Hook implementations for the rich notifications feature module.
//
// Sender, message and media previews in notifications.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Wraps the signed-in app (for example to receive pushes handed over from
/// background isolates while the main isolate is alive).
Widget wrapWithNotifications(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;

List<Widget> notificationSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
