import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../thread_screen.dart';
import 'thread_features.dart';
import 'thread_models.dart';
import 'thread_widgets.dart';

/// Opens the threads list of [roomId].
Future<void> openThreadsList(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required AppPalette palette,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        ThreadsListScreen(backend: backend, roomId: roomId, palette: palette),
  ),
);

/// Element X's threads list: thread roots in a room with reply counts, the
/// latest reply and an unread dot where known, filterable to threads the
/// user takes part in. Tapping a thread opens it.
class ThreadsListScreen extends StatefulWidget {
  const ThreadsListScreen({
    super.key,
    required this.backend,
    required this.roomId,
    required this.palette,
  });
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  @override
  State<ThreadsListScreen> createState() => _ThreadsListScreenState();
}

class _ThreadsListScreenState extends State<ThreadsListScreen> {
  late BackendSessionOwner _owner;
  StreamSubscription<String>? _activity;
  int _generation = 0;
  ThreadListFilter _filter = ThreadListFilter.all;
  List<ThreadSummary> _threads = const [];
  String? _nextBatch;
  String? _error;
  String? _pageError;
  bool _loading = false;
  bool _paging = false;
  bool _expired = false;
  bool _unsupported = false;

  ThreadFeatures? get _features => threadFeaturesOf(widget.backend);

  bool _current(int generation) =>
      mounted && !_expired && generation == _generation && _owner.isCurrent;

  @override
  void initState() {
    super.initState();
    _bind();
    unawaited(_refresh());
  }

  void _bind() {
    _owner = BackendSessionOwner(widget.backend);
    widget.backend.addListener(_accountChanged);
    try {
      _activity = _features
          ?.threadActivity(widget.roomId)
          .listen((_) => unawaited(_refresh(quiet: true)));
    } catch (_) {
      _activity = null;
    }
  }

  void _unbind(ChatBackend backend) {
    backend.removeListener(_accountChanged);
    unawaited(_activity?.cancel());
    _activity = null;
    _owner.release();
  }

  void _accountChanged() {
    if (_expired || _owner.isCurrent) return;
    _generation++;
    setState(() {
      _expired = true;
      _threads = const [];
      _nextBatch = _error = _pageError = null;
      _loading = _paging = false;
    });
  }

