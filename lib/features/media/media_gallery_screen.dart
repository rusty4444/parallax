import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../attachment_picker.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'media_actions.dart';
import 'media_bubbles.dart';
import 'media_content.dart';
import 'media_features.dart';
import 'media_viewer_pager.dart';

/// Element X "Media and files": images and videos in a grid, and documents,
/// audio and voice messages in a list, newest first, paginated from the
/// server so items older than the loaded timeline appear too.
class MediaGalleryScreen extends StatefulWidget {
  const MediaGalleryScreen({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.palette,
  });

  final ChatBackend backend;
  final MediaFeatures features;
  final String roomId;
  final AppPalette palette;

  @override
  State<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends State<MediaGalleryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_tabChanged);
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  final _items = <ChatEntry>[];
  final _seen = <String>{};
  final _loaders = <String, Future<DownloadedAttachment> Function()>{};
  String? _nextBatch;
  bool _exhausted = false;
  bool _loading = false;
  bool _failed = false;
  int _generation = 0;

  /// Automatic follow-up pages since the last user action. Bounds history
  /// requests in rooms that contain few or no media events.
  int _autoPages = 0;

  List<ChatEntry> get _media => [
    for (final item in _items)
      if (isVisualMediaKind(item.kind)) item,
  ];
  List<ChatEntry> get _files => [
    for (final item in _items)
      if (isFileMediaKind(item.kind)) item,
  ];

  @override
  void initState() {
    super.initState();
    // setState is not allowed during initState; start after this frame task.
    scheduleMicrotask(() {
      if (mounted) unawaited(_loadMore());
    });
  }

  @override
  void dispose() {
    _generation++;
    _tabs.dispose();
    _owner.release();
    super.dispose();
  }

  void _tabChanged() {
    if (_tabs.indexIsChanging) return;
    _autoPages = 0;
    _fillCurrentTab();
  }

  /// Keeps paginating (a bounded number of pages) until the visible tab has
  /// something to show or history is exhausted; then "Load more" takes over.
  void _fillCurrentTab() {
    final visible = _tabs.index == 0 ? _media : _files;
    if (!_loading &&
        !_exhausted &&
        !_failed &&
        visible.length < 18 &&
        _autoPages < 3) {
      _autoPages++;
      unawaited(_loadMore());
    }
  }

  void _userLoadMore() {
    _autoPages = 0;
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    if (_loading || _exhausted || !_owner.isCurrent) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.features.loadMediaHistory(
        widget.roomId,
        from: _nextBatch,
      );
      if (!mounted || generation != _generation || !_owner.isCurrent) return;
      setState(() {
        for (final item in page.items) {
          if (_seen.add(item.id)) _items.add(item);
        }
        _nextBatch = page.nextBatch;
        _exhausted = page.nextBatch == null;
        _loading = false;
      });
      _fillCurrentTab();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<DownloadedAttachment> Function() _loader(String eventId) =>
      _loaders.putIfAbsent(
        eventId,
        () =>
            () => widget.features.loadOriginal(widget.roomId, eventId),
      );

  Future<void> _open(ChatEntry entry, List<ChatEntry> group) async {
    if (!_owner.isCurrent) return;
    // The viewer pages oldest → newest; the gallery lists newest first.
    await openMediaViewer(
      context,
      backend: widget.backend,
      roomId: widget.roomId,
      eventId: entry.id,
      entries: group.reversed.toList(),
      loaderFor: _loader,
    );
  }

  Future<void> _actions(ChatEntry entry) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_full_rounded),
              title: const Text('Open'),
              onTap: () => Navigator.pop(sheetContext, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () => Navigator.pop(sheetContext, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('Save'),
              onTap: () => Navigator.pop(sheetContext, 'save'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('File info'),
              onTap: () => Navigator.pop(sheetContext, 'info'),
            ),
            if (entry.mine)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent || choice == null) return;
    switch (choice) {
      case 'open':
        await _open(entry, isVisualMediaKind(entry.kind) ? _media : [entry]);
      case 'share':
        await shareMedia(
          context,
          backend: widget.backend,
          loader: _loader(entry.id),
        );
      case 'save':
        await saveAttachment(
          context,
          widget.backend,
          widget.roomId,
          entry.id,
          loader: _loader(entry.id),
        );
      case 'info':
        await showMediaInfo(context, entry);
      case 'delete':
        if (!await confirmDeleteMedia(context) || !mounted) return;
        try {
          await widget.features.deleteMedia(widget.roomId, entry.id);
          if (!mounted || !_owner.isCurrent) return;
          setState(() => _items.removeWhere((item) => item.id == entry.id));
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Couldn’t delete this file.')),
            );
          }
        }
    }
  }

  Widget _status({required bool media, required bool empty}) {
    final p = widget.palette;
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              media ? 'Loading media…' : 'Loading files…',
              style: TextStyle(color: p.muted),
            ),
          ],
        ),
      );
    }
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              'Check your internet connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.foreground),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _userLoadMore, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (empty && _exhausted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(32, 64, 32, 24),
        child: Column(
          children: [
            Icon(
              media ? Icons.photo_library_outlined : Icons.folder_outlined,
              size: 48,
              color: p.secondary,
            ),
            const SizedBox(height: 14),
            Text(
              media ? 'No media uploaded yet' : 'No files uploaded yet',
              style: TextStyle(
                color: p.foreground,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              media
                  ? 'Images and videos uploaded to this room will be shown here.'
                  : 'Documents, audio files, and voice messages uploaded to '
                        'this room will be shown here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.muted),
            ),
          ],
        ),
      );
    }
    if (_exhausted) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          media ? 'No more media to show' : 'No more files to show',
          textAlign: TextAlign.center,
          style: TextStyle(color: p.muted),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: TextButton(
          onPressed: _loading ? null : _userLoadMore,
          child: const Text('Load more'),
        ),
      ),
    );
  }

  bool _nearEnd(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        notification.metrics.extentAfter < 400 &&
        !_loading &&
        !_exhausted &&
        !_failed) {
      _userLoadMore();
    }
    return false;
  }

  List<(String, List<ChatEntry>)> _byMonth(List<ChatEntry> items) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final groups = <(String, List<ChatEntry>)>[];
    for (final item in items) {
      final local = item.time.toLocal();
      final label = '${months[local.month - 1]} ${local.year}';
      if (groups.isEmpty || groups.last.$1 != label) {
        groups.add((label, []));
      }
      groups.last.$2.add(item);
    }
    return groups;
  }

  Widget _header(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Text(
      label.toUpperCase(),
      style: TextStyle(
        color: widget.palette.secondary,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 2,
      ),
    ),
  );

  Widget _mediaTab() {
    final media = _media;
    final autoLoad =
        FeatureSettingsScope.maybeOf(context)?.preferences.autoLoadMedia ??
        true;
    return NotificationListener<ScrollNotification>(
      onNotification: _nearEnd,
      child: CustomScrollView(
        slivers: [
          for (final (label, group) in _byMonth(media)) ...[
            SliverToBoxAdapter(child: _header(label)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: group.length,
                itemBuilder: (context, index) =>
                    _tile(group[index], media, autoLoad),
              ),
            ),
          ],
          SliverToBoxAdapter(child: _status(media: true, empty: media.isEmpty)),
        ],
      ),
    );
  }

  Widget _tile(ChatEntry entry, List<ChatEntry> media, bool autoLoad) {
    final info = MediaInfo.fromEntry(entry);
    final video = entry.kind == EntryKind.video;
    final p = widget.palette;
    return Semantics(
      button: true,
      label: '${video ? 'Video' : 'Image'}: ${info.name}',
      child: GestureDetector(
        onTap: () => unawaited(_open(entry, media)),
        onLongPress: () => unawaited(_actions(entry)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!video || info.hasThumbnail)
                MediaPreviewImage(
                  key: ValueKey(entry.id),
                  backend: widget.backend,
                  roomId: widget.roomId,
                  eventId: entry.id,
                  palette: p,
                  placeholderIcon: video
                      ? Icons.movie_outlined
                      : Icons.image_outlined,
                  enabled: autoLoad,
                )
              else
                ColoredBox(
                  color: p.raised,
                  child: Icon(Icons.movie_outlined, color: p.secondary),
                ),
              if (video)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_arrow_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                        if (info.duration != null)
                          Text(
                            formatMediaDuration(info.duration!),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filesTab() {
    final files = _files;
    final p = widget.palette;
    return NotificationListener<ScrollNotification>(
      onNotification: _nearEnd,
      child: CustomScrollView(
        slivers: [
          for (final (label, group) in _byMonth(files)) ...[
            SliverToBoxAdapter(child: _header(label)),
            SliverList.builder(
              itemCount: group.length,
              itemBuilder: (context, index) {
                final entry = group[index];
                final info = MediaInfo.fromEntry(entry);
                final voice = entry.kind == EntryKind.voice;
                final details = [
                  if (voice) 'Voice message',
                  if (info.duration != null)
                    formatMediaDuration(info.duration!),
                  if (info.size != null) formatFileSize(info.size!),
                  if (!voice) fileTypeLabel(info.name, info.mimeType),
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 3,
                  ),
                  child: Material(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(18),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: p.raised,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          voice
                              ? Icons.mic_rounded
                              : fileTypeIcon(info.name, info.mimeType),
                          color: p.secondary,
                        ),
                      ),
                      title: Text(
                        voice ? entry.senderLabel : info.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.foreground),
                      ),
                      subtitle: Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted),
                      ),
                      trailing: IconButton(
                        tooltip: 'More options for ${info.name}',
                        icon: const Icon(Icons.more_vert_rounded),
                        onPressed: () => unawaited(_actions(entry)),
                      ),
                      onTap: () => unawaited(_open(entry, [entry])),
                    ),
                  ),
                );
              },
            ),
          ],
          SliverToBoxAdapter(
            child: _status(media: false, empty: files.isEmpty),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'Media and files',
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              TabBar(
                controller: _tabs,
                labelColor: p.foreground,
                unselectedLabelColor: p.muted,
                indicatorColor: p.accent,
                tabs: const [
                  Tab(text: 'Media'),
                  Tab(text: 'Files'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [_mediaTab(), _filesTab()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
