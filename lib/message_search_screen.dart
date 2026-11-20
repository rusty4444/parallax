import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'features/threads/local_message_search.dart';
import 'features/threads/message_index_store.dart';
import 'features/threads/message_search_settings.dart';
import 'features/threads/thread_widgets.dart';
import 'features/threads/timeline_navigation.dart';
import 'widgets.dart';

/// Message search across joined rooms.
///
/// Unencrypted rooms are searched on the homeserver. With "Search this
/// device's history" on (Element X's Message search, default on), encrypted
/// rooms are searched in a local index of decrypted messages. Results open
/// the room at the matching message where the backend supports it; the route
/// pops with the room ID for the caller to open.
class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.initialQuery = '',
  });
  final ChatBackend backend;
  final AppPalette palette;

  /// Pre-filled query (from the home search bar); searched on open when it
  /// is at least two characters.
  final String initialQuery;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _queryController = TextEditingController();
  late BackendSessionOwner _owner;
  LocalMessageSearch? _local;
  bool _deviceSearch = false;
  int _localSetup = 0;
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  String? _nextBatch;
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _expired = false;
  List<MessageHit> _hits = const [];
  List<LocalMessageHit> _localHits = const [];
  int? _localNext;
  String? _localError;
  bool _localLoading = false;
  bool _localLoadingMore = false;
  String? _opening;

  @override
  void initState() {
    super.initState();
    _bind();
    final initial = widget.initialQuery.trim();
    if (initial.length >= 2) {
      _queryController.text = widget.initialQuery;
      _onChanged(widget.initialQuery);
    }
  }

  void _bind() {
    _owner = BackendSessionOwner(widget.backend);
    widget.backend.addListener(_accountChanged);
    _local = localMessageSearchOf(widget.backend);
    _deviceSearch = false;
    final local = _local;
    if (local != null) {
      try {
        local.ensureStarted();
      } catch (_) {}
      unawaited(_loadDeviceSearch(local));
    }
  }

  Future<void> _loadDeviceSearch(LocalMessageSearch local) async {
    final setup = ++_localSetup;
    bool enabled;
    try {
      enabled = await local.isEnabled();
    } catch (_) {
      enabled = false;
    }
    if (!mounted ||
        setup != _localSetup ||
        !identical(local, _local) ||
        _expired ||
        !_owner.isCurrent) {
      return;
    }
    if (enabled == _deviceSearch) return;
    setState(() => _deviceSearch = enabled);
    _rerun();
  }

  /// Repeats the current query (after the search mode changed).
  void _rerun() {
    if (_query.length >= 2) _onChanged(_queryController.text);
  }

  bool _current(int generation) =>
      mounted && generation == _generation && _owner.isCurrent;

  void _resetSearch() {
    _generation++;
    _debounce?.cancel();
    _queryController.clear();
    _query = '';
    _hits = const [];
    _nextBatch = null;
    _loading = false;
    _loadingMore = false;
    _error = null;
    _localHits = const [];
    _localNext = null;
    _localError = null;
    _localLoading = false;
    _localLoadingMore = false;
    _opening = null;
  }

  void _accountChanged() {
    if (_expired || _owner.isCurrent) return;
    setState(() {
      _resetSearch();
      _expired = true;
    });
  }

  @override
  void didUpdateWidget(covariant MessageSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend) return;
    oldWidget.backend.removeListener(_accountChanged);
    _owner.release();
    _localSetup++;
    _resetSearch();
    _expired = false;
    _bind();
  }

  @override
  void dispose() {
    _generation++;
    _localSetup++;
    _debounce?.cancel();
    widget.backend.removeListener(_accountChanged);
    _owner.release();
    _queryController.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    if (_expired || !_owner.isCurrent) return;
    final query = text.trim();
    final generation = ++_generation;
    _debounce?.cancel();
    final device = _deviceSearch && _local != null;
    setState(() {
      _query = query;
      _hits = const [];
      _nextBatch = null;
      _loading = query.length >= 2;
      // A retired page does not own the new query's pagination guard.
      _loadingMore = false;
      _error = null;
      _localHits = const [];
      _localNext = null;
      _localError = null;
      _localLoading = device && query.length >= 2;
      _localLoadingMore = false;
      _opening = null;
    });
    if (query.length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_search(query, generation));
      final local = _local;
      if (device && local != null) {
        unawaited(_searchLocal(local, query, generation));
      }
    });
  }

  Future<void> _search(String query, int generation) async {
    if (!_current(generation)) return;
    try {
      final page = await widget.backend.searchMessages(query);
      if (!_current(generation)) return;
      setState(() {
        _hits = page.hits;
        _nextBatch = page.nextBatch;
        _loading = false;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() {
          _loading = false;
          _error = 'Couldn’t search messages on this server.';
        });
      }
    }
  }

  Future<void> _searchLocal(
    LocalMessageSearch local,
    String query,
    int generation,
  ) async {
    if (!_current(generation)) return;
    try {
      final page = await local.search(query);
      if (!_current(generation)) return;
      setState(() {
        _localHits = page.hits;
        _localNext = page.nextOffset;
        _localLoading = false;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() {
          _localLoading = false;
          _localError = 'Couldn’t search this device’s history.';
        });
      }
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    if (token == null || _loading || _loadingMore || !_owner.isCurrent) return;
    final generation = _generation;
    final query = _query;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.backend.searchMessages(query, nextBatch: token);
      if (!_current(generation)) return;
      setState(() {
        final known = _hits.map((hit) => hit.id).toSet();
        _hits = [
          ..._hits,
          for (final hit in page.hits)
            if (known.add(hit.id)) hit,
        ];
        _nextBatch = page.nextBatch;
      });
    } catch (_) {
      if (mounted && _current(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load more matches.')),
        );
      }
    } finally {
      if (_current(generation)) setState(() => _loadingMore = false);
    }
  }

  Future<void> _moreLocal() async {
    final local = _local;
    final offset = _localNext;
    if (local == null ||
        offset == null ||
        _localLoading ||
        _localLoadingMore ||
        !_owner.isCurrent) {
      return;
    }
    final generation = _generation;
    final query = _query;
    setState(() => _localLoadingMore = true);
    try {
      final page = await local.search(query, offset: offset);
      if (!_current(generation)) return;
      setState(() {
        final known = _localHits.map((hit) => hit.id).toSet();
        _localHits = [
          ..._localHits,
          for (final hit in page.hits)
            if (known.add(hit.id)) hit,
        ];
        _localNext = page.nextOffset;
      });
    } catch (_) {
      if (mounted && _current(generation)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load more matches.')),
        );
      }
    } finally {
      if (_current(generation)) setState(() => _localLoadingMore = false);
    }
  }

  Future<void> _setDeviceSearch(bool enabled) async {
    final local = _local;
    if (local == null || _expired || !_owner.isCurrent) return;
    if (!enabled && !await confirmDeviceSearchOff(context)) return;
    final setup = ++_localSetup;
    try {
      await local.setEnabled(enabled);
    } catch (_) {
      if (mounted && setup == _localSetup) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t change device search.')),
        );
      }
      return;
    }
    if (!mounted || setup != _localSetup || !_owner.isCurrent) return;
    setState(() => _deviceSearch = enabled);
    _rerun();
  }

  Future<void> _showDeviceSettings() async {
    final local = _local;
    if (local == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: DeviceSearchSettingsCard(
            search: local,
            palette: widget.palette,
          ),
        ),
      ),
    );
    if (mounted && identical(local, _local)) {
      unawaited(_loadDeviceSearch(local));
    }
  }

  /// Opens a result: focuses the room on the event when possible, then pops
  /// with the room ID so the caller opens the room screen.
  Future<void> _open(
    int generation,
    MessageHit hit, {
    required String jumpEventId,
  }) async {
    if (!_current(generation) || _opening != null) return;
    final navigation = timelineNavigationOf(widget.backend);
    if (navigation == null || !jumpEventId.startsWith(r'$')) {
      Navigator.pop(context, hit.roomId);
      return;
    }
    setState(() => _opening = hit.id);
    var focused = false;
    try {
      await navigation.openRoomAt(hit.roomId, jumpEventId);
      focused = true;
    } catch (_) {
      focused = false;
    }
    if (!mounted || !_current(generation)) return;
    setState(() => _opening = null);
    if (!focused) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn’t jump to that message. Opening the room instead.',
          ),
        ),
      );
    }
    Navigator.pop(context, hit.roomId);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final local = _local;
    final device = _deviceSearch && local != null;
    final canJump = timelineNavigationOf(widget.backend) != null;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          minimum: (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows)
              ? const EdgeInsets.only(top: kDesktopTitleBarHeight)
              : EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
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
                        'Find messages',
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                          fontSize: 23,
                        ),
                      ),
                    ),
                    if (local != null)
                      IconButton(
                        tooltip: 'Search settings',
                        onPressed: _expired ? null : _showDeviceSettings,
                        icon: Icon(Icons.tune_rounded, color: p.secondary),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow('Across joined rooms', palette: p),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _queryController,
                      enabled: !_expired,
                      onChanged: _onChanged,
                      decoration: const InputDecoration(
                        hintText: 'Search message text',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                    if (local != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          'Search this device’s history',
                          style: TextStyle(color: p.foreground),
                        ),
                        value: _deviceSearch,
                        onChanged: _expired ? null : _setDeviceSearch,
                      ),
                    const SizedBox(height: 4),
                    Text(
                      device
                          ? 'Encrypted rooms are searched on this device; other '
                                'rooms on your homeserver. '
                                '${canJump ? 'Matches open at the message.' : ''}'
                          : 'Server search cannot index encrypted message text. '
                                '${canJump ? 'Matches open the room at the message.' : 'Matches open the room, not the historical event.'}',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: device ? _combined(p) : _serverOnly(p)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status(AppPalette p, String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: p.muted),
      ),
    ),
  );

  Widget _serverOnly(AppPalette p) {
    final generation = _generation;
    if (_expired) return _status(p, 'Account changed. Reopen message search.');
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }
    if (_error != null) return _status(p, _error!);
    if (_hits.isEmpty && _nextBatch == null) {
      return _status(
        p,
        _query.length < 2
            ? 'Type at least two characters to search.'
            : 'No matches in joined rooms.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 26),
      itemCount: _hits.length + (_nextBatch == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == _hits.length) return _serverMore();
        final hit = _hits[index];
        return _resultCard(p, generation, hit, jumpEventId: hit.id);
      },
    );
  }

  Widget _serverMore() => Center(
    child: TextButton(
      onPressed: _loadingMore ? null : _more,
      child: Text(_loadingMore ? 'Loading…' : 'Load more'),
    ),
  );

  Widget _combined(AppPalette p) {
    final generation = _generation;
    if (_expired) return _status(p, 'Account changed. Reopen message search.');
    if (_query.length < 2) {
      return _status(p, 'Type at least two characters to search.');
    }
    if (_loading && _localLoading) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }
    final localIds = {for (final hit in _localHits) hit.id};
    final serverHits = [
      for (final hit in _hits)
        if (!localIds.contains(hit.id)) hit,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 26),
      children: [
        _section(p, 'Encrypted rooms · this device'),
        if (_localLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          )
        else if (_localError != null)
          _inline(p, _localError!)
        else if (_localHits.isEmpty)
          _inline(p, 'No matches in this device’s history.')
        else
          for (final hit in _localHits)
            _resultCard(
              p,
              generation,
              hit,
              jumpEventId: hit.jumpEventId,
              inThread: hit.threadRootId != null,
            ),
        if (_localNext != null)
          Center(
            child: TextButton(
              onPressed: _localLoadingMore ? null : _moreLocal,
              child: Text(
                _localLoadingMore ? 'Loading…' : 'Load more from this device',
              ),
            ),
          ),
        const SizedBox(height: 10),
        _section(p, 'Other rooms · server'),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          )
        else if (_error != null)
          _inline(p, _error!)
        else if (serverHits.isEmpty && _nextBatch == null)
          _inline(p, 'No matches in joined rooms.')
        else
          for (final hit in serverHits)
            _resultCard(p, generation, hit, jumpEventId: hit.id),
        if (_nextBatch != null && !_loading) _serverMore(),
      ],
    );
  }

  /// [body] with every query word (case-insensitive) emphasised.
  TextSpan _highlighted(String body, TextStyle style, TextStyle match) {
    final lower = body.toLowerCase();
    final tokens = searchTokens(_query);
    // Lower-casing must keep offsets aligned for the ranges to be valid.
    if (tokens.isEmpty || lower.length != body.length) {
      return TextSpan(text: body, style: style);
    }
    final marked = List.filled(body.length, false);
    for (final token in tokens) {
      for (var at = lower.indexOf(token); at >= 0;) {
        marked.fillRange(at, at + token.length, true);
        at = lower.indexOf(token, at + token.length);
      }
    }
    final spans = <TextSpan>[];
    var start = 0;
    for (var i = 1; i <= body.length; i++) {
      if (i == body.length || marked[i] != marked[start]) {
        spans.add(
          TextSpan(
            text: body.substring(start, i),
            style: marked[start] ? match : null,
          ),
        );
        start = i;
      }
    }
    return TextSpan(style: style, children: spans);
  }

  Widget _section(AppPalette p, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
    child: Eyebrow(label, palette: p),
  );

  Widget _inline(AppPalette p, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
    child: Text(text, style: TextStyle(color: p.muted)),
  );

  Widget _resultCard(
    AppPalette p,
    int generation,
    MessageHit hit, {
    required String jumpEventId,
    bool inThread = false,
  }) {
    final opening = _opening == hit.id;
    return Card(
      key: ValueKey('hit-${hit.id}'),
      color: p.surface,
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(generation, hit, jumpEventId: jumpEventId),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hit.roomName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.secondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    activityLabel(context, hit.time),
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text.rich(
                _highlighted(
                  hit.body,
                  TextStyle(color: p.foreground, fontSize: 15),
                  TextStyle(color: p.accent, fontWeight: FontWeight.w700),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      opening ? 'Opening…' : hit.sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                  ),
                  if (inThread)
                    Text(
                      'In a thread',
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
