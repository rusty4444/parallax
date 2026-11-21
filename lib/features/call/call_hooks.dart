// Hook implementations for the Element Call feature module.
//
// Embedded Element Call widget, call buttons, banners and ringing.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'call_features.dart';
import 'call_screen.dart';
import 'call_settings_section.dart';
import 'call_ui.dart';
import 'incoming_call_overlay.dart';

List<Widget> callRoomHeaderActions(BuildContext context, RoomHookContext ctx) {
  final features = callFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  return [
    if (ctx.room?.isVoiceRoom ?? false)
      TextButton.icon(
        key: ValueKey('voice-room-drop-in-${ctx.roomId}'),
        onPressed: () => unawaited(
          openCallScreen(
            context,
            backend: ctx.backend,
            roomId: ctx.roomId,
            palette: ctx.palette,
            navigator: Navigator.of(context),
            audioOnly: true,
          ),
        ),
        icon: const Icon(Icons.graphic_eq_rounded, size: 18),
        label: const Text('Drop in'),
      ),
    CallHeaderButton(
      key: ValueKey('call-header-${ctx.roomId}'),
      features: features,
      backend: ctx.backend,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}

List<Widget> callRoomBanners(BuildContext context, RoomHookContext ctx) {
  final features = callFeaturesOf(ctx.backend);
  if (features == null || (ctx.room?.invited ?? false)) return const [];
  return [
    OngoingCallBanner(
      key: ValueKey('call-banner-${ctx.roomId}'),
      features: features,
      backend: ctx.backend,
      roomId: ctx.roomId,
      palette: ctx.palette,
      direct: ctx.room?.isDirect ?? false,
    ),
  ];
}

Widget? callEntryBody(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  if (entry.kind != EntryKind.call) return null;
  return CallTimelineBody(
    eventType: entry.eventType,
    content: entry.content,
    time: entry.time,
    mine: entry.mine,
    palette: ctx.palette,
    textColor: ctx.onBubble,
    backend: ctx.backend,
    roomId: ctx.roomId,
    features: callFeaturesOf(ctx.backend),
  );
}

/// Wraps the signed-in app (incoming-call overlay, ongoing-call pill …).
Widget wrapWithCallOverlay(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) {
  if (callFeaturesOf(ctx.backend) == null) return child;
  return IncomingCallOverlay(
    backend: ctx.backend,
    palette: ctx.palette,
    navigatorKey: ctx.navigatorKey,
    child: child,
  );
}

List<Widget> callSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final features = callFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    CallSettingsSection(
      key: const ValueKey('call-settings'),
      features: features,
      palette: ctx.palette,
    ),
  ];
}
