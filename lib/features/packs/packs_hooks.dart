// Hook implementations for the custom emoji and sticker packs feature module.
//
// MSC2545 image packs: emoticons, stickers and pack management.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';
import '../home/settings_widgets.dart';
import 'emoticon_transform.dart';
import 'pack_features.dart';
import 'pack_management.dart';
import 'pack_model.dart';
import 'packs_picker.dart';

/// `:` autocomplete for custom emoji in the room's packs.
List<ComposerSuggestionSource> packsSuggestionSources(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = packsFeaturesOf(ctx.backend);
  if (features == null) return const [];
  features.ensurePacksLoaded(ctx.roomId);
  return [
    customEmojiSuggestionSource(
      features: features,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}

/// Converts known `:shortcode:`s into emoticon images in `formatted_body`.
Map<String, Object?> packsTransformOutgoing(
  OutgoingTextContext ctx,
  Map<String, Object?> content,
) {
  final features = packsFeaturesOf(ctx.backend);
  if (features == null) return content;
  try {
    return transformOutgoingEmoticons(
      content,
      features.availablePacks(ctx.roomId),
    );
  } catch (_) {
    // Never block a send over custom emoji; the body keeps the shortcodes.
    return content;
  }
}

/// "Sticker" in the composer's attachment sheet.
List<ComposerAttachmentAction> packsComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = packsFeaturesOf(ctx.backend);
  if (features == null) return const [];
  features.ensurePacksLoaded(ctx.roomId);
  return [
    ComposerAttachmentAction(
      id: 'packs-sticker',
      icon: Icons.sticky_note_2_outlined,
      label: 'Sticker',
      onSelected: (context) => pickAndSendSticker(context, ctx, features),
    ),
  ];
}

/// Room details › "Emoji & stickers".
List<Widget> packsRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final features = packsFeaturesOf(ctx.backend);
  if (features == null) return const [];
  return [
    ListenableBuilder(
      key: const ValueKey('packs-room-details'),
      listenable: features.packUpdates,
      builder: (context, _) {
        final count = features.roomPacks(ctx.roomId).length;
        return ListTile(
          key: const ValueKey('packs-room-details-tile'),
          leading: const Icon(Icons.emoji_emotions_outlined),
          title: const Text('Emoji & stickers'),
          subtitle: Text(
            count == 0
                ? 'Custom emoji and sticker packs'
                : count == 1
                ? '1 pack'
                : '$count packs',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RoomPacksScreen(
                features: features,
                roomId: ctx.roomId,
                palette: ctx.palette,
              ),
            ),
          ),
        );
      },
    ),
  ];
}

/// Settings → Chats → "Emoji & stickers": personal pack and packs in all
/// rooms.
List<Widget> packsSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final features = packsFeaturesOf(ctx.backend);
  if (features == null) return const [];
  final p = ctx.palette;
  return [
    ListenableBuilder(
      key: const ValueKey('packs-settings'),
      listenable: features.packUpdates,
      builder: (context, _) {
        final personal = features.personalPack().images.length;
        final global = features.globalPacks().length;
        return SettingsGroup(
          palette: p,
          title: 'Emoji & stickers',
          children: [
            ListTile(
              key: const ValueKey('packs-settings-tile'),
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('Custom emoji & stickers'),
              subtitle: Text(
                [
                  personal == 1
                      ? '1 image in your pack'
                      : '$personal images in your pack',
                  if (global > 0)
                    global == 1
                        ? '1 room pack everywhere'
                        : '$global room packs everywhere',
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PackSettingsScreen(features: features, palette: p),
                ),
              ),
            ),
          ],
        );
      },
    ),
  ];
}

/// Whether [ctx]'s room has any sticker available (for callers that want to
/// hide sticker affordances).
bool packsHaveStickers(RoomHookContext ctx) =>
    packsFeaturesOf(
      ctx.backend,
    )?.availablePacks(ctx.roomId).supports(PackUsage.sticker) ??
    false;
