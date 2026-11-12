import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'network_logo.dart';
import 'room_logos.dart';
import 'room_pictures.dart';
import 'widgets.dart';

/// A chat's picture, in order: one set on this phone (Settings → long-press
/// a chat → Chat picture), the chat's own picture, its people's pictures,
/// then the app's logo (when Settings → Appearance → App logos is on) or the
/// first letter of its name.
class RoomAvatar extends StatelessWidget {
  const RoomAvatar({
    super.key,
    required this.room,
    required this.backend,
    required this.palette,
    this.size = 52,
    this.pictures,
    this.logoOverrides,
  });

  final ChatRoom room;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  /// Pictures set on this phone; defaults to [RoomPictures.shared].
  final RoomPictures? pictures;

  /// Per-room logo choices; defaults to [RoomLogos.shared].
  final RoomLogos? logoOverrides;

  RoomLogos get _logoStore => logoOverrides ?? RoomLogos.shared;

  @override
  Widget build(BuildContext context) {
    final pictures = this.pictures ?? RoomPictures.shared;
    final logos =
        FeatureSettingsScope.maybeOf(context)?.preferences.networkLogos ??
        false;
    final overrides = _logoStore;
    return ListenableBuilder(
      listenable: Listenable.merge([pictures, overrides]),
      builder: (context, _) {
        final local = pictures.pictureFor(room.id);
        if (local != null) {
          return _LocalPicture(bytes: local, label: room.name, size: size);
        }
        return _remote(logos);
      },
    );
  }

  /// The logo for the chat's app when [logos] is on and there is one, else
  /// the first letter of its name.
  Widget _letter(bool logos) {
    // An explicit per-room choice wins over detection; "no logo" is stored
    // as otherBridge, which has no logo and so shows the letter.
    final network = _logoStore.overrideFor(room.id) ?? room.network;
    if (logos && network != null && network.hasLogo) {
      return NetworkLogo(
        network: network,
        palette: palette,
        size: size,
        semanticLabel: room.name,
      );
    }
    return InitialAvatar(name: room.name, palette: palette, size: size);
  }

  Widget _remote(bool logos) {
    if (room.avatarUrl case final url?) {
      return _AvatarFace(
        name: room.name,
        url: url,
        backend: backend,
        palette: palette,
        size: size,
        fallback: _letter(logos),
      );
    }
    final faces = room.heroes.take(4).toList();
    // Nobody pictured: the logo stands for the chat rather than a letter.
    if (faces.isEmpty || (logos && faces.every((face) => face.url == null))) {
      return _letter(logos);
    }
    if (faces.length == 1) {
      return _AvatarFace(
        name: faces.first.name,
        url: faces.first.url,
        backend: backend,
        palette: palette,
        size: size,
        fallback: logos ? _letter(logos) : null,
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

/// A picture set on this phone (already a small square JPEG in memory).
class _LocalPicture extends StatelessWidget {
  const _LocalPicture({
    required this.bytes,
    required this.label,
    required this.size,
  });

  final Uint8List bytes;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    image: true,
    child: ClipOval(
      child: Image.memory(
        bytes,
        width: size,
        height: size,
        cacheWidth: (size * 3).round().clamp(1, roomPictureSize),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    ),
  );
}

/// One person's avatar (an `mxc://` URI loaded through the backend's bounded
/// avatar cache), falling back to their initial.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.name,
    required this.url,
    required this.backend,
    required this.palette,
    this.size = 32,
  });

  final String name;
  final Uri? url;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  @override
  Widget build(BuildContext context) => _AvatarFace(
    name: name,
    url: url,
    backend: backend,
    palette: palette,
    size: size,
  );
}

class _AvatarFace extends StatefulWidget {
  const _AvatarFace({
    required this.name,
    required this.url,
    required this.backend,
    required this.palette,
    required this.size,
    this.fallback,
  });
  final String name;
  final Uri? url;
  final ChatBackend backend;
  final AppPalette palette;
  final double size;

  /// Shown with no picture or while it can't load; the initial by default.
  final Widget? fallback;

  @override
  State<_AvatarFace> createState() => _AvatarFaceState();
}

class _AvatarFaceState extends State<_AvatarFace> {
  Future<Uint8List?>? _image;
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final url = widget.url;
    _cached = url == null ? null : widget.backend.cachedAvatar(url);
    _image = url == null
        ? null
        : _cached != null
        ? Future.value(_cached)
        : widget.backend.loadAvatar(url);
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
    final fallback =
        widget.fallback ??
        InitialAvatar(
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
        // Cached avatars draw on the first frame (no initial flash).
        initialData: _cached,
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
