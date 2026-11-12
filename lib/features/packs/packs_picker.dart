import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../widgets.dart';
import '../reactions/emoji_picker_sheet.dart';
import 'pack_features.dart';
import 'pack_image.dart';
import 'pack_model.dart';

/// Emoji picker tabs for the custom emoji packs usable in [roomId] (default:
/// the backend's open room). Composer picks insert `:shortcode:`; reaction
/// picks return the image's `mxc://` key (MSC4027).
List<CustomEmojiTab> customEmojiTabsFor({
  ChatBackend? backend,
  String? roomId,
  required bool forReaction,
}) {
  final owner = backend ?? currentPacksBackend;
  final features = owner == null ? null : packsFeaturesOf(owner);
  if (owner == null || features == null) return const [];
  final room = roomId ?? owner.activeRoomId;
  features.ensurePacksLoaded(room);
  final packs = features.availablePacks(room);
  return [
    for (final group in packs.grouped(PackUsage.emoticon))
      CustomEmojiTab(
        id: group.pack.slug,
        label: group.pack.name,
        icon: PackImageView(
          features: features,
          url: group.pack.pack.avatarUrl ?? group.images.first.url,
          size: 24,
        ),
        items: [
          for (final image in group.images)
            CustomEmojiItem(
              value: forReaction
                  ? image.url.toString()
                  : packs.insertCode(group.pack, image),
              label: ':${image.shortcode}:',
              image: PackImageView(
                features: features,
                url: image.url,
                size: 34,
                semanticLabel: ':${image.shortcode}:',
                fallback: Text(
                  ':${image.shortcode}:',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ),
        ],
      ),
  ];
}

/// `:` autocomplete over the room's custom emoji.
ComposerSuggestionSource customEmojiSuggestionSource({
  required PacksFeatures features,
  required String roomId,
  required AppPalette palette,
}) => ComposerSuggestionSource(
  id: 'packs-emoji',
  trigger: ':',
  minQueryLength: 1,
  search: (query) {
    final packs = features.availablePacks(roomId);
    return [
      for (final entry in packs.search(query, limit: 12))
        ComposerSuggestion(
          id: 'packs-${entry.pack.slug}-${entry.image.shortcode}',
          label: ':${entry.image.shortcode}:',
          subtitle: entry.pack.name,
          insertText: '${packs.insertCode(entry.pack, entry.image)} ',
          leading: SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: PackImageView(
                features: features,
                url: entry.image.url,
                size: 28,
                semanticLabel: ':${entry.image.shortcode}:',
              ),
            ),
          ),
        ),
    ];
  },
);

/// Sticker picker grouped by pack. Resolves to the chosen sticker or null.
Future<PackImage?> showStickerPicker(
  BuildContext context, {
  required PacksFeatures features,
  required String roomId,
  required AppPalette palette,
}) {
  features.ensurePacksLoaded(roomId);
  return showModalBottomSheet<PackImage>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.surface,
    builder: (_) => StickerPickerSheet(
      features: features,
      roomId: roomId,
      palette: palette,
    ),
  );
}

class StickerPickerSheet extends StatefulWidget {
  const StickerPickerSheet({
    super.key,
    required this.features,
    required this.roomId,
    required this.palette,
  });
  final PacksFeatures features;
  final String roomId;
  final AppPalette palette;

  @override
  State<StickerPickerSheet> createState() => _StickerPickerSheetState();
}

class _StickerPickerSheetState extends State<StickerPickerSheet> {
  bool _chosen = false;

  @override
  void initState() {
    super.initState();
    widget.features.packUpdates.addListener(_changed);
  }

  @override
  void didUpdateWidget(StickerPickerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.features, widget.features)) {
      oldWidget.features.packUpdates.removeListener(_changed);
      widget.features.packUpdates.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.features.packUpdates.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _choose(PackImage image) {
    if (_chosen || !mounted) return;
    _chosen = true;
    Navigator.of(context).pop(image);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final media = MediaQuery.of(context);
    final height = (media.size.height * 0.55).clamp(280.0, 480.0);
    final groups = widget.features
        .availablePacks(widget.roomId)
        .grouped(PackUsage.sticker);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Eyebrow('Stickers', palette: p),
            ),
            Expanded(
              child: groups.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Center(
                        child: Text(
                          'No sticker packs yet. Add stickers to your own '
                          'pack in Settings, or to this room’s packs in '
                          'Room details › Emoji & stickers.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.muted, height: 1.4),
                        ),
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        for (final group in groups) ...[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                              child: Text(
                                group.pack.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            sliver: SliverGrid.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 96,
                                    mainAxisSpacing: 6,
                                    crossAxisSpacing: 6,
                                  ),
                              itemCount: group.images.length,
                              itemBuilder: (context, index) {
                                final image = group.images[index];
                                return Tooltip(
                                  message: image.description,
                                  child: Semantics(
                                    button: true,
                                    label: 'Sticker: ${image.description}',
                                    excludeSemantics: true,
                                    child: InkWell(
                                      key: ValueKey(
                                        'sticker-${group.pack.slug}-'
                                        '${image.shortcode}',
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () => _choose(image),
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: Center(
                                          child: PackImageView(
                                            features: widget.features,
                                            url: image.url,
                                            size: 72,
                                            semanticLabel: image.description,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the sticker picker for [ctx]'s room and sends the chosen sticker.
Future<void> pickAndSendSticker(
  BuildContext context,
  RoomHookContext ctx,
  PacksFeatures features,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final image = await showStickerPicker(
    context,
    features: features,
    roomId: ctx.roomId,
    palette: ctx.palette,
  );
  if (image == null) return;
  try {
    await features.sendSticker(ctx.roomId, image);
  } catch (_) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Couldn’t send this sticker.')),
      );
  }
}
