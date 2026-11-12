// Hook implementations for the threads and search feature module.
//
// Thread list, thread summaries, local message search and jump-to-event.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../matrix_backend.dart';
import '../../thread_screen.dart';
import 'local_message_search.dart';
import 'message_search_settings.dart';
import 'thread_features.dart';
import 'thread_list_screen.dart';
import 'thread_widgets.dart';
import 'timeline_navigation.dart';

/// Room header: "Threads" (threads list). While the timeline is focused on an
/// event, "Jump to latest" takes its place: the header has room for one
/// module action (the threads list stays reachable from room details).
List<Widget> threadRoomHeaderActions(
  BuildContext context,
  RoomHookContext ctx,
) {
  _startDeviceIndex(ctx.backend);
  final navigation = timelineNavigationOf(ctx.backend);
  final focused = navigation?.focusedEventIn(ctx.roomId) != null;
  final threads = threadFeaturesOf(ctx.backend);
  return [
    if (navigation != null && focused)
      IconButton(
        key: const ValueKey('thread-jump-to-latest'),
        tooltip: 'Jump to latest',
        visualDensity: VisualDensity.compact,
        onPressed: () => jumpToLatest(context, navigation, ctx.roomId),
        icon: Badge(
          isLabelVisible: navigation.hasNewerThanFocus(ctx.roomId),
          smallSize: 8,
          backgroundColor: ctx.palette.accent,
          child: Icon(
            Icons.vertical_align_bottom_rounded,
            color: ctx.palette.secondary,
          ),
        ),
      )
    else if (threads != null)
      IconButton(
        key: const ValueKey('thread-list-action'),
        tooltip: 'Threads',
        visualDensity: VisualDensity.compact,
        onPressed: () => openThreadsList(
          context,
          backend: ctx.backend,
          roomId: ctx.roomId,
          palette: ctx.palette,
        ),
        icon: Icon(Icons.forum_rounded, color: ctx.palette.secondary),
      ),
  ];
}

/// Footer under a message: the thread summary of a thread root and the
/// "Jumped to this message" marker of a focused timeline.
Widget? threadEntryFooter(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  final navigation = timelineNavigationOf(ctx.backend);
  final focused = navigation?.focusedEventIn(ctx.roomId) == entry.id;
  final summary = entry.threadReplyCount > 0 && !entry.redacted;
  if (!summary && !focused) return null;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (summary)
        ThreadSummaryChip(
          entry: entry,
          palette: ctx.palette,
          onBubble: ctx.onBubble,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ThreadScreen(
                backend: ctx.backend,
                roomId: ctx.roomId,
                root: entry,
                palette: ctx.palette,
              ),
            ),
          ),
        ),
      if (focused && navigation != null)
        FocusedEventMarker(
          backend: ctx.backend,
          roomId: ctx.roomId,
          palette: ctx.palette,
          onBubble: ctx.onBubble,
          navigation: navigation,
        ),
    ],
  );
}

/// The room screen already offers "Open thread" for every message.
List<MessageActionItem> threadMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

/// Room details: entry point to the threads list.
List<Widget> threadRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  if (threadFeaturesOf(ctx.backend) == null) return const [];
  final p = ctx.palette;
  return [
    Card(
      key: const ValueKey('thread-details-section'),
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.stroke),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        leading: Icon(Icons.forum_rounded, color: p.secondary),
        title: Text('Threads', style: TextStyle(color: p.foreground)),
        subtitle: Text(
          'Browse every thread in this room',
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
        onTap: () => openThreadsList(
          context,
          backend: ctx.backend,
          roomId: ctx.roomId,
          palette: p,
        ),
      ),
    ),
  ];
}

// --- New extension points (wire in lib/hooks/registry.dart) ---------------

/// Settings: "Search this device's history" toggle, privacy note and
/// "Clear search index". Wire into `settingsSectionsFor`.
List<Widget> messageSearchSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final search = localMessageSearchOf(ctx.backend);
  if (search == null) return const [];
  return [
    const SizedBox(height: 28),
    DeviceSearchSettingsCard(
      key: const ValueKey('device-search-settings'),
      search: search,
      palette: ctx.palette,
    ),
  ];
}

/// Starts the device message index for the signed-in session as soon as the
/// app shell is up, so messages are indexed before the first search. Wire
/// into `wrapSignedInApp`. Without it, indexing starts when a room or message
/// search is first opened.
Widget wrapWithMessageSearchIndex(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _DeviceIndexStarter(backend: ctx.backend, child: child);

class _DeviceIndexStarter extends StatefulWidget {
  const _DeviceIndexStarter({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_DeviceIndexStarter> createState() => _DeviceIndexStarterState();
}

class _DeviceIndexStarterState extends State<_DeviceIndexStarter> {
  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
    _changed();
  }

  @override
  void didUpdateWidget(covariant _DeviceIndexStarter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend) return;
    oldWidget.backend.removeListener(_changed);
    widget.backend.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.backend.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (widget.backend.connection == SessionStatus.ready) {
      _startDeviceIndex(widget.backend);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Starts indexing only for the live Matrix backend (never for fakes).
void _startDeviceIndex(ChatBackend backend) {
  if (backend is! MatrixBackend) return;
  final search = localMessageSearchOf(backend);
  if (search == null) return;
  // Never notify listeners synchronously from build.
  scheduleMicrotask(() {
    try {
      search.ensureStarted();
    } catch (_) {}
  });
}
