import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../media/media_content.dart';
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

  LinkPreviewImageSource? get _imageSource => switch (widget.source) {
    final LinkPreviewImageSource s => s,
    _ => switch (widget.backend) {
      final LinkPreviewImageSource s => s,
      _ => null,
    },
  };

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
      final bubble = mine ? palette.bubble : palette.surface;
      final rawText = mine ? palette.bubbleText : palette.foreground;
      // Derive card fill and border from the surrounding bubble and its
      // readable text colour rather than global theme background, so custom
      // light/dark BubbleColours never produce dark-on-dark or light-on-light.
      final cardColor = Color.alphaBlend(
        rawText.withValues(alpha: mine ? 0.10 : 0.08),
        bubble,
      );
      final text =
          (cardColor.computeLuminance() - rawText.computeLuminance()).abs() <
              0.25
          ? (cardColor.computeLuminance() > 0.42
                ? const Color(0xFF141414)
                : const Color(0xFFFFFFFF))
          : rawText;
      final muted = text.withValues(alpha: 0.72);
      final borderColor = Color.alphaBlend(
        text.withValues(alpha: 0.22),
        bubble,
      );
      final imageSource = _imageSource;
      final videoAspect =
          preview.video?.aspectRatio ?? preview.imageAspectRatio;
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
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: Border.all(color: borderColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (preview.video != null)
                      LinkVideoPlayer(
                        video: preview.video!,
                        backend: widget.backend,
                        poster: preview.image,
                        posterLoader: imageSource?.loadPreviewImage,
                        initialAspectRatio: videoAspect,
                        controllerFactory: widget.videoControllerFactory,
                        onFullScreen: () => showLinkVideoFullScreen(
                          context,
                          preview.video!,
                          widget.backend,
                          poster: preview.image,
                          posterLoader: imageSource?.loadPreviewImage,
                          initialAspectRatio: videoAspect,
                          controllerFactory: widget.videoControllerFactory,
                        ),
                      ),
                    InkWell(
                      onTap: () => openTimelineLink(context, widget.uri),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (preview.video == null && preview.image != null)
                            _PreviewImage(
                              backend: widget.backend,
                              imageSource: imageSource,
                              uri: preview.image!,
                              width: width,
                              initialAspectRatio: preview.imageAspectRatio,
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
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

/// Prominent full-width image banner for a link or photo preview, sizing
/// itself from Open Graph or decoded dimensions while bounded for chat.
class _PreviewImage extends StatefulWidget {
  const _PreviewImage({
    required this.backend,
    required this.imageSource,
    required this.uri,
    required this.width,
    this.initialAspectRatio,
  });

  final ChatBackend backend;
  final LinkPreviewImageSource? imageSource;
  final Uri uri;
  final double width;
  final double? initialAspectRatio;

  @override
  State<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<_PreviewImage> {
  late Future<Uint8List?> _bytes;
  Uint8List? _cached;
  Uint8List? _sizedBytes;
  double? _decodedAspect;
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _untrackSize();
    _sizedBytes = null;
    _decodedAspect = null;
    final source = widget.imageSource;
    if (source != null) {
      _cached = source.cachedPreviewImage(widget.uri);
      _bytes = _cached != null
          ? Future<Uint8List?>.value(_cached)
          : source.loadPreviewImage(widget.uri);
    } else {
      _cached = widget.backend.cachedAvatar(widget.uri);
      _bytes = _cached != null
          ? Future<Uint8List?>.value(_cached)
          : widget.backend.loadAvatar(widget.uri);
    }
  }

  void _untrackSize() {
    final stream = _sizeStream;
    final listener = _sizeListener;
    _sizeStream = null;
    _sizeListener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  @override
  void didUpdateWidget(_PreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.backend != widget.backend ||
        oldWidget.imageSource != widget.imageSource) {
      _load();
    }
  }

  @override
  void dispose() {
    _untrackSize();
    super.dispose();
  }

  void _trackSize(ImageProvider provider, Uint8List data) {
    if (identical(_sizedBytes, data)) return;
    _untrackSize();
    _sizedBytes = data;
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      _untrackSize();
      if (mounted && w > 0 && h > 0) {
        final ratio = w / h;
        if (_decodedAspect == null || (_decodedAspect! - ratio).abs() > 0.02) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _decodedAspect = ratio);
          });
        }
      }
    }, onError: (_, _) => _untrackSize());
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    initialData: _cached,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
      final provider = boundedMemoryImage(bytes, maxEdge: 1024);
      _trackSize(provider, bytes);
      final aspect = (_decodedAspect ?? widget.initialAspectRatio ?? (16 / 9))
          .clamp(0.6, 2.2);
      final height = (widget.width / aspect).clamp(110.0, 320.0);
      return SizedBox(
        key: const ValueKey('link-preview-photo'),
        width: widget.width,
        height: height,
        child: Image(
          image: provider,
          width: widget.width,
          height: height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    },
  );
}
