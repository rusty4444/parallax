import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../messaging_features.dart';

/// Round video messages ("video notes", Telegram style). Sent as a standard
/// `m.video` so every client can play it, with a Parallax marker so Parallax
/// renders it as a circular inline note.
const videoNoteMarker = 'net.samrusselltech.parallax.video_note';

bool isVideoNote(Map<String, Object?> content) =>
    content[videoNoteMarker] == true;

/// Records a short video with the system camera and sends it as a video note.
Future<void> recordAndSendVideoNote(
  BuildContext context,
  ChatBackend backend,
  String roomId,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final picked = await ImagePicker().pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(seconds: 60),
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (bytes.isEmpty) return;
    if (bytes.length > 20 * 1024 * 1024) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Video notes must be under 20 MB.')),
      );
      return;
    }
    final features = backend is MessagingFeatures
        ? backend as MessagingFeatures
        : null;
    if (features == null) return;
    await features.queueMedia(
      roomId,
      MediaSelection(
        bytes: bytes,
        name: picked.name.isEmpty ? 'video-note.mp4' : picked.name,
        mimeType: picked.mimeType ?? 'video/mp4',
        extraContent: const {videoNoteMarker: true},
      ),
    );
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Couldn’t record the video note.')),
    );
  }
}

/// Composer attachment sheet → "Video note".
List<ComposerAttachmentAction> videoNoteComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) {
  if (ctx.room?.invited ?? false) return const [];
  return [
    ComposerAttachmentAction(
      id: 'media.video-note',
      icon: Icons.videocam_outlined,
      label: 'Video note',
      onSelected: (context) =>
          recordAndSendVideoNote(context, ctx.backend, ctx.roomId),
    ),
  ];
}
