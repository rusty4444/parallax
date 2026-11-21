import 'package:flutter/material.dart';

import '../features/call/call_hooks.dart';
import '../features/catch_up/catch_up_hooks.dart';
import '../features/chat_export/chat_export_hooks.dart';
import '../features/chat_lock/chat_lock_hooks.dart';
import '../features/composer/composer_hooks.dart';
import '../features/home/home_hooks.dart';
import '../features/link_previews/link_preview_hooks.dart';
import '../features/live_location/live_location_hooks.dart';
import '../features/media/media_hooks.dart';
import '../features/media/video_note.dart';
import '../features/message_requests/message_requests_hooks.dart';
import '../features/notifications/notification_hooks.dart';
import '../features/packs/packs_hooks.dart';
import '../features/platform/platform_hooks.dart';
import '../features/polls/poll_hooks.dart';
import '../features/qr_login/qr_login_hooks.dart';
import '../features/reactions/reaction_hooks.dart';
import '../features/reminders/reminders_hooks.dart';
import '../features/retention/retention_hooks.dart';
import '../features/rich_timeline/rich_timeline_hooks.dart';
import '../features/rooms_admin/rooms_admin_hooks.dart';
import '../features/saved/saved_hooks.dart';
import '../features/scheduled/scheduled_hooks.dart';
import '../features/security/security_hooks.dart';
import '../features/spaces_admin/spaces_admin_hooks.dart';
import '../features/stories/stories_hooks.dart';
import '../features/threads/thread_hooks.dart';
import '../features/transcription/transcription_hooks.dart';
import '../features/translation/translation_hooks.dart';
import '../features/user_status/user_status_hooks.dart';
import 'hook_types.dart';

export 'hook_types.dart';

/// Aggregates feature hooks for the core screens. Feature modules implement
/// their own hook files; this file only fixes the order in which they appear.

Widget? entryBodyFor(BuildContext context, EntryHookContext ctx) =>
    pollEntryBody(context, ctx) ??
    locationEntryBody(context, ctx) ??
    liveLocationEntryBody(context, ctx) ??
    callEntryBody(context, ctx) ??
    mediaEntryBody(context, ctx);

List<Widget> entryFootersFor(BuildContext context, EntryHookContext ctx) => [
  ?threadEntryFooter(context, ctx),
  ?linkPreviewEntryFooter(context, ctx),
];

List<MessageActionItem> messageActionsFor(
  BuildContext context,
  EntryHookContext ctx,
) => [
  ...threadMessageActions(context, ctx),
  ...reactionMessageActions(context, ctx),
  ...pollMessageActions(context, ctx),
  ...mediaMessageActions(context, ctx),
  ...savedMessageActions(context, ctx),
  ...reminderMessageActions(context, ctx),
  ...translationMessageActions(context, ctx),
  ...transcriptionMessageActions(context, ctx),
  ...richTimelineMessageActions(context, ctx),
  // Moderator removal comes from the reactions module (live power levels);
  // roomsAdminMessageActions duplicates it once room details were cached.
  if (reactionMessageActions(context, ctx).isEmpty)
    ...roomsAdminMessageActions(context, ctx),
];

List<ComposerAttachmentAction> composerAttachmentsFor(
  BuildContext context,
  RoomHookContext ctx,
) => [
  ...pollComposerAttachments(context, ctx),
  ...liveLocationComposerAttachments(context, ctx),
  ...packsComposerAttachments(context, ctx),
  ...videoNoteComposerAttachments(context, ctx),
];

/// Long-press options on the composer's send button.
List<ComposerSendOption> composerSendOptionsFor(
  BuildContext context,
  RoomHookContext ctx,
) => [...scheduledSendOptions(context, ctx)];

/// Autocomplete sources other than `@` mentions (custom emoji `:`, …).
List<ComposerSuggestionSource> composerSuggestionSourcesFor(
  BuildContext context,
  RoomHookContext ctx,
) => [...packsSuggestionSources(context, ctx)];

