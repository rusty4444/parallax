import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
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
  Timer? _debounce;
  int _generation = 0;
  String _query = '';
  String? _nextBatch;
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  List<MessageHit> _hits = const [];

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _query = text.trim();
    final generation = ++_generation;
    _debounce?.cancel();
    if (_query.length < 2) {
      setState(() {
        _hits = const [];
        _nextBatch = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(_query, generation),
    );
  }

  Future<void> _search(String query, int generation) async {
    try {
      final page = await widget.backend.searchMessages(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _hits = page.hits;
        _nextBatch = page.nextBatch;
        _loading = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Couldn’t search messages on this server.';
        });
      }
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    if (token == null || _loadingMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.backend.searchMessages(
        _query,
        nextBatch: token,
      );
      if (!mounted || generation != _generation) return;
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
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load more matches.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
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
                child: _loading
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
                              onTap: () => Navigator.pop(context, hit.roomId),
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
