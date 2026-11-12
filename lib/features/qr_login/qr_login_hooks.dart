// Hook implementations for the QR code sign-in feature module.
//
// MSC4108 sign in with QR code, and linking a new device.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import '../../widgets.dart';
import '../security/security_ui.dart' show SecurityCard;
import 'link_new_device_screen.dart';
import 'qr_login_features.dart';

/// Settings sections (for example "Link new device").
List<Widget> qrLoginSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final features = qrLoginFeaturesOf(ctx.backend);
  if (features == null || !features.canLinkNewDevice) return const [];
  final p = ctx.palette;
  return [
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 28),
        Eyebrow('Devices', palette: p),
        const SizedBox(height: 10),
        SecurityCard(
          palette: p,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.qr_code_2_rounded, color: p.accent),
            title: Text(
              'Link new device',
              style: TextStyle(
                color: p.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              'Sign in on another phone with a QR code',
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
            onTap: () async {
              final linked = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) =>
                      LinkNewDeviceScreen(backend: ctx.backend, palette: p),
                ),
              );
              if (linked == true && context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('New device linked.')),
                );
              }
            },
          ),
        ),
      ],
    ),
  ];
}
