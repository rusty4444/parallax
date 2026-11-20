import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/media/media_content.dart';
import 'features/media/media_features.dart';
import 'media_viewer.dart';
import 'media_preview_policy.dart';

/// Animated GIF/WebP originals up to this size play in the timeline; larger
/// ones show their (static) thumbnail.
const maxTimelineAnimationBytes = 4 * 1024 * 1024;

/// Test override for reading an image's first-frame dimensions (real
/// decoding needs `runAsync` under fake async). Null uses [probeImageSize].
@visibleForTesting
Future<Size> Function(Uint8List bytes)? debugDecodeImageSize;

/// Intrinsic dimensions of encoded bytes, with a bounded probe decode.
/// [ui.instantiateImageCodecWithSize] reports the intrinsic size to
/// [getTargetSize] BEFORE decoding, so the ratio is exact and the decode
/// itself is fitted within 64×64 — a hostile, highly-compressible
/// 8000×8000 (or 100×16000) GIF cannot expand into a huge bitmap just to
/// be measured. One-axis targeting is NOT enough: the other axis stays
/// unbounded for extreme aspects.
Future<Size> probeImageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  Size? intrinsic;
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (w, h) {
      intrinsic = Size(w.toDouble(), h.toDouble());
      final scale = math.min(1.0, 64 / math.max(w, h));
      return ui.TargetImageSize(
        width: math.max(1, (w * scale).round()),
        height: math.max(1, (h * scale).round()),
      );
    },
  );
  try {
    final frame = await codec.getNextFrame();
    final size =
        intrinsic ??
        Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}

