// Hook implementations for the home and settings feature module.
//
// Room list filters, spaces, account settings and app lock.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Wraps the signed-in app with the PIN/biometric app lock.
Widget wrapWithAppLock(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => child;
