import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'chat_network.dart';
import 'network_logo.dart';
import 'room_logos.dart';
import 'room_pictures.dart';

/// Long-press a chat → Chat picture…: choose a picture only this phone
/// shows for the chat, pick the app logo used when it has no picture, or
/// remove them. Saved on the phone by [RoomPictures] and [RoomLogos].
Future<void> showRoomPictureSheet(
  BuildContext context, {
  required ChatRoom room,
  RoomPictures? pictures,
  RoomLogos? logos,
  AppPalette? palette,
}) async {
  final store = pictures ?? RoomPictures.shared;
  final logoStore = logos ?? RoomLogos.shared;
  final colours = palette ?? paletteFor(defaultVisualTheme);
  final messenger = ScaffoldMessenger.maybeOf(context);
  await store.ensureLoaded();
  if (!context.mounted) return;
  final hasPicture = store.has(room.id);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
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
            ListTile(
              leading: const Icon(Icons.apps_rounded),
              title: const Text('App logo…'),
              subtitle: const Text(
                'Which app’s logo shows when the chat has no picture',
              ),
              onTap: () => Navigator.pop(sheetContext, 'logo'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'logo') {
    await _chooseLogo(context, room: room, store: logoStore, palette: colours);
    return;
  }
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

class _LogoChoice {
  const _LogoChoice(this.network);

  /// Null means automatic detection.
  final ChatNetwork? network;
}

/// The per-room logo picker: automatic, no logo, or a specific app.
Future<void> _chooseLogo(
  BuildContext context, {
  required ChatRoom room,
  required RoomLogos store,
  required AppPalette palette,
}) async {
  await store.ensureLoaded();
  if (!context.mounted) return;
  final current = store.overrideFor(room.id);
  final detected = room.network;
  final options = <_LogoChoice>[
    const _LogoChoice(null),
    const _LogoChoice(ChatNetwork.otherBridge),
    for (final network in ChatNetwork.values)
      if (network.hasLogo) _LogoChoice(network),
  ];
  String label(ChatNetwork? network) => switch (network) {
    null => 'Automatic',
    ChatNetwork.otherBridge => 'No logo — show the letter',
    _ => network.label,
  };
  final choice = await showModalBottomSheet<_LogoChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('App logo'),
              subtitle: Text(
                'Used when this chat has no picture, while App logos is '
                'on in Settings → Appearance.',
              ),
            ),
            for (final option in options)
              ListTile(
                leading: SizedBox(
                  width: 28,
                  height: 28,
                  child: option.network == null
                      ? const Icon(Icons.auto_awesome_outlined)
                      : option.network!.hasLogo
                      ? NetworkLogo(
                          network: option.network!,
                          palette: palette,
                          size: 28,
                        )
                      : const Icon(Icons.text_fields_rounded),
                ),
                title: Text(label(option.network)),
                subtitle: option.network == null
                    ? Text(
                        detected == null || detected == ChatNetwork.unknown
                            ? 'Nothing detected for this chat'
                            : 'Detected: ${detected.label}',
                      )
                    : null,
                trailing: option.network == current
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    ),
  );
  if (choice == null) return;
  await store.set(room.id, choice.network);
}
