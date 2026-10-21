import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';

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
  late Future<Uint8List?> _image = _load();

  Future<Uint8List?> _load() =>
      widget.backend.loadImage(widget.roomId, widget.eventId);

  @override
  void didUpdateWidget(MessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId ||
        oldWidget.eventId != widget.eventId) {
      _image = _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            snapshot.data!,
            width: widget.width,
            height: widget.height,
            fit: BoxFit.cover,
            cacheWidth: (widget.width * 3).round().clamp(1, 1024),
            cacheHeight: (widget.height * 3).round().clamp(1, 1024),
            errorBuilder: (_, _, _) => _placeholder('Image unavailable'),
          ),
        );
      }
      return _placeholder(
        snapshot.hasError
            ? 'Image unavailable'
            : snapshot.connectionState == ConnectionState.done
            ? 'Image unavailable'
            : 'Loading image…',
      );
    },
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
