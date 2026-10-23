import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'feature_settings_scope.dart';
import 'widgets.dart';

class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({
    super.key,
    required this.backend,
    required this.palette,
  });
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _queryController = TextEditingController();
  late BackendSessionOwner _owner;
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  String? _nextBatch;
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _expired = false;
  List<MessageHit> _hits = const [];

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _owner = BackendSessionOwner(widget.backend);
    widget.backend.addListener(_accountChanged);
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
    _resetSearch();
    _expired = false;
    _bind();
  }

  @override
  void dispose() {
    _generation++;
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
    setState(() {
      _query = query;
      _hits = const [];
      _nextBatch = null;
      _loading = query.length >= 2;
      // A retired page does not own the new query's pagination guard.
      _loadingMore = false;
      _error = null;
    });
    if (query.length < 2) return;
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(query, generation),
    );
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

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final generation = _generation;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
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
                        'Find messages',
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
                    const SizedBox(height: 9),
                    Text(
                      'Server search cannot index encrypted message text. '
                      'Matches open the room, not the historical event.',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _expired
                    ? Center(
                        child: Text(
                          'Account changed. Reopen message search.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : _loading
                    ? Center(child: CircularProgressIndicator(color: p.accent))
                    : _error != null
                    ? Center(
                        child: Text(_error!, style: TextStyle(color: p.muted)),
                      )
                    : _hits.isEmpty && _nextBatch == null
                    ? Center(
                        child: Text(
                          _query.length < 2
                              ? 'Type at least two characters to search.'
                              : 'No matches in joined rooms.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 26),
                        itemCount: _hits.length + (_nextBatch == null ? 0 : 1),
                        itemBuilder: (context, index) {
                          if (index == _hits.length) {
                            return Center(
                              child: TextButton(
                                onPressed: _loadingMore ? null : _more,
                                child: Text(
                                  _loadingMore ? 'Loading…' : 'Load more',
                                ),
                              ),
                            );
                          }
                          final hit = _hits[index];
                          return Card(
                            color: p.surface,
                            margin: const EdgeInsets.only(bottom: 9),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                if (_current(generation)) {
                                  Navigator.pop(context, hit.roomId);
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      hit.roomName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.secondary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      hit.body,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.foreground,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    Text(
                                      hit.sender,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
