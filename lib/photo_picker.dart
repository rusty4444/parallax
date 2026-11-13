import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_backend.dart';
import 'features/media/image_editor_screen.dart';
import 'messaging_features.dart';

Future<MediaSelection> _editableImage(XFile file) async {
  final mimeType = file.mimeType;
  return MediaSelection(
    bytes: await file.readAsBytes(),
    name: file.name,
    mimeType:
        mimeType ??
        switch (file.name.split('.').last.toLowerCase()) {
          'png' => 'image/png',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          'heic' || 'heif' => 'image/heic',
          _ => 'image/jpeg',
        },
  );
}

Future<void> pickAndSendImages(
  BuildContext context,
  ChatBackend backend,
  String roomId, {
  @visibleForTesting Future<List<XFile>> Function()? picker,
}) async {
  if (backend.sending) return;
  try {
    final images =
        await (picker ??
                () => ImagePicker().pickMultiImage(
                  limit: 10,
                  requestFullMetadata: false,
                ))
            .call();
    if (!context.mounted || images.isEmpty) return;
    if (images.length > 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select no more than 10 photos.')),
      );
      return;
    }
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${images.length} ${images.length == 1 ? 'photo' : 'photos'}',
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Photos are sent in order. Tap the edit icon to crop, rotate '
                  'or mark up a photo. A failed upload may leave earlier '
                  'photos in the room.',
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 144,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: images.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, index) => Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: FutureBuilder<Uint8List>(
                            future: images[index].readAsBytes(),
                            builder: (context, snapshot) {
                              final bytes = snapshot.data;
                              if (bytes == null) {
                                return const SizedBox(
                                  width: 128,
                                  height: 144,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return Image.memory(
                                bytes,
                                width: 128,
                                height: 144,
                                fit: BoxFit.cover,
                                cacheWidth: 384,
                              );
                            },
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: CircleAvatar(
                            radius: 18,
                            backgroundColor: Colors.black54,
                            child: IconButton(
                              tooltip: 'Edit photo ${index + 1}',
                              iconSize: 18,
                              color: Colors.white,
                              onPressed: () async {
                                final source = await _editableImage(
                                  images[index],
                                );
                                if (!sheetContext.mounted) return;
                                final edited = await showImageEditor(
                                  sheetContext,
                                  source,
                                );
                                if (edited == null || !sheetContext.mounted) {
                                  return;
                                }
                                images[index] = XFile.fromData(
                                  edited.bytes,
                                  path: edited.name,
                                  name: edited.name,
                                  mimeType: edited.mimeType,
                                );
                                setSheetState(() {});
                              },
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext, true),
                    child: const Text('Send photos'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await backend.sendImages(roomId, images);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Photo upload failed. Some photos may have sent.'),
        ),
      );
    }
  }
}
