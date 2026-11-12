// Hook implementations for the QR code sign-in feature module.
//
// MSC4108 sign in with QR code, and linking a new device.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import 'link_new_device_screen.dart';
import 'qr_login_features.dart';

/// Settings → Account → Devices: the "Link new device" row.
List<Widget> qrLoginSettingsRows(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final features = qrLoginFeaturesOf(ctx.backend);
  if (features == null || !features.canLinkNewDevice) return const [];
  final p = ctx.palette;
  return [
    ListTile(
      key: const ValueKey('qr-login.link-new-device'),
      leading: const Icon(Icons.qr_code_2_rounded),
      title: const Text('Link new device'),
      subtitle: const Text('Sign in on another phone with a QR code'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () async {
        final linked = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) =>
                LinkNewDeviceScreen(backend: ctx.backend, palette: p),
          ),
        );
        if (linked == true && context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('New device linked.')));
        }
      },
    ),
  ];
}