/// Final transform of an outgoing text message's content, after markdown,
/// `/me` and mentions. Applied in order: effects/commands, then emoticons.
Map<String, Object?> transformOutgoingText(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) => packsTransformOutgoing(ctx, composerTransformOutgoing(ctx, content));

/// Full-screen overlays above the room timeline (chat effects).
List<Widget> roomOverlaysFor(BuildContext context, RoomHookContext ctx) => [
  ...composerRoomOverlays(context, ctx),
];

List<Widget> roomHeaderActionsFor(BuildContext context, RoomHookContext ctx) =>
    [
      ...callRoomHeaderActions(context, ctx),
      ...threadRoomHeaderActions(context, ctx),
    ];

List<Widget> roomBannersFor(BuildContext context, RoomHookContext ctx) => [
  ...securityRoomBanners(context, ctx),
  ...callRoomBanners(context, ctx),
  ...roomsAdminRoomBanners(context, ctx),
  ...liveLocationRoomBanners(context, ctx),
  ...scheduledRoomBanners(context, ctx),
  ...reactionRoomBanners(context, ctx),
  ...retentionRoomBanners(context, ctx),
  ...userStatusRoomBanners(context, ctx),
  ...catchUpRoomBanners(context, ctx),
];

List<Widget> roomDetailsSectionsFor(
  BuildContext context,
  RoomHookContext ctx,
) => [
  ...reactionRoomDetailsSections(context, ctx),
  ...threadRoomDetailsSections(context, ctx),
  ...mediaRoomDetailsSections(context, ctx),
  ...pollRoomDetailsSections(context, ctx),
  ...spacesAdminRoomDetailsSections(context, ctx),
  ...packsRoomDetailsSections(context, ctx),
  ...retentionRoomDetailsSections(context, ctx),
  ...chatLockRoomDetailsSections(context, ctx),
  ...chatExportRoomDetailsSections(context, ctx),
];

// Settings is a menu of category pages (lib/settings_screen.dart). Each
// function below supplies one page's feature rows or sections, so every
// feature setting lands in a category rather than on the top-level list.

/// Settings → Notifications: rows in the "This device" group.
List<Widget> notificationSettingsRowsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [...notificationSettingsRows(context, ctx)];

/// Settings → Account: rows in the "Devices" group.
List<Widget> accountDeviceSettingsRowsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...qrLoginSettingsRows(context, ctx),
  ...userStatusAccountRows(context, ctx),
];

/// Settings → Chats: sending, effects, emoji and saved messages.
List<Widget> chatSettingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...scheduledSettingsSections(context, ctx),
  ...composerSettingsSections(context, ctx),
  ...quickReactionSettingsSections(context, ctx),
  ...packsSettingsSections(context, ctx),
  ...savedSettingsSections(context, ctx),
  ...storiesChatsSections(context, ctx),
  ...remindersChatsSections(context, ctx),
];

/// Settings → Media: upload quality.
List<Widget> mediaSettingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...mediaSettingsSections(context, ctx),
  ...linkPreviewSettingsSections(context, ctx),
];

/// Settings → Privacy: the on-device message search index.
List<Widget> privacySettingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...messageSearchSettingsSections(context, ctx),
  ...messageRequestsPrivacySections(context, ctx),
];

/// Settings → Security: key storage, recovery, room keys and reset.
List<Widget> securitySettingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [...securitySettingsSections(context, ctx)];

/// Settings → Advanced: Element Call service and Matrix links.
List<Widget> advancedSettingsSectionsFor(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  ...callSettingsSections(context, ctx),
  ...platformSettingsSections(context, ctx),
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
      wrapWithNotifications(
        context,
        ctx,
        wrapWithLiveLocation(
          context,
          ctx,
          wrapWithPlatformIntents(
            context,
            ctx,
            wrapWithChatLock(
              context,
              ctx,
              wrapWithMessageRequests(
                context,
                ctx,
                wrapWithUserStatus(
                  context,
                  ctx,
                  wrapWithStories(
                    context,
                    ctx,
                    wrapWithReminders(context, ctx, child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// Outermost signed-in wrapper: the PIN/biometric app lock.
Widget wrapSignedInAppLock(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => wrapWithAppLock(context, ctx, child);
