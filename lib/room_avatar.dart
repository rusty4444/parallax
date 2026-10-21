import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'widgets.dart';

class RoomAvatar extends StatelessWidget {
  const RoomAvatar({
    super.key,
    required this.room,
    required this.backend,
    required this.palette,
    this.size = 52,
  });

  final ChatRoom room;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (room.avatarUrl case final url?) {
      return _AvatarFace(
        name: room.name,
        url: url,
        backend: backend,
        palette: palette,
        size: size,
      );
    }
    final faces = room.heroes.take(4).toList();
    if (faces.isEmpty) {
      return InitialAvatar(name: room.name, palette: palette, size: size);
    }
    if (faces.length == 1) {
      return _AvatarFace(
        name: faces.first.name,
        url: faces.first.url,
        backend: backend,
        palette: palette,
        size: size,
      );
    }
    final faceSize = size * 0.55;
    final end = size - faceSize;
    final offsets = switch (faces.length) {
      2 => [Offset(0, end / 2), Offset(end, end / 2)],
      3 => [Offset(end / 2, 0), Offset(0, end), Offset(end, end)],
      _ => [Offset.zero, Offset(end, 0), Offset(0, end), Offset(end, end)],
    };
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < faces.length; i++)
            Positioned(
              left: offsets[i].dx,
              top: offsets[i].dy,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.background,
                ),
                child: _AvatarFace(
                  name: faces[i].name,
                  url: faces[i].url,
                  backend: backend,
                  palette: palette,
                  size: faceSize - 3,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AvatarFace extends StatefulWidget {
  const _AvatarFace({
    required this.name,
    required this.url,
    required this.backend,
    required this.palette,
    required this.size,
  });
  final String name;
  final Uri? url;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  @override
  State<_AvatarFace> createState() => _AvatarFaceState();
}

class _AvatarFaceState extends State<_AvatarFace> {
  Future<Uint8List?>? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final url = widget.url;
    _image = url == null ? null : widget.backend.loadAvatar(url);
  }

  @override
  void didUpdateWidget(_AvatarFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.backend != widget.backend) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = InitialAvatar(
      name: widget.name,
      palette: widget.palette,
      size: widget.size,
    );
    final image = _image;
    if (image == null) return fallback;
    return Semantics(
      label: widget.name,
      child: FutureBuilder<Uint8List?>(
        future: image,
        builder: (context, snapshot) => snapshot.data == null
            ? fallback
            : ClipOval(
                child: Image.memory(
                  snapshot.data!,
                  width: widget.size,
                  height: widget.size,
                  cacheWidth: (widget.size * 3).round().clamp(1, 384),
                  cacheHeight: (widget.size * 3).round().clamp(1, 384),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                ),
              ),
      ),
    );
  }
}
