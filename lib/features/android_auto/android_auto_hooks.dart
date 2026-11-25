// Hook implementations for the Android Auto feature module.
//
// Parallax on the car screen: recent chats read aloud, voice replies and
// mark as read. Car notifications themselves are part of the notifications
// module (MessagingStyle with Reply and Mark as read).
import 'package:flutter/widgets.dart';

import '../../hooks/hook_types.dart';
import 'android_auto_host.dart';

/// Wraps the signed-in app: answers the car screen with the live client.
Widget wrapWithAndroidAuto(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => AndroidAutoHost(app: ctx, child: child);
