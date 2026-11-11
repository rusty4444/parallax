// Hook implementations for the home and settings feature module.
//
// Room list filters, spaces, account settings and app lock.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import 'app_lock/app_lock_controller.dart';
import 'app_lock/app_lock_gate.dart';

/// Test seam: replaces the controller the signed-in gate creates.
@visibleForTesting
AppLockController Function()? appLockControllerFactory;

/// Wraps the signed-in app with the PIN/biometric app lock.
Widget wrapWithAppLock(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => AppLockGate(
  // A different account gets a fresh lock state.
  key: ValueKey('app-lock:${BackendSessionOwner.keyFor(ctx.backend) ?? ''}'),
  backend: ctx.backend,
  palette: ctx.palette,
  createController: appLockControllerFactory,
  child: child,
);
