import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_backend.dart';
import 'room_pictures.dart';

/// Long-press a chat → Chat picture…: choose a picture only this phone
/// shows for the chat, or remove it. Saved on the phone by [RoomPictures].
Future<void> showRoomPictureSheet(
  BuildContext context, {
  required ChatRoom room,
  RoomPictures? pictures,
}) async {
  final store = pictures ?? RoomPictures.shared;
  final messenger = ScaffoldMessenger.maybeOf(context);
  await store.ensureLoaded();
  if (!context.mounted) return;
  final hasPicture = store.has(room.id);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('Chat picture · only shown on this phone'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(hasPicture ? 'Change picture' : 'Choose picture'),
            onTap: () => Navigator.pop(sheetContext, 'choose'),
          ),
          if (hasPicture)
            ListTile(
              leading: const Icon(Icons.hide_image_outlined),
              title: const Text('Remove picture'),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  try {
    if (choice == 'remove') {
      await store.remove(room.id);
      return;
    }
    final selection = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (selection == null) return;
    await store.setFromImage(room.id, await selection.readAsBytes());
  } catch (error) {
    final message = switch (error) {
      ArgumentError(:final message) => '$message',
      FormatException() => 'That file isn’t a picture the app can read.',
      _ => 'Couldn’t update this chat’s picture.',
    };
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
