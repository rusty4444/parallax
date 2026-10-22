import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'media_viewer.dart';

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
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final String eventId;
  final double width;
  final double height;

  @override
  State<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<MessageImage> {
  Future<Uint8List?>? _image;
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  bool _autoLoad = true;

  Future<Uint8List?> _load() async {
    final owner = _owner;
    final roomId = widget.roomId;
    final eventId = widget.eventId;
    final bytes = await widget.backend.loadImage(roomId, eventId);
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
                  child: Image.memory(
                    snapshot.data!,
                    width: widget.width,
                    height: widget.height,
                    fit: BoxFit.cover,
                    cacheWidth: (widget.width * 3).round().clamp(1, 1024),
                    cacheHeight: (widget.height * 3).round().clamp(1, 1024),
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
