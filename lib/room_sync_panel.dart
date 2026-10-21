import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';

/// Distinguishes an unsynced account from one that truly has no rooms.
class RoomSyncPanel extends StatelessWidget {
  const RoomSyncPanel({
    super.key,
    required this.backend,
    required this.palette,
  });

  final ChatBackend backend;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final failed = backend.roomSyncState == RoomSyncState.error;
    final detail = switch (backend.roomSyncIssue) {
      RoomSyncIssue.network =>
        'Can’t reach your homeserver. Check your connection and retry.',
      RoomSyncIssue.homeserver =>
        'Your homeserver rejected the room sync. Try again.',
      RoomSyncIssue.processing =>
        'Room updates could not be processed. Try again.',
      null => 'Large accounts may take a little longer to load.',
    };
    return LayoutBuilder(
      builder: (context, viewport) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: viewport.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    Icon(
                      Icons.sync_problem_rounded,
                      size: 46,
                      color: palette.secondary,
                    )
                  else
                    CircularProgressIndicator(color: palette.accent),
                  const SizedBox(height: 18),
                  Text(
                    failed ? 'Couldn’t sync your rooms' : 'Syncing your rooms…',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.foreground,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: palette.muted, height: 1.4),
                  ),
                  if (failed) ...[
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: () => backend.refreshRooms(),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry sync'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
