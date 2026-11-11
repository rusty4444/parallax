import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import 'forward_content.dart';
import 'forward_screen.dart';
import 'message_action_features.dart';
import 'message_previews.dart';

/// Pins or unpins with user-facing error handling. Returns true on success.
Future<bool> setMessagePinned(
  BuildContext context, {
  required MessageActionFeatures features,
  required String roomId,
  required String eventId,
  required bool pinned,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await features.setPinned(roomId, eventId, pinned: pinned);
    return true;
  } catch (_) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            pinned
                ? 'Couldn’t pin this message.'
                : 'Couldn’t unpin this message.',
          ),
        ),
      );
    return false;
  }
}

/// Shared resolution of pinned events: the loaded timeline first (always
/// fresh, edits applied), otherwise a server fetch.
mixin _PinnedEntryResolver<T extends StatefulWidget> on State<T> {
  ChatBackend get backend;
  MessageActionFeatures get features;
  String get roomId;

  final _fetched = <String, ChatEntry?>{};
  final _failed = <String>{};
  final _inFlight = <String>{};
  int _fetchGeneration = 0;

  ChatEntry? timelineEntry(String id) => backend.activeRoomId == roomId
      ? backend.messages.where((m) => m.id == id).firstOrNull
      : null;

  ChatEntry? entryFor(String id) => timelineEntry(id) ?? _fetched[id];

  bool isMissing(String id) =>
      timelineEntry(id) == null &&
      _fetched.containsKey(id) &&
      _fetched[id] == null;

  bool hasFailed(String id) => _failed.contains(id);

  void forgetFetched(Iterable<String> keep) {
    final ids = keep.toSet();
    _fetched.removeWhere((id, _) => !ids.contains(id));
    _failed.removeWhere((id) => !ids.contains(id));
    _fetchGeneration++;
    _inFlight.clear();
  }

  void retry(String id) {
    _failed.remove(id);
    ensureLoaded(id);
  }

  void ensureLoaded(String id) {
    if (timelineEntry(id) != null ||
        _fetched.containsKey(id) ||
        _failed.contains(id) ||
        !_inFlight.add(id)) {
      return;
    }
    final generation = _fetchGeneration;
    unawaited(
      features
          .loadEvent(roomId, id)
          .then<void>(
            (entry) {
              if (!mounted || generation != _fetchGeneration) return;
              _inFlight.remove(id);
              markNeedsRebuild(() => _fetched[id] = entry);
            },
            onError: (Object _) {
              if (!mounted || generation != _fetchGeneration) return;
              _inFlight.remove(id);
              markNeedsRebuild(() => _failed.add(id));
            },
          ),
    );
  }

  /// setState that is safe from ChangeNotifier callbacks fired mid-build.
  void markNeedsRebuild([VoidCallback? change]) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      change?.call();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(change ?? () {});
  }
}

