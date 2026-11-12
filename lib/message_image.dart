import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/media/media_content.dart';
import 'features/media/media_features.dart';
import 'media_viewer.dart';

/// Animated GIF/WebP originals up to this size play in the timeline; larger
/// ones show their (static) thumbnail.
const maxTimelineAnimationBytes = 4 * 1024 * 1024;

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

  @override
  State<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<MessageImage> {
  Future<Uint8List?>? _image;
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  bool _autoLoad = true;
  bool _animate = false;

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
    return bytes;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _autoLoad =
        FeatureSettingsScope.maybeOf(context)?.preferences.autoLoadMedia ??
        true;
    final animate = _wantsAnimation(context);
    if (animate != _animate) {
      _animate = animate;
      _image = null;
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
    }
  }

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
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
        ? _placeholder('Tap to open image')
        : FutureBuilder<Uint8List?>(
            future: _image,
            builder: (context, snapshot) {
              if (_owner.isCurrent && snapshot.hasData) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  // Multi-frame GIF/WebP animate; frames are decoded one at a
                  // time within the bounded size.
                  child: Image(
                    image: boundedMemoryImage(snapshot.data!),
                    width: widget.width,
                    height: widget.height,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        _placeholder('Image unavailable'),
                  ),
                );
              }
              return _placeholder(
                snapshot.hasError ||
                        snapshot.connectionState == ConnectionState.done
                    ? 'Image unavailable'
                    : 'Loading image…',
              );
            },
          ),
  );

  Widget _placeholder(String label) => Container(
    width: widget.width,
    height: widget.height,
    decoration: BoxDecoration(
      color: widget.palette.raised,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.image_outlined, color: widget.palette.secondary, size: 30),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(color: widget.palette.foreground, fontSize: 11),
        ),
      ],
    ),
  );
}
