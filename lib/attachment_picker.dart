import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'chat_backend.dart';

String safeAttachmentName(String raw) {
  final name = raw
      .replaceAll(RegExp(r'[\\/\x00-\x1F:*?"<>|]'), '_')
      .replaceFirst(RegExp(r'^\.+'), '')
      .trim();
  if (name.isEmpty) return 'attachment';
  return name.length > 120 ? name.substring(0, 120) : name;
}

Future<void> pickAndSendAttachment(
  BuildContext context,
  ChatBackend backend,
  String roomId,
) async {
  if (backend.sending) return;
  try {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null || !context.mounted) return;
    final length = await file.length();
    if (length == null || length <= 0 || length > 20 * 1024 * 1024) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose a file smaller than 20 MB.')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send file?'),
        content: Text(file.name, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Send file'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await backend.sendAttachment(roomId, file.xFile);
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File upload failed. It may have sent.')),
      );
    }
  }
}

Future<bool> saveAttachment(
  BuildContext context,
  ChatBackend backend,
  String roomId,
  String eventId,
) async {
  try {
    final file = await backend.loadAttachment(roomId, eventId);
    if (!context.mounted) return false;
    final saved = await FilePicker.saveFile(
      fileName: safeAttachmentName(file.name),
      bytes: file.bytes,
      mimeType: file.mimeType,
    );
    if (!context.mounted) return false;
    if (saved == null) return false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('File saved.')));
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t save this attachment.')),
      );
    }
    return false;
  }
}
