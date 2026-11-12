// Hook implementations for the QR code sign-in feature module.
//
// MSC4108 sign in with QR code, and linking a new device.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Settings sections (for example "Link new device").
List<Widget> qrLoginSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
