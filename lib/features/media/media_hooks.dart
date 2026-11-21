// Hook implementations for the media feature module.
//
// Video, voice/audio, stickers, animated images, gallery and upload quality.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../attachment_picker.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'media_actions.dart';
import 'media_bubbles.dart';
import 'media_features.dart';
import 'media_gallery_screen.dart';
import 'media_settings_section.dart';
import 'thumbnail_sync.dart';
import 'thumbnail_sync_section.dart';
import 'video_note.dart';

/// Body for media kinds (image captions, video, audio, voice, sticker, file).
/// Return null to use the core rendering.
Widget? mediaEntryBody(BuildContext context, EntryHookContext ctx) {
  if (ctx.entry.redacted) return null;
  return switch (ctx.entry.kind) {
    EntryKind.image => ImageMessageBody(ctx: ctx),
    EntryKind.video =>
      isVideoNote(ctx.entry.content)
          ? SizedBox(
              width: 220,
              height: 220,
              child: ClipOval(child: VideoMessageBody(ctx: ctx)),
            )
          : VideoMessageBody(ctx: ctx),
    EntryKind.audio => AudioMessageBody(ctx: ctx),
    EntryKind.voice => VoiceMessageBody(ctx: ctx),
    EntryKind.sticker => StickerMessageBody(ctx: ctx),
    EntryKind.file => FileMessageBody(ctx: ctx),
    _ => null,
  };
}

/// NEW EXTENSION POINT (coordinator: wire in `MessageBubble.build` before the
/// bubble decoration, e.g. `final standalone = mediaEntryStandalone(context,
/// hook, onLongPress: onAction); if (standalone != null) return standalone;`).
/// Returns a sticker without bubble chrome, as in Element X; null otherwise.
Widget? mediaEntryStandalone(
  BuildContext context,
  EntryHookContext ctx, {
  VoidCallback? onLongPress,
}) => ctx.entry.kind == EntryKind.sticker && !ctx.entry.redacted
    ? StandaloneSticker(ctx: ctx, onLongPress: onLongPress)
    : null;

bool _isMedia(EntryKind kind) => switch (kind) {
  EntryKind.image ||
  EntryKind.video ||
  EntryKind.audio ||
  EntryKind.voice ||
  EntryKind.file ||
  EntryKind.sticker => true,
  _ => false,
};

List<MessageActionItem> mediaMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  if (entry.redacted || !_isMedia(entry.kind)) return const [];
  final kind = entry.kind;
  return [
    MessageActionItem(
      id: 'media.share',
      icon: Icons.share_outlined,
      label: 'Share',
      onSelected: (context) => shareMedia(
        context,
        backend: ctx.backend,
        loader: mediaLoaderFor(ctx.backend, ctx.roomId, entry.id),
      ),
    ),
    // The core sheet already offers "Save attachment" for files/audio/video.
    if (kind == EntryKind.image || kind == EntryKind.sticker)
      MessageActionItem(
        id: 'media.save',
        icon: Icons.download_rounded,
        label: 'Save image',
        onSelected: (context) async {
          await saveAttachment(
            context,
            ctx.backend,
            ctx.roomId,
            entry.id,
            loader: mediaLoaderFor(ctx.backend, ctx.roomId, entry.id),
          );
        },
      ),
    MessageActionItem(
      id: 'media.info',
      icon: Icons.info_outline_rounded,
      label: 'File info',
      onSelected: (context) => showMediaInfo(context, entry),
    ),
  ];
}

List<Widget> mediaRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = mediaFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    ListTile(
      key: const ValueKey('media.gallery'),
      leading: Icon(Icons.photo_library_outlined, color: ctx.palette.secondary),
      title: const Text('Media and files'),
      subtitle: const Text('Images, videos, files and voice messages'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => MediaGalleryScreen(
              backend: ctx.backend,
              features: features,
              roomId: ctx.roomId,
              palette: ctx.palette,
            ),
          ),
        ),
      ),
    ),
  ];
}

/// Settings → Media: upload quality, then offline thumbnails when the
/// backend keeps a thumbnail store.
List<Widget> mediaSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => [
  MediaSettingsSection(palette: ctx.palette),
  if (thumbnailSyncOf(ctx.backend) case final sync?)
    ThumbnailSyncSection(
      key: const ValueKey('thumbnail-sync'),
      sync: sync,
      palette: ctx.palette,
    ),
];
