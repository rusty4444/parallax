import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../widgets.dart';
import '../home/settings_widgets.dart';
import 'folder_tabs.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_messages_screen.dart';

/// Settings → Saved: Note to self, Saved messages and Chat folders.
class SavedSettingsSection extends StatefulWidget {
  const SavedSettingsSection({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final SavedFeatures features;

  @override
  State<SavedSettingsSection> createState() => _SavedSettingsSectionState();
}

class _SavedSettingsSectionState extends State<SavedSettingsSection> {
  late Listenable _changes = _merge();
  bool _opening = false;

  Listenable _merge() => Listenable.merge([
    widget.backend,
    if (!identical(widget.features, widget.backend)) widget.features,
  ]);

  @override
  void didUpdateWidget(SavedSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend) ||
        !identical(oldWidget.features, widget.features)) {
      _changes = _merge();
    }
  }

  Future<void> _openNote() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await openNoteToSelfRoom(
        context,
        backend: widget.backend,
        palette: widget.palette,
        features: widget.features,
      );
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: _changes,
      builder: (context, _) {
        final saved = widget.features.bookmarks.length;
        final folders = widget.features.folders.folders.length;
        final hasNote = widget.features.noteToSelfRoomId != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 28),
            Eyebrow('Saved', palette: p),
            const SizedBox(height: 10),
            SettingsGroup(
              palette: p,
              footer:
                  'Saved messages and folders sync across your devices '
                  'through your account. Only chat and message IDs and '
                  'folder names are stored, never message text.',
              children: [
                ListTile(
                  leading: NoteToSelfAvatar(palette: p, size: 36),
                  title: const Text('Note to self'),
                  subtitle: Text(
                    hasNote
                        ? 'Your private, encrypted notes'
                        : 'Start a private, encrypted chat with just you',
                  ),
                  trailing: _opening
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: _opening ? null : _openNote,
                ),
                ListTile(
                  leading: const Icon(Icons.bookmarks_outlined),
                  title: const Text('Saved messages'),
                  subtitle: Text(
                    saved == 0
                        ? 'Nothing saved yet'
                        : saved == 1
                        ? '1 message'
                        : '$saved messages',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => SavedMessagesScreen(
                        backend: widget.backend,
                        palette: p,
                        features: widget.features,
                      ),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_copy_outlined),
                  title: const Text('Chat folders'),
                  subtitle: Text(
                    folders == 0
                        ? 'Group chats into tabs'
                        : folders == 1
                        ? '1 folder'
                        : '$folders folders',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openFoldersScreen(
                    context,
                    backend: widget.backend,
                    palette: p,
                    features: widget.features,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
