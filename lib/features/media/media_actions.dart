import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_temporary_directory.dart';
import '../../attachment_picker.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import '../../room_events.dart';
import 'media_content.dart';
import 'media_features.dart';

/// Hands a private temporary file to the platform share sheet. Completes when
/// the platform has taken the file (share_plus copies it into its own share
/// cache on Android), after which the caller deletes its copy.
typedef MediaSharePresenter =
    Future<void> Function(String path, String mimeType, String name);

Future<void> _systemShare(String path, String mimeType, String name) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path, mimeType: mimeType, name: name)],
    ),
  );
}

/// Overridable in tests; production uses share_plus.
@visibleForTesting
MediaSharePresenter debugMediaSharePresenter = _systemShare;

/// Overridable in tests; production uses the app cache directory.
@visibleForTesting
Future<Directory> Function() debugShareTemporaryRoot = appTemporaryDirectory;

/// Loader for one media event: the live timeline when the room is open (its
/// cached event), falling back to the module's history-capable loader for
/// events outside the loaded timeline (for example, the media gallery).
MediaLoader mediaLoaderFor(ChatBackend backend, String roomId, String eventId) {
  final features = mediaFeaturesOf(backend);
  if (features == null) return () => backend.loadAttachment(roomId, eventId);
  return () async {
    var active = false;
    try {
      active = backend.activeRoomId == roomId;
    } catch (_) {
      // Minimal backends may not track an active room.
    }
    if (active) {
      try {
        return await backend.loadAttachment(roomId, eventId);
      } catch (_) {
        // Not in the loaded timeline: fetch it directly below.
      }
    }
    return features.loadOriginal(roomId, eventId);
  };
}

/// Downloads, decrypts and shares one attachment. The decrypted copy lives in
/// a unique private directory that is deleted once sharing returns or fails.
Future<void> shareMedia(
  BuildContext context, {
  required ChatBackend backend,
  required MediaLoader loader,
}) async {
  final owner = BackendSessionOwner(backend);
  final messenger = ScaffoldMessenger.maybeOf(context);
  Directory? directory;
  try {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Preparing to share…'),
        duration: Duration(seconds: 2),
      ),
    );
    final file = await loader();
    if (!owner.isCurrent) return;
    final root = await debugShareTemporaryRoot();
    directory = await root.createTemp('parallax-share-');
    final name = safeAttachmentName(file.name);
    final path = '${directory.path}/$name';
    await File(path).writeAsBytes(file.bytes, flush: true);
    if (!owner.isCurrent) return;
    await debugMediaSharePresenter(path, file.mimeType, name);
  } catch (_) {
    if (owner.isCurrent) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Couldn’t share this file.')),
      );
    }
  } finally {
    owner.release();
    try {
      await directory?.delete(recursive: true);
    } catch (_) {
      // Cache cleanup is best effort; the directory is app-private.
    }
  }
}

/// Element X "Delete file?" confirmation.
Future<bool> confirmDeleteMedia(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete file?'),
        content: const Text(
          'This file will be removed from the room and members won’t have '
          'access to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ==
    true;

/// Redacts one of the user's media events via the module's guarded path.
Future<void> deleteMediaEvent(
  ChatBackend backend,
  String roomId,
  String eventId,
) {
  final features = mediaFeaturesOf(backend);
  if (features != null) return features.deleteMedia(roomId, eventId);
  if (backend is RoomEventFeatures) {
    return (backend as RoomEventFeatures).redactEvent(roomId, eventId);
  }
  return backend.redactMessage(roomId, eventId);
}

String _date(DateTime time) {
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = time.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'am' : 'pm';
  return '${local.day} ${months[local.month - 1]} ${local.year}, '
      '$hour:$minute $period';
}

/// Element X "File info": name, uploader, date, format and size.
Future<void> showMediaInfo(BuildContext context, ChatEntry entry) {
  final info = MediaInfo.fromEntry(entry);
  final rows = <(String, String)>[
    ('Name', info.name),
    ('Uploaded by', entry.senderLabel),
    ('Uploaded on', _date(entry.time)),
    if (info.mimeType != null) ('Format', info.mimeType!),
    if (info.size != null) ('Size', formatFileSize(info.size!)),
    if (info.width != null && info.height != null)
      ('Dimensions', '${info.width} × ${info.height}'),
    if (info.duration != null)
      ('Duration', formatMediaDuration(info.duration!)),
    if (info.caption != null) ('Caption', info.caption!),
  ];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'File info',
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            for (final (label, value) in rows) ...[
              Text(
                label,
                style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                  color: Theme.of(sheetContext).colorScheme.secondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(value),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    ),
  );
}
