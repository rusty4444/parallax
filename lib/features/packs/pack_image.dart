import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import 'custom_reactions.dart';
import 'pack_features.dart';
import 'pack_model.dart';

export 'custom_reactions.dart';

/// A pack image (custom emoji or sticker) loaded through [features]' bounded,
/// authenticated thumbnail cache. Shows [fallback] while loading fails or
/// when the image cannot be decoded.
class PackImageView extends StatefulWidget {
  const PackImageView({
    super.key,
    required this.features,
    required this.url,
    required this.size,
    this.fallback,
    this.semanticLabel,
    this.placeholder,
  });

  final PacksFeatures features;
  final Uri url;

  /// Height (and maximum width / 1) of the image box; wide images may use
  /// up to twice this width.
  final double size;
  final Widget? fallback;
  final Widget? placeholder;
  final String? semanticLabel;

  @override
  State<PackImageView> createState() => _PackImageViewState();
}

class _PackImageViewState extends State<PackImageView> {
  Uint8List? _bytes;
  bool _failed = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PackImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !identical(oldWidget.features, widget.features)) {
      _load();
    }
  }

  void _load() {
    final request = ++_request;
    _failed = false;
    _bytes = widget.features.cachedPackImage(widget.url);
    if (_bytes != null) return;
    unawaited(
      widget.features
          .loadPackImage(widget.url)
          .then(
            (bytes) {
              if (!mounted || request != _request) return;
              setState(() {
                _bytes = bytes;
                _failed = bytes == null;
              });
            },
            onError: (Object _) {
              if (mounted && request == _request) {
                setState(() => _failed = true);
              }
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final fallback =
        widget.fallback ??
        Icon(Icons.emoji_emotions_outlined, size: size * 0.8);
    final bytes = _bytes;
    final Widget child;
    if (bytes != null) {
      final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
      child = Image.memory(
        bytes,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        // Bounded decode: never more pixels than the box needs.
        cacheHeight: (size * ratio).round().clamp(1, 256),
        semanticLabel: widget.semanticLabel,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (_failed) {
      child = fallback;
    } else {
      child = widget.placeholder ?? SizedBox(width: size, height: size);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: size * 2, maxHeight: size),
      child: child,
    );
  }
}

/// An `<img data-mx-emoticon>` in a message, at text height. Falls back to
/// its `:shortcode:` alt text when no packs backend is available.
class EmoticonInline extends StatelessWidget {
  const EmoticonInline({
    super.key,
    required this.url,
    required this.alt,
    required this.size,
    required this.style,
    this.backend,
  });

  final Uri url;
  final String alt;
  final double size;
  final TextStyle style;

  /// Defaults to [currentPacksBackend].
  final ChatBackend? backend;

  @override
  Widget build(BuildContext context) {
    final owner = backend ?? currentPacksBackend;
    final features = owner == null ? null : packsFeaturesOf(owner);
    final text = Text(alt, style: style);
    if (features == null) return text;
    return Tooltip(
      message: alt,
      excludeFromSemantics: true,
      child: PackImageView(
        features: features,
        url: url,
        size: size,
        fallback: text,
        semanticLabel: alt,
      ),
    );
  }
}

/// Human label for a reaction key: the emoji itself, or the custom emoji's
/// `:shortcode:` when a pack in [roomId] provides it.
String reactionKeyLabel(ChatBackend backend, String roomId, String key) {
  if (!isCustomReactionKey(key)) return key;
  final url = parseMxcUri(key);
  if (url == null) return 'custom emoji';
  final found = packsFeaturesOf(backend)?.availablePacks(roomId).findByUrl(url);
  return found == null ? 'custom emoji' : ':${found.image.shortcode}:';
}

/// Reaction chip label for a custom emoji key (image and count). Returns
/// null for ordinary emoji keys so callers keep their text label.
Widget? customReactionChipLabel({
  required ChatBackend backend,
  required String roomId,
  required String reactionKey,
  required int count,
  TextStyle? style,
}) {
  if (!isCustomReactionKey(reactionKey)) return null;
  final url = parseMxcUri(reactionKey);
  final features = packsFeaturesOf(backend);
  final label = reactionKeyLabel(backend, roomId, reactionKey);
  final fallback = Text(label, style: style);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (url == null || features == null)
        fallback
      else
        PackImageView(
          key: ValueKey('custom-reaction-$reactionKey'),
          features: features,
          url: url,
          size: 18,
          fallback: fallback,
          semanticLabel: label,
        ),
      const SizedBox(width: 4),
      Text('$count', style: style),
    ],
  );
}