  @override
  void didUpdateWidget(covariant ThreadsListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend &&
        oldWidget.roomId == widget.roomId) {
      return;
    }
    _unbind(oldWidget.backend);
    _generation++;
    _expired = false;
    _threads = const [];
    _nextBatch = null;
    _bind();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _generation++;
    _unbind(widget.backend);
    super.dispose();
  }

  Future<void> _refresh({bool quiet = false}) async {
    final features = _features;
    if (!mounted || _expired || !_owner.isCurrent || features == null) return;
    if (quiet && (_loading || _paging)) return;
    final generation = ++_generation;
    final filter = _filter;
    setState(() {
      if (!quiet) {
        _loading = true;
        _threads = const [];
        _nextBatch = null;
      }
      _paging = false;
      _error = _pageError = null;
    });
    try {
      final page = await features.loadThreads(widget.roomId, filter: filter);
      if (!_current(generation)) return;
      setState(() {
        if (quiet && _threads.isNotEmpty) {
          // Keep already paged threads; fresh activity moves to the top.
          final fresh = {for (final thread in page.threads) thread.root.id};
          _threads = [
            ...page.threads,
            for (final thread in _threads)
              if (!fresh.contains(thread.root.id)) thread,
          ];
          _nextBatch ??= page.nextBatch;
        } else {
          _threads = page.threads;
          _nextBatch = page.nextBatch;
        }
        _unsupported = false;
      });
    } on ThreadListUnsupported {
      if (_current(generation)) setState(() => _unsupported = true);
    } catch (_) {
      if (_current(generation) && !quiet) {
        setState(() => _error = 'Couldn’t load threads. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final features = _features;
    final token = _nextBatch;
    if (features == null ||
        token == null ||
        _loading ||
        _paging ||
        _expired ||
        !_owner.isCurrent) {
      return;
    }
    final generation = _generation;
    final filter = _filter;
    setState(() {
      _paging = true;
      _pageError = null;
    });
    try {
      final page = await features.loadThreads(
        widget.roomId,
        filter: filter,
        nextBatch: token,
      );
      if (!_current(generation)) return;
      setState(() {
        final known = {for (final thread in _threads) thread.root.id};
        _threads = [
          ..._threads,
          for (final thread in page.threads)
            if (known.add(thread.root.id)) thread,
        ];
        _nextBatch = page.nextBatch == token ? null : page.nextBatch;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() => _pageError = 'Couldn’t load more threads.');
      }
    } finally {
      if (_current(generation)) setState(() => _paging = false);
    }
  }

  void _setFilter(ThreadListFilter filter) {
    if (filter == _filter || _expired) return;
    setState(() => _filter = filter);
    unawaited(_refresh());
  }

  Future<void> _open(ThreadSummary thread) async {
    if (!mounted || _expired || !_owner.isCurrent) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ThreadScreen(
          backend: widget.backend,
          roomId: widget.roomId,
          root: thread.root,
          palette: widget.palette,
        ),
      ),
    );
    if (mounted && !_expired && _owner.isCurrent) {
      unawaited(_refresh(quiet: true));
    }
  }

  String get _roomName {
    try {
      for (final room in widget.backend.rooms) {
        if (room.id == widget.roomId) return room.name;
      }
    } catch (_) {
      // Minimal backends may not project rooms.
    }
    return widget.roomId;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          // Full-screen threads-list route on a desktop window: clear the
          // shell's top-right caption buttons — the header's Refresh action
          // would otherwise sit directly under the close button.
          minimum: (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
              : EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Semantics(
                        header: true,
                        label: 'Threads in $_roomName',
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Threads',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 21,
                                ),
                              ),
                              Text(
                                _roomName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _expired || _features == null
                          ? null
                          : () => _refresh(),
                      icon: Icon(Icons.refresh_rounded, color: p.secondary),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                child: Row(
                  children: [
                    for (final (filter, label) in [
                      (ThreadListFilter.all, 'All threads'),
                      (ThreadListFilter.participated, 'My threads'),
                    ]) ...[
                      ChoiceChip(
                        label: Text(label),
                        selected: _filter == filter,
                        onSelected: _expired ? null : (_) => _setFilter(filter),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              Expanded(child: _body(p)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(AppPalette p, String text, {VoidCallback? retry}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: p.muted, height: 1.35),
          ),
          if (retry != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: retry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );

  Widget _body(AppPalette p) {
    if (_expired) return _message(p, 'Account changed. Reopen this room.');
    if (_features == null) {
      return _message(p, 'Threads are unavailable for this account.');
    }
    if (_unsupported) {
      return _message(
        p,
        'This homeserver doesn’t provide a threads list. '
        'Open a thread from its message in the room instead.',
      );
    }
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }
    if (_error != null) return _message(p, _error!, retry: _refresh);
    if (_threads.isEmpty) {
      return _message(
        p,
        _filter == ThreadListFilter.participated
            ? 'You haven’t taken part in any threads in this room yet.'
            : 'No threads in this room yet. Start one from any message.',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 300 &&
              _pageError == null &&
              _nextBatch != null &&
              !_paging) {
            // Never set state from inside a scroll/layout callback.
            scheduleMicrotask(() => unawaited(_more()));
          }
          return false;
        },
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 26),
          itemCount: _threads.length + (_nextBatch != null ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _threads.length) {
              return Center(
                child: _paging
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: CircularProgressIndicator(color: p.accent),
                      )
                    : TextButton(
                        onPressed: _more,
                        child: Text(_pageError ?? 'Load more threads'),
                      ),
              );
            }
            final thread = _threads[index];
            return ThreadListTile(
              key: ValueKey(thread.root.id),
              palette: p,
              root: thread.root,
              latest: thread.latest,
              replyCount: thread.replyCount,
              activity: thread.activity,
              unread: thread.unread,
              onTap: () => _open(thread),
            );
          },
        ),
      ),
    );
  }
}