/// Element X pinned messages banner under the room header: shows one pin at
/// a time with an "n of N" indicator; tap shows it and moves to the next.
class PinnedMessagesBanner extends StatefulWidget {
  const PinnedMessagesBanner({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.palette,
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final String roomId;
  final AppPalette palette;

  @override
  State<PinnedMessagesBanner> createState() => _PinnedMessagesBannerState();
}

class _PinnedMessagesBannerState extends State<PinnedMessagesBanner>
    with _PinnedEntryResolver<PinnedMessagesBanner> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  List<String> _ids = const [];
  int _index = -1;

  @override
  ChatBackend get backend => widget.backend;
  @override
  MessageActionFeatures get features => widget.features;
  @override
  String get roomId => widget.roomId;

  @override
  void initState() {
    super.initState();
    _sync();
    widget.backend.addListener(_onBackend);
  }

  @override
  void didUpdateWidget(PinnedMessagesBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      oldWidget.backend.removeListener(_onBackend);
      widget.backend.addListener(_onBackend);
    }
    if (oldWidget.roomId != widget.roomId) {
      _ids = const [];
      forgetFetched(const []);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.backend.removeListener(_onBackend);
    _owner.release();
    super.dispose();
  }

  void _onBackend() => markNeedsRebuild(_sync);

  void _sync() {
    final ids = _owner.isCurrent
        ? widget.features.pinnedEventIds(widget.roomId)
        : const <String>[];
    if (!listEquals(ids, _ids)) {
      final grew = ids.length > _ids.length;
      _ids = ids;
      forgetFetched(ids);
      if (ids.isEmpty) {
        _index = -1;
      } else if (grew || _index < 0 || _index >= ids.length) {
        // Element X starts at (and jumps to) the most recent pin.
        _index = ids.length - 1;
      }
    }
    if (_index >= 0) ensureLoaded(_ids[_index]);
  }

  Future<void> _openCurrent() async {
    if (_ids.isEmpty || _index < 0) return;
    final id = _ids[_index];
    final entry = entryFor(id);
    setState(() {
      // Element X moves to the previous (older) pin after each tap.
      _index = (_index - 1) % _ids.length;
      ensureLoaded(_ids[_index]);
    });
    if (entry == null) {
      if (hasFailed(id)) retry(id);
      return;
    }
    await showPinnedMessagePreview(
      context,
      backend: widget.backend,
      features: widget.features,
      roomId: widget.roomId,
      entry: entry,
      palette: widget.palette,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ids.isEmpty || _index < 0 || !_owner.isCurrent) {
      return const SizedBox.shrink();
    }
    final p = widget.palette;
    final id = _ids[_index];
    final entry = entryFor(id);
    final count = _ids.length;
    final preview = entry != null
        ? messagePreviewText(entry)
        : isMissing(id)
        ? 'Message not available'
        : hasFailed(id)
        ? 'Couldn’t load this message. Tap to retry.'
        : 'Loading message…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Material(
        color: p.surface.withValues(alpha: 0.94),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.stroke),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('pinned-banner'),
          onTap: _openCurrent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 58),
            child: Row(
              children: [
                const SizedBox(width: 12),
                _PinIndicator(index: _index, count: count, palette: p),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.push_pin_rounded, size: 18, color: p.muted),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          count > 1
                              ? 'Pinned message · ${_index + 1} of $count'
                              : 'Pinned message',
                          style: TextStyle(
                            color: p.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry == null
                              ? preview
                              : '${entry.senderLabel}: $preview',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.foreground, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => openPinnedMessagesScreen(
                    context,
                    backend: widget.backend,
                    features: widget.features,
                    roomId: widget.roomId,
                    palette: p,
                  ),
                  child: const Text('View all'),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Vertical segments, as in Element X: up to three visible at a time.
class _PinIndicator extends StatelessWidget {
  const _PinIndicator({
    required this.index,
    required this.count,
    required this.palette,
  });

  final int index;
  final int count;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final segments = count <= 3 ? count : 3;
    final page = count <= 3 ? 0 : index ~/ 3;
    final shown = count <= 3 ? count : (count - page * 3).clamp(1, 3);
    final active = count <= 3 ? index : index % 3;
    final height = switch (segments) {
      1 => 32.0,
      2 => 15.0,
      _ => 10.0,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments; i++)
          Container(
            width: 2.5,
            height: height,
            margin: const EdgeInsets.symmetric(vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: i >= shown
                  ? Colors.transparent
                  : i == active
                  ? palette.accent
                  : palette.stroke,
            ),
          ),
      ],
    );
  }
}

Future<void> openPinnedMessagesScreen(
  BuildContext context, {
  required ChatBackend backend,
  required MessageActionFeatures features,
  required String roomId,
  required AppPalette palette,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => PinnedMessagesScreen(
      backend: backend,
      features: features,
      roomId: roomId,
      palette: palette,
    ),
  ),
);

/// Bottom-sheet view of one pinned message (Parallax cannot yet scroll the
/// timeline to an arbitrary event, so this stands in for "jump to message").
Future<void> showPinnedMessagePreview(
  BuildContext context, {
  required ChatBackend backend,
  required MessageActionFeatures features,
  required String roomId,
  required ChatEntry entry,
  required AppPalette palette,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.surface,
    builder: (sheetContext) {
      final canPin = features.permissions(roomId).canPin;
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Eyebrow('Pinned message', palette: palette),
                const SizedBox(height: 10),
                _PinnedCardContent(
                  entry: entry,
                  palette: palette,
                  maxLines: 30,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.pop(sheetContext, 'all'),
                      icon: const Icon(Icons.list_rounded),
                      label: const Text('View all'),
                    ),
                    if (canForward(entry))
                      TextButton.icon(
                        onPressed: () => Navigator.pop(sheetContext, 'forward'),
                        icon: const Icon(Icons.forward_rounded),
                        label: const Text('Forward'),
                      ),
                    if (canPin)
                      TextButton.icon(
                        onPressed: () => Navigator.pop(sheetContext, 'unpin'),
                        icon: const Icon(Icons.push_pin_outlined),
                        label: const Text('Unpin'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case 'all':
      await openPinnedMessagesScreen(
        context,
        backend: backend,
        features: features,
        roomId: roomId,
        palette: palette,
      );
    case 'forward':
      await openForwardScreen(
        context,
        backend: backend,
        features: features,
        palette: palette,
        entry: entry,
      );
    case 'unpin':
      await setMessagePinned(
        context,
        features: features,
        roomId: roomId,
        eventId: entry.id,
        pinned: false,
      );
  }
}

class _PinnedCardContent extends StatelessWidget {
  const _PinnedCardContent({
    required this.entry,
    required this.palette,
    this.maxLines = 6,
  });

  final ChatEntry entry;
  final AppPalette palette;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final time = entry.time.toLocal();
    final localisations = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            InitialAvatar(name: entry.senderLabel, palette: p, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.senderLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${localisations.formatShortDate(time)} '
              '${localisations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          entry.kind == EntryKind.text ||
                  entry.kind == EntryKind.notice ||
                  entry.kind == EntryKind.emote
              ? entry.body
              : messagePreviewText(entry),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.foreground, height: 1.35),
        ),
      ],
    );
  }
}

