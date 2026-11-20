import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import '../home/room_list_tile.dart';
import '../reactions/message_previews.dart';
import '../threads/timeline_navigation.dart';
import 'note_to_self.dart';
import 'saved_features.dart';
import 'saved_models.dart';

sealed class _Load {
  const _Load();
}

class _Loading extends _Load {
  const _Loading();
}

class _Loaded extends _Load {
  const _Loaded(this.result);
  final SavedEventResult result;
}

class _Failed extends _Load {
  const _Failed();
}

String _key(Bookmark bookmark) => '${bookmark.roomId}\n${bookmark.eventId}';

/// Saved messages (bookmarks). Only identifiers are synced; each message is
/// loaded on demand from the local timeline/database or the homeserver and
/// decrypted on this device.
class SavedMessagesScreen extends StatefulWidget {
  const SavedMessagesScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.features,
    this.onOpenRoom,
  });

  final ChatBackend backend;
  final AppPalette palette;

  /// Defaults to [savedFeaturesOf] the backend.
  final SavedFeatures? features;

  /// Opens a room after the timeline was focused on the saved message.
  /// Defaults to pushing the room screen.
  final void Function(BuildContext context, String roomId)? onOpenRoom;

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  static const _parallelLoads = 4;

  late final _owner = BackendSessionOwner(widget.backend);
  late final SavedFeatures? _features =
      widget.features ?? savedFeaturesOf(widget.backend);
  late final Listenable _changes = Listenable.merge([
    widget.backend,
    if (_features != null && !identical(_features, widget.backend)) _features,
  ]);

  final _loads = <String, _Load>{};
  final _queue = <Bookmark>[];
  final _removed = <String>{};
  int _active = 0;
  String? _roomFilter;
  String? _opening;

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  void _request(Bookmark bookmark) {
    if (_loads.containsKey(_key(bookmark))) return;
    _loads[_key(bookmark)] = const _Loading();
    _queue.add(bookmark);
    _pump();
  }

  void _pump() {
    final features = _features;
    if (features == null) return;
    while (_active < _parallelLoads && _queue.isNotEmpty) {
      final bookmark = _queue.removeAt(0);
      _active++;
      unawaited(_load(features, bookmark));
    }
  }

  Future<void> _load(SavedFeatures features, Bookmark bookmark) async {
    _Load next;
    try {
      next = _Loaded(
        await features.loadSavedEvent(bookmark.roomId, bookmark.eventId),
      );
    } catch (_) {
      next = const _Failed();
    } finally {
      _active--;
    }
    if (!mounted || !_owner.isCurrent) return;
    setState(() => _loads[_key(bookmark)] = next);
    _pump();
  }

  void _retry(Bookmark bookmark) {
    setState(() => _loads.remove(_key(bookmark)));
  }

  Future<void> _refresh() async {
    setState(() {
      _loads.removeWhere((_, load) => load is! _Loading);
    });
  }

  String _roomName(String roomId) {
    for (final room in widget.backend.rooms) {
      if (room.id == roomId) {
        return roomId == _features?.noteToSelfRoomId
            ? noteToSelfTitle
            : room.name;
      }
    }
    return 'Unknown room';
  }

  bool _roomOpenable(String roomId) =>
      widget.backend.rooms.any((room) => room.id == roomId && !room.invited);

  Future<void> _open(Bookmark bookmark) async {
    if (_opening != null || !_owner.isCurrent) return;
    final load = _loads[_key(bookmark)];
    if (!_roomOpenable(bookmark.roomId) ||
        (load is _Loaded &&
            load.result.status == SavedEventStatus.roomUnavailable)) {
      showSavedSnack(context, 'You’re no longer in this room.');
      return;
    }
    final navigation = timelineNavigationOf(widget.backend);
    var focused = navigation == null;
    if (navigation != null) {
      setState(() => _opening = _key(bookmark));
      try {
        await navigation.openRoomAt(bookmark.roomId, bookmark.eventId);
        focused = true;
      } catch (_) {
        focused = false;
      }
      if (!mounted || !_owner.isCurrent) return;
      setState(() => _opening = null);
    }
    if (!focused) {
      showSavedSnack(
        context,
        'Couldn’t jump to that message. Opening the room instead.',
      );
    }
    final open = widget.onOpenRoom;
    if (open != null) {
      open(context, bookmark.roomId);
    } else {
      savedOpenRoomRoute(
        context,
        widget.backend,
        widget.palette,
        bookmark.roomId,
      );
    }
  }

  Future<bool> _remove(Bookmark bookmark) async {
    final features = _features;
    if (features == null || !_owner.isCurrent) return false;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await features.setSaved(bookmark.roomId, bookmark.eventId, saved: false);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'Couldn’t remove this saved message.');
      }
      return false;
    }
    if (!mounted || !_owner.isCurrent) return true;
    setState(() => _removed.add(_key(bookmark)));
    messenger?.removeCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('Removed from saved messages'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_undo(features, bookmark)),
        ),
      ),
    );
    return true;
  }

  Future<void> _undo(SavedFeatures features, Bookmark bookmark) async {
    try {
      await features.setSaved(
        bookmark.roomId,
        bookmark.eventId,
        saved: true,
        savedAt: bookmark.savedAt,
      );
      if (mounted && _owner.isCurrent) {
        setState(() => _removed.remove(_key(bookmark)));
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showSavedSnack(context, 'Couldn’t restore this saved message.');
      }
    }
  }

  Future<void> _showOptions(Bookmark bookmark) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('Go to message'),
              onTap: () => Navigator.pop(sheetContext, 'open'),
            ),
            ListTile(
              leading: Icon(
                Icons.bookmark_remove_outlined,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                'Remove from saved',
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
              ),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent) return;
    switch (choice) {
      case 'open':
        await _open(bookmark);
      case 'remove':
        await _remove(bookmark);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final features = _features;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          minimum: (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
              : EdgeInsets.zero,
          child: AnimatedBuilder(
            animation: _changes,
            builder: (context, _) {
              final all = features == null || !_owner.isCurrent
                  ? const <Bookmark>[]
                  : features.bookmarks.bookmarks
                        .where((b) => !_removed.contains(_key(b)))
                        .toList();
              final roomIds = [
                ...{for (final b in all) b.roomId},
              ];
              final filter = roomIds.contains(_roomFilter) ? _roomFilter : null;
              final shown = filter == null
                  ? all
                  : all.where((b) => b.roomId == filter).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.maybePop(context),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(height: 14),
                        Eyebrow('Saved', palette: p),
                        const SizedBox(height: 4),
                        Text(
                          'Saved messages',
                          style: TextStyle(
                            color: p.foreground,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1.4,
                          ),
                        ),
                        if (roomIds.length > 1) ...[
                          const SizedBox(height: 14),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _RoomChip(
                                  label: 'All rooms',
                                  selected: filter == null,
                                  palette: p,
                                  onTap: () =>
                                      setState(() => _roomFilter = null),
                                ),
                                for (final roomId in roomIds)
                                  _RoomChip(
                                    label: _roomName(roomId),
                                    selected: filter == roomId,
                                    palette: p,
                                    onTap: () =>
                                        setState(() => _roomFilter = roomId),
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                  Expanded(
                    child: shown.isEmpty
                        ? _EmptySaved(palette: p)
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                              itemCount: shown.length + 1,
                              itemBuilder: (context, index) {
                                if (index == shown.length) {
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      8,
                                      10,
                                      8,
                                      0,
                                    ),
                                    child: Text(
                                      'Saved messages sync across your '
                                      'devices. Only links to them are '
                                      'stored on your homeserver, never their '
                                      'text. Swipe a message to remove it.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: p.muted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  );
                                }
                                final bookmark = shown[index];
                                _request(bookmark);
                                final key = _key(bookmark);
                                return Dismissible(
                                  key: ValueKey('saved-$key'),
                                  direction: DismissDirection.endToStart,
                                  confirmDismiss: (_) => _remove(bookmark),
                                  background: Container(
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 24),
                                    margin: const EdgeInsets.only(bottom: 8),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.errorContainer,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Icon(
                                      Icons.bookmark_remove_outlined,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onErrorContainer,
                                    ),
                                  ),
                                  child: _SavedTile(
                                    bookmark: bookmark,
                                    load: _loads[key] ?? const _Loading(),
                                    roomName: _roomName(bookmark.roomId),
                                    palette: p,
                                    busy: _opening == key,
                                    onTap: () {
                                      final load = _loads[key];
                                      if (load is _Failed) {
                                        _retry(bookmark);
                                      } else {
                                        unawaited(_open(bookmark));
                                      }
                                    },
                                    onLongPress: () =>
                                        unawaited(_showOptions(bookmark)),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Semantics(
      selected: selected,
      button: true,
      child: ActionChip(
        onPressed: onTap,
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        backgroundColor: selected ? palette.accent : palette.surface,
        labelStyle: TextStyle(
          color: selected ? palette.accentOn : palette.foreground,
        ),
        side: BorderSide(color: selected ? palette.accent : palette.stroke),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

class _SavedTile extends StatelessWidget {
  const _SavedTile({
    required this.bookmark,
    required this.load,
    required this.roomName,
    required this.palette,
    required this.onTap,
    required this.onLongPress,
    this.busy = false,
  });

  final Bookmark bookmark;
  final _Load load;
  final String roomName;
  final AppPalette palette;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final (title, preview, time, muted) = switch (load) {
      _Loading() => ('Loading…', '', bookmark.savedAt, true),
      _Failed() => (
        'Couldn’t load this message',
        'Tap to try again.',
        bookmark.savedAt,
        true,
      ),
      _Loaded(:final result) => switch (result.status) {
        SavedEventStatus.roomUnavailable => (
          'Room unavailable',
          'You’re no longer in this room. Rejoin it to see this message, or '
              'remove it from saved messages.',
          bookmark.savedAt,
          true,
        ),
        SavedEventStatus.notFound => (
          'Message unavailable',
          'This message may have been deleted.',
          bookmark.savedAt,
          true,
        ),
        SavedEventStatus.available => (
          result.entry!.senderLabel,
          messagePreviewText(result.entry!),
          result.entry!.time,
          result.entry!.redacted,
        ),
      },
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: InkWell(
          onTap: busy ? null : onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InitialAvatar(name: title, palette: p, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.foreground,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            RoomListTile.timeLabel(context, time),
                            style: TextStyle(color: p.muted, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.forum_outlined,
                            size: 12,
                            color: p.secondary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              roomName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.secondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          preview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: muted ? p.muted : p.foreground,
                            fontStyle: muted
                                ? FontStyle.italic
                                : FontStyle.normal,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (busy) ...[
                  const SizedBox(width: 8),
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySaved extends StatelessWidget {
  const _EmptySaved({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: viewport.maxHeight),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(35),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.bookmark_border_rounded,
                  size: 50,
                  color: palette.secondary,
                ),
                const SizedBox(height: 14),
                Text(
                  'No saved messages yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: palette.foreground,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Long-press any message and choose Save to keep it here. '
                  'Saved messages sync across your devices; only links to '
                  'them are stored, never their text.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
