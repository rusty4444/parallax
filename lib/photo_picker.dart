import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_backend.dart';

Future<void> pickAndSendImages(
  BuildContext context,
  ChatBackend backend,
  String roomId,
) async {
  if (backend.sending) return;
  try {
    final images = await ImagePicker().pickMultiImage(
      limit: 10,
      requestFullMetadata: false,
    );
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
      builder: (sheetContext) => SafeArea(
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
                'Photos are sent in order. A failed upload may leave '
                'earlier photos in the room.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 144,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(
                      File(images[index].path),
                      width: 128,
                      height: 144,
                      fit: BoxFit.cover,
                      cacheWidth: 384,
                    ),
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