/// Loads one visible attachment through the SDK, including decryption.
class MessageImage extends StatefulWidget {
  const MessageImage({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    required this.eventId,
    this.width = 228,
    this.height = 170,
    this.entry,
    this.entries,
    this.autoAspect = true,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final String eventId;
  final double width;
  final double height;

  /// Event metadata: enables animated GIF/WebP playback and stickers.
  final ChatEntry? entry;

  /// Loaded timeline (oldest first) for swiping in the viewer.
  final List<ChatEntry>? entries;

  /// GIF/WebP previews size themselves to the media's own aspect instead of
  /// cropping into the fixed [width]×[height] box ([width] becomes the max
  /// width). Gallery mosaics pass false to keep their fixed grid cells.
  final bool autoAspect;

  @override
  State<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<MessageImage> {
  Future<Uint8List?>? _image;
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  bool _autoLoad = true;
  bool _animate = false;

  /// Intrinsic size decoded from the bytes when the event declares no
  /// dimensions (bridged GIFs often omit `info.w`/`info.h`).
  Size? _decoded;

  MediaInfo? get _info {
    final entry = widget.entry;
    return entry == null ? null : MediaInfo.fromEntry(entry);
  }

  /// GIF/WebP images fit their own shape; other media keeps the fixed box.
  bool get _autoFit =>
      widget.autoAspect &&
      widget.entry?.kind == EntryKind.image &&
      (_info?.mayBeAnimated ?? false);

  /// The preview box: the media's aspect for GIF/WebP (never cropped), the
  /// caller's fixed box for everything else.
  Size _displaySize() {
    if (!_autoFit) return Size(widget.width, widget.height);
    final decoded = _decoded;
    final ratio =
        _info?.aspectRatio ??
        (decoded != null && decoded.width > 0 && decoded.height > 0
            ? (decoded.width / decoded.height).clamp(0.2, 5.0)
            : null);
    return gifPreviewSize(
      ratio,
      maxWidth: widget.width,
      fallbackHeight: widget.height,
    );
  }

  /// Whether this image should load its (bounded) animated original.
  bool _wantsAnimation(BuildContext context) {
    final entry = widget.entry;
    if (entry == null || entry.kind != EntryKind.image) return false;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return false;
    final info = MediaInfo.fromEntry(entry);
    final size = info.size;
    return info.mayBeAnimated &&
        size != null &&
        size <= maxTimelineAnimationBytes &&
        mediaFeaturesOf(widget.backend) != null;
  }

  Future<Uint8List?> _load() async {
    final owner = _owner;
    final roomId = widget.roomId;
    final eventId = widget.eventId;
    final entry = widget.entry;
    final features = mediaFeaturesOf(widget.backend);
    Uint8List? bytes;
    try {
      if (_animate && features != null) {
        bytes = (await features.loadOriginal(
          roomId,
          eventId,
          maxBytes: maxTimelineAnimationBytes,
        )).bytes;
      } else if (widget.entry?.kind == EntryKind.sticker && features != null) {
        bytes = await features.loadPreview(roomId, eventId);
      } else {
        bytes = await widget.backend.loadImage(roomId, eventId);
      }
    } catch (_) {
      if (!_animate) rethrow;
      // Fall back to the static thumbnail if the original is unavailable.
      bytes = await widget.backend.loadImage(roomId, eventId);
    }
    if (!mounted ||
        !owner.isCurrent ||
        roomId != widget.roomId ||
        eventId != widget.eventId ||
        !identical(owner, _owner)) {
      return null;
    }
    // No declared dimensions: read them from the bytes so an odd-shaped
    // GIF is shown at its own aspect instead of cropped.
    if (bytes != null && _autoFit && _info?.aspectRatio == null) {
      try {
        final size = await (debugDecodeImageSize ?? probeImageSize)(bytes);
        if (mounted &&
            owner.isCurrent &&
            identical(owner, _owner) &&
            identical(entry, widget.entry) &&
            roomId == widget.roomId &&
            eventId == widget.eventId) {
          setState(() => _decoded = size);
        }
      } catch (_) {
        // Dimensions stay unknown; the preview keeps its fallback box.
      }
    }
    return bytes;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _autoLoad = autoLoadMediaFor(context, widget.backend, widget.roomId);
    final animate = _wantsAnimation(context);
    if (animate != _animate) {
      _animate = animate;
      _image = null;
      _decoded = null;
    }
    if (_autoLoad) {
      _image ??= _load();
    } else {
      _image = null;
    }
  }

  @override
  void didUpdateWidget(MessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      _owner.release();
      _owner = BackendSessionOwner(widget.backend);
    }
    if (oldWidget.backend != widget.backend ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.eventId != widget.eventId) {
      _animate = _wantsAnimation(context);
      _image = _autoLoad ? _load() : null;
      _decoded = null;
    } else if (!identical(oldWidget.entry, widget.entry)) {
      _decoded = null;
    }
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _displaySize();
    return GestureDetector(
      // Keep single-tap media navigation inside the image only. Ancestors still
      // own long-press actions and double-tap reactions (including galleries).
      onTap: () {
        if (!_owner.isCurrent) return;
        unawaited(
          openMediaViewer(
            context,
            backend: widget.backend,
            roomId: widget.roomId,
            eventId: widget.eventId,
            entries: widget.entries,
          ),
        );
      },
      child: !_autoLoad
          ? _placeholder('Tap to open image', size)
          : FutureBuilder<Uint8List?>(
              future: _image,
              builder: (context, snapshot) {
                if (_owner.isCurrent && snapshot.hasData) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    // Multi-frame GIF/WebP animate; frames are decoded one at a
                    // time within the bounded size. Auto-fitted previews use
                    // contain so odd-shaped GIFs are never cropped.
                    child: Image(
                      image: boundedMemoryImage(snapshot.data!),
                      width: size.width,
                      height: size.height,
                      fit: _autoFit ? BoxFit.contain : BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          _placeholder('Image unavailable', size),
                    ),
                  );
                }
                return _placeholder(
                  snapshot.hasError ||
                          snapshot.connectionState == ConnectionState.done
                      ? 'Image unavailable'
                      : 'Loading image…',
                  size,
                );
              },
            ),
    );
  }

  Widget _placeholder(String label, Size size) => Container(
    width: size.width,
    height: size.height,
    decoration: BoxDecoration(
      color: widget.palette.raised,
      borderRadius: BorderRadius.circular(12),
    ),
    // A wide GIF's strip is too short for the icon-and-label column.
    child: size.height < 64
        ? Center(
            child: Icon(
              Icons.image_outlined,
              color: widget.palette.secondary,
              size: 20,
            ),
          )
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.image_outlined,
                color: widget.palette.secondary,
                size: 30,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: widget.palette.foreground,
                  fontSize: 11,
                ),
              ),
            ],
          ),
  );
}
