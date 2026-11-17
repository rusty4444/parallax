import 'dart:async';

import 'package:flutter/material.dart';

import '../../attachment_picker.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import '../../media_viewer.dart' show MediaViewer, shutdownMediaViewerPage;
import '../file_preview/document_page.dart';
import 'media_actions.dart';
import 'media_content.dart';

/// One page of the media viewer. [loader] must be a stable instance: the
/// viewer reloads when it changes.
@immutable
class MediaViewerItem {
  const MediaViewerItem({
    required this.eventId,
    required this.loader,
    this.entry,
  });
  final String eventId;
  final MediaLoader loader;

  /// Timeline/gallery metadata (sender, date, info), when known.
  final ChatEntry? entry;

  MediaInfo? get info => entry == null ? null : MediaInfo.fromEntry(entry!);

  /// Documents show their preview (text, Markdown, CSV, Word, Excel,
  /// PowerPoint) or a file card instead of a player.
  bool get isDocument {
    final entry = this.entry;
    if (entry == null || entry.kind != EntryKind.file) return false;
    final mime = info?.mimeType ?? '';
    return !(mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        mime.startsWith('audio/'));
  }
}

/// Builds swipeable viewer items. Images and videos in [entries] (oldest
/// first) are paged like Element X; any other kind opens on its own.
List<MediaViewerItem> mediaViewerItems(
  ChatBackend backend,
  String roomId,
  String eventId, {
  List<ChatEntry>? entries,
  MediaLoader Function(String eventId)? loaderFor,
}) {
  MediaLoader loader(String id) =>
      loaderFor?.call(id) ?? mediaLoaderFor(backend, roomId, id);
  var source = entries;
  if (source == null) {
    try {
      source = backend.activeRoomId == roomId ? backend.messages : const [];
    } catch (_) {
      source = const []; // Minimal backends may not expose a timeline.
    }
  }
  final target = source.where((entry) => entry.id == eventId).firstOrNull;
  if (target == null || target.redacted || !isVisualMediaKind(target.kind)) {
    return [
      MediaViewerItem(eventId: eventId, loader: loader(eventId), entry: target),
    ];
  }
  return [
    for (final entry in source)
      if (!entry.redacted && isVisualMediaKind(entry.kind))
        MediaViewerItem(
          eventId: entry.id,
          loader: loader(entry.id),
          entry: entry,
        ),
  ];
}

/// Opens the original-media viewer. With [entries] (or the active room's
/// loaded timeline) the user can swipe between the room's images and videos.
/// Completes after the route has closed and every page has joined its native
/// player disposal and deleted its private temporary file.
Future<void> openMediaViewer(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required String eventId,
  List<ChatEntry>? entries,
  MediaLoader Function(String eventId)? loaderFor,
}) async {
  final items = mediaViewerItems(
    backend,
    roomId,
    eventId,
    entries: entries,
    loaderFor: loaderFor,
  );
  final initial = items.indexWhere((item) => item.eventId == eventId);
  final key = GlobalKey<_MediaViewerPagerState>();
  final route = MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => MediaViewerPager(
      key: key,
      backend: backend,
      roomId: roomId,
      items: items,
      initialIndex: initial < 0 ? 0 : initial,
    ),
  );
  await Navigator.of(context).push<void>(route);
  // PopScope starts shutdown even during the reverse route animation. Retain
  // the join independently of State so late native/file work is still owned.
  final cleanup = key.currentState?._shutdown();
  await route.completed;
  await cleanup;
}

/// Swipeable viewer with Element X actions: share, save, info and delete.
class MediaViewerPager extends StatefulWidget {
  const MediaViewerPager({
    super.key,
    required this.backend,
    required this.roomId,
    required this.items,
    this.initialIndex = 0,
    this.fileFactory = createMediaTempFile,
    this.playerFactory = createNativeMediaPlayer,
    this.imageDecoder = decodeMediaImage,
  });

  final ChatBackend backend;
  final String roomId;
  final List<MediaViewerItem> items;
  final int initialIndex;
  final MediaFileFactory fileFactory;
  final MediaPlayerFactory playerFactory;
  final MediaImageDecoder imageDecoder;

  @override
  State<MediaViewerPager> createState() => _MediaViewerPagerState();
}

