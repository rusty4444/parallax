import 'package:flutter/material.dart';

import '../features/call/call_hooks.dart';
import '../features/home/home_hooks.dart';
import '../features/media/media_hooks.dart';
import '../features/platform/platform_hooks.dart';
import '../features/polls/poll_hooks.dart';
import '../features/reactions/reaction_hooks.dart';
import '../features/rich_timeline/rich_timeline_hooks.dart';
import '../features/rooms_admin/rooms_admin_hooks.dart';
import '../features/security/security_hooks.dart';
import '../features/threads/thread_hooks.dart';
import 'hook_types.dart';

export 'hook_types.dart';

/// Aggregates feature hooks for the core screens. Feature modules implement
/// their own hook files; this file only fixes the order in which they appear.

Widget? entryBodyFor(BuildContext context, EntryHookContext ctx) =>
    pollEntryBody(context, ctx) ??
    locationEntryBody(context, ctx) ??
    callEntryBody(context, ctx) ??
    mediaEntryBody(context, ctx);

List<Widget> entryFootersFor(BuildContext context, EntryHookContext ctx) => [
  ?threadEntryFooter(context, ctx),
];

List<MessageActionItem> messageActionsFor(
  BuildContext context,
  EntryHookContext ctx,
) => [
  ...threadMessageActions(context, ctx),
  ...reactionMessageActions(context, ctx),
  ...pollMessageActions(context, ctx),
  ...mediaMessageActions(context, ctx),
  ...richTimelineMessageActions(context, ctx),
  // Moderator removal comes from the reactions module (live power levels);
  // roomsAdminMessageActions duplicates it once room details were cached.
  if (reactionMessageActions(context, ctx).isEmpty)
    ...roomsAdminMessageActions(context, ctx),
];

List<ComposerAttachmentAction> composerAttachmentsFor(
  BuildContext context,
  RoomHookContext ctx,
) => [...pollComposerAttachments(context, ctx)];

List<Widget> roomHeaderActionsFor(BuildContext context, RoomHookContext ctx) =>
    [
      ...callRoomHeaderActions(context, ctx),
      ...threadRoomHeaderActions(context, ctx),
    ];

List<Widget> roomBannersFor(BuildContext context, RoomHookContext ctx) => [
  ...securityRoomBanners(context, ctx),
  ...callRoomBanners(context, ctx),
  ...roomsAdminRoomBanners(context, ctx),
  ...reactionRoomBanners(context, ctx),
];

List<Widget> roomDetailsSectionsFor(
  BuildContext context,
  RoomHookContext ctx,
) => [
  ...reactionRoomDetailsSections(context, ctx),
  ...threadRoomDetailsSections(context, ctx),
  ...mediaRoomDetailsSections(context, ctx),
  ...pollRoomDetailsSections(context, ctx),
];

List<Widget> settingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...securitySettingsSections(context, ctx),
  ...callSettingsSections(context, ctx),
  ...mediaSettingsSections(context, ctx),
  ...platformSettingsSections(context, ctx),
  ...messageSearchSettingsSections(context, ctx),
];

/// Wraps the signed-in app (inside the verification overlay). The app lock
/// is applied separately by [wrapSignedInAppLock], outside the overlay, so
/// incoming verification prompts cannot appear above the lock screen.
Widget wrapSignedInApp(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => wrapWithSecurityGate(
  context,
  ctx,
  wrapWithCallOverlay(
    context,
    ctx,
    wrapWithMessageSearchIndex(
      context,
      ctx,
      wrapWithPlatformIntents(context, ctx, child),
    ),
  ),
);

/// Outermost signed-in wrapper: the PIN/biometric app lock.
Widget wrapSignedInAppLock(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => wrapWithAppLock(context, ctx, child);
