import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../rich_timeline/message_actions.dart';
import 'link_preview_cache.dart';
import 'link_previews.dart';
import 'link_video_player.dart';

/// Widest a preview card gets inside a bubble.
const maxLinkPreviewWidth = 264.0;

/// The page title and image for one link, under the message that contains
/// it. Shows nothing until the preview arrives, and nothing at all when the
/// page has no preview or the fetch failed.
class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({
    super.key,
    required this.uri,
    required this.source,
    required this.backend,
    required this.palette,
    required this.mine,
    this.cache,
    this.timestamp,
    this.videoControllerFactory = createNetworkLinkVideoController,
  });

  final Uri uri;
  final LinkPreviewSource source;
  final ChatBackend backend;
  final AppPalette palette;
  final bool mine;
  final LinkPreviewCache? cache;

  /// Message time, so the server can return the preview as it was then.
  final int? timestamp;
  final LinkVideoControllerFactory videoControllerFactory;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  late LinkPreviewCache _cache;
  late Future<LinkPreview?> _preview;

  @override
  void initState() {
    super.initState();
    _cache = widget.cache ?? LinkPreviewCache.forSource(widget.source);
    _preview = _load();
  }

  Future<LinkPreview?> _load() =>
      _cache.preview(widget.uri, timestamp: widget.timestamp);

  @override
  void didUpdateWidget(LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.source != widget.source) {
      _cache = widget.cache ?? LinkPreviewCache.forSource(widget.source);
      _preview = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<LinkPreview?>(
    future: _preview,
    builder: (context, snapshot) {
      final preview = snapshot.data;
      if (preview == null) return const SizedBox.shrink();
      final palette = widget.palette;
      final mine = widget.mine;
      final text = mine ? palette.bubbleText : palette.foreground;
      final muted = text.withValues(alpha: 0.72);
      // The bubble hugs its content, so the card needs a real width: as
      // wide as a bubble may be, capped like Element's previews.
      final available =
          MediaQuery.sizeOf(context).width * 0.83 -
          (mine ? 40 : 0) -
          28; // avatar column and bubble padding
      final width = math.max(140.0, math.min(maxLinkPreviewWidth, available));
      return Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Semantics(
          button: true,
          label: 'Link preview: ${preview.title ?? preview.host}',
          child: Material(
            color: mine
                ? palette.bubbleText.withValues(alpha: 0.10)
                : palette.background,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(
                  color: mine
                      ? palette.bubbleText.withValues(alpha: 0.25)
                      : palette.stroke,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (preview.video != null)
                      LinkVideoPlayer(
                        video: preview.video!,
                        backend: widget.backend,
                        poster: preview.image,
                        controllerFactory: widget.videoControllerFactory,
                        onFullScreen: () => showLinkVideoFullScreen(
                          context,
                          preview.video!,
                          widget.backend,
                          poster: preview.image,
                          controllerFactory: widget.videoControllerFactory,
                        ),
                      ),
                    InkWell(
                      onTap: () => openTimelineLink(context, widget.uri),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (preview.image != null)
                            _PreviewImage(
                              backend: widget.backend,
                              uri: preview.image!,
                              size: 64,
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 7,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    preview.host,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (preview.title != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      preview.title!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: text,
                                        fontSize: 13,
                                        height: 1.25,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                  if (preview.description != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      preview.description!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: muted,
                                        fontSize: 12,
                                        height: 1.25,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The page's image, as a small homeserver thumbnail through the backend's
/// usual (disk-cached, size-bounded) avatar loader.
class _PreviewImage extends StatefulWidget {
  const _PreviewImage({
    required this.backend,
    required this.uri,
    required this.size,
  });

  final ChatBackend backend;
  final Uri uri;
  final double size;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  late final Future<Uint8List?> _bytes = widget.backend.loadAvatar(widget.uri);

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    initialData: widget.backend.cachedAvatar(widget.uri),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
      return Image.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheWidth: (widget.size * 3).round(),
        gaplessPlayback: true,
      );
    },
  );
}