/// Element X pinned messages list, reached from the banner and room details.
class PinnedMessagesScreen extends StatefulWidget {
  const PinnedMessagesScreen({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.palette,
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final String roomId;
  final AppPalette palette;

  @override
  State<PinnedMessagesScreen> createState() => _PinnedMessagesScreenState();
}

class _PinnedMessagesScreenState extends State<PinnedMessagesScreen>
    with _PinnedEntryResolver<PinnedMessagesScreen> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  List<String> _ids = const [];
  final _busy = <String>{};

  @override
  ChatBackend get backend => widget.backend;
  @override
  MessageActionFeatures get features => widget.features;
  @override
  String get roomId => widget.roomId;

  @override
  void initState() {
    super.initState();
    _sync();
    widget.backend.addListener(_onBackend);
  }

  @override
  void dispose() {
    widget.backend.removeListener(_onBackend);
    _owner.release();
    super.dispose();
  }

  void _onBackend() => markNeedsRebuild(_sync);

  void _sync() {
    final ids = _owner.isCurrent
        ? widget.features.pinnedEventIds(widget.roomId)
        : const <String>[];
    if (!listEquals(ids, _ids)) {
      _ids = ids;
      forgetFetched(ids);
    }
    ids.forEach(ensureLoaded);
  }

  Future<void> _unpin(String id) async {
    if (!_busy.add(id)) return;
    setState(() {});
    await setMessagePinned(
      context,
      features: widget.features,
      roomId: widget.roomId,
      eventId: id,
      pinned: false,
    );
    if (mounted) setState(() => _busy.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final expired = !_owner.isCurrent;
    final count = _ids.length;
    final canPin =
        !expired && widget.features.permissions(widget.roomId).canPin;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 20, 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        count == 0
                            ? 'Pinned messages'
                            : count == 1
                            ? '1 Pinned message'
                            : '$count Pinned messages',
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                          fontSize: 23,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: expired
                    ? Center(
                        child: Text(
                          'Account changed. Reopen this room.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : count == 0
                    ? _empty(p)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                        // Newest pin first.
                        itemCount: count,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) =>
                            _item(_ids[count - 1 - index], p, canPin),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(AppPalette p) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.push_pin_outlined, size: 40, color: p.secondary),
          const SizedBox(height: 14),
          Text(
            'Pin important messages so that they can be easily discovered',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.foreground,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Press on a message and choose “Pin” to include here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted),
          ),
        ],
      ),
    ),
  );

  Widget _item(String id, AppPalette p, bool canPin) {
    final entry = entryFor(id);
    final busy = _busy.contains(id);
    return Container(
      key: ValueKey('pinned-item-$id'),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.stroke),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: entry == null
            ? (hasFailed(id) ? () => setState(() => retry(id)) : null)
            : () => showPinnedMessagePreview(
                context,
                backend: widget.backend,
                features: widget.features,
                roomId: widget.roomId,
                entry: entry,
                palette: p,
              ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: entry != null
                    ? _PinnedCardContent(entry: entry, palette: p)
                    : Text(
                        isMissing(id)
                            ? 'Message not available'
                            : hasFailed(id)
                            ? 'Couldn’t load this message. Tap to retry.'
                            : 'Loading message…',
                        style: TextStyle(color: p.muted),
                      ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else if (canPin || (entry != null && canForward(entry)))
                PopupMenuButton<String>(
                  tooltip: 'Pinned message options',
                  onSelected: (value) {
                    if (value == 'unpin') {
                      _unpin(id);
                    } else if (value == 'forward' && entry != null) {
                      openForwardScreen(
                        context,
                        backend: widget.backend,
                        features: widget.features,
                        palette: p,
                        entry: entry,
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    if (entry != null && canForward(entry))
                      const PopupMenuItem(
                        value: 'forward',
                        child: Text('Forward'),
                      ),
                    if (canPin)
                      const PopupMenuItem(value: 'unpin', child: Text('Unpin')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Room details row: "Pinned messages" with a live count.
class PinnedMessagesDetailsTile extends StatelessWidget {
  const PinnedMessagesDetailsTile({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.palette,
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final String roomId;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: backend,
    builder: (context, _) {
      final count = features.pinnedEventIds(roomId).length;
      return ListTile(
        key: const ValueKey('room-details-pinned'),
        leading: Icon(Icons.push_pin_outlined, color: palette.secondary),
        title: const Text('Pinned messages'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (count > 0)
              Text('$count', style: TextStyle(color: palette.muted)),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
        onTap: () => openPinnedMessagesScreen(
          context,
          backend: backend,
          features: features,
          roomId: roomId,
          palette: palette,
        ),
      );
    },
  );
}
