// Hook implementations for the rich notifications feature module.
//
// Sender, message and media previews in notifications.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'notification_settings_section.dart';
import 'notification_troubleshoot_screen.dart';
import 'notifications_host.dart';

/// Wraps the signed-in app: receives pushes handed over from background
/// isolates while the main isolate is alive, renders rich notifications with
/// the live client, sends quick replies and clears notifications of rooms
/// that are opened or read.
Widget wrapWithNotifications(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => NotificationsHost(app: ctx, child: child);

/// Rows for the Settings Notifications group: message content and media
/// previews in notifications.
List<Widget> notificationSettingsRows(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  NotificationContentSection(palette: ctx.palette, backend: ctx.backend),
  ListTile(
    key: const ValueKey('notif-troubleshoot-row'),
    leading: const Icon(Icons.build_circle_outlined),
    title: const Text('Troubleshoot notifications'),
    subtitle: const Text('Check permissions, background sync and pushers'),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => NotificationTroubleshootScreen(
          backend: ctx.backend,
          palette: ctx.palette,
        ),
      ),
    ),
  ),
];