class _MediaViewerPagerState extends State<MediaViewerPager> {
  late final PageController _controller;
  late List<MediaViewerItem> _items = List.of(widget.items);
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  final _keys = <String, GlobalKey>{};
  final _cleanups = <Future<void>>[];
  late int _index;
  bool _zoomed = false;
  bool _ended = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
    widget.backend.addListener(_sessionChanged);
  }

  /// Logout or account change ends every page and disables all actions.
  void _sessionChanged() {
    if (_ended || _owner.isCurrent) return;
    _shutdown();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.backend.removeListener(_sessionChanged);
    _shutdown();
    _controller.dispose();
    _owner.release();
    super.dispose();
  }

  MediaViewerItem get _current => _items[_index];

  void _track(Future<void> cleanup) {
    _cleanups.add(cleanup.catchError((Object _) {}));
  }

  /// Stops every live page; completes when all started cleanups have joined.
  Future<void> _shutdown() {
    _ended = true;
    for (final key in _keys.values) {
      shutdownMediaViewerPage(key);
    }
    return Future.wait(List.of(_cleanups)).then((_) {});
  }

  void _close() {
    _shutdown();
    if (mounted) setState(() {});
    Navigator.of(context).maybePop();
  }

  Future<void> _run(Future<void> Function(MediaViewerItem item) action) async {
    if (_busy || _ended || !_owner.isCurrent) return;
    setState(() => _busy = true);
    try {
      await action(_current);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(MediaViewerItem item) async {
    if (!await confirmDeleteMedia(context) || !mounted || !_owner.isCurrent) {
      return;
    }
    try {
      await deleteMediaEvent(widget.backend, widget.roomId, item.eventId);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t delete this file.')),
        );
      }
      return;
    }
    if (!mounted || !_owner.isCurrent) return;
    final remaining = [
      for (final other in _items)
        if (other.eventId != item.eventId) other,
    ];
    final page = _keys.remove(item.eventId);
    if (page != null) shutdownMediaViewerPage(page);
    if (remaining.isEmpty) {
      _close();
      return;
    }
    setState(() {
      _items = remaining;
      _index = _index.clamp(0, remaining.length - 1);
      _zoomed = false;
    });
    if (_controller.hasClients) _controller.jumpToPage(_index);
  }

  Widget _page(MediaViewerItem item) {
    if (item.isDocument) {
      return DocumentPage(
        key: ValueKey('document-${item.eventId}'),
        backend: widget.backend,
        roomId: widget.roomId,
        eventId: item.eventId,
        loader: item.loader,
        info: item.info!,
        fallback: _DocumentPage(item: item),
      );
    }
    final key = _keys.putIfAbsent(item.eventId, GlobalKey.new);
    return MediaViewer(
      key: key,
      backend: widget.backend,
      roomId: widget.roomId,
      eventId: item.eventId,
      loader: item.loader,
      fileFactory: widget.fileFactory,
      playerFactory: widget.playerFactory,
      imageDecoder: widget.imageDecoder,
      embedded: true,
      onCleanup: _track,
      onZoomChanged: (zoomed) {
        if (mounted && zoomed != _zoomed) setState(() => _zoomed = zoomed);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = _current;
    final entry = item.entry;
    final info = item.info;
    final enabled = !_busy && !_ended && _owner.isCurrent;
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _shutdown();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close media',
            icon: const Icon(Icons.close),
            onPressed: _close,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                info?.name ?? 'Media',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (entry != null)
                Text(
                  _items.length > 1
                      ? '${entry.senderLabel} · ${_index + 1} of ${_items.length}'
                      : entry.senderLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.share_outlined),
              onPressed: enabled
                  ? () => _run(
                      (item) => shareMedia(
                        context,
                        backend: widget.backend,
                        loader: item.loader,
                      ),
                    )
                  : null,
            ),
            IconButton(
              tooltip: 'Save',
              icon: const Icon(Icons.download_rounded),
              onPressed: enabled
                  ? () => _run(
                      (item) => saveAttachment(
                        context,
                        widget.backend,
                        widget.roomId,
                        item.eventId,
                        loader: item.loader,
                      ),
                    )
                  : null,
            ),
            if (entry != null)
              IconButton(
                tooltip: 'File info',
                icon: const Icon(Icons.info_outline_rounded),
                onPressed: enabled ? () => showMediaInfo(context, entry) : null,
              ),
            if (entry?.mine ?? false)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: enabled ? () => _run(_delete) : null,
              ),
          ],
        ),
        body: SafeArea(
          child: _ended
              ? const Center(child: Text('This media session has ended.'))
              : PageView.builder(
                  controller: _controller,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: _items.length,
                  onPageChanged: (index) => setState(() {
                    _index = index;
                    _zoomed = false;
                  }),
                  itemBuilder: (_, index) => _page(_items[index]),
                ),
        ),
      ),
    );
  }
}

/// A document that cannot be previewed: type, size and save/share hints.
class _DocumentPage extends StatelessWidget {
  const _DocumentPage({required this.item});
  final MediaViewerItem item;

  @override
  Widget build(BuildContext context) {
    final info = item.info!;
    final details = [
      fileTypeLabel(info.name, info.mimeType),
      if (info.size != null) formatFileSize(info.size!),
    ].join(' · ');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(fileTypeIcon(info.name, info.mimeType), size: 72),
            const SizedBox(height: 18),
            Text(
              info.name,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(details),
            const SizedBox(height: 18),
            const Text(
              'This file can’t be previewed. Save or share it to open it in '
              'another app.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
