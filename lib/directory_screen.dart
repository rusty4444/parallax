import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'room_join_dialog.dart';
import 'widgets.dart';

class DirectoryScreen extends StatefulWidget {
  const DirectoryScreen({
    super.key,
    required this.backend,
    required this.palette,
  });
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  Timer? _debounce;
  int _generation = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _nextBatch;
  String? _error;
  String _query = '';
  String? _joining;
  List<PublicRoom> _rooms = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search('', ++_generation);
    });
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }

  void _queueSearch(String query) {
    _query = query.trim();
    final generation = ++_generation;
    _debounce?.cancel();
    setState(() {
      _loading = true;
      // Retire pagination immediately, even if the old request never settles.
      _loadingMore = false;
      _nextBatch = null;
      _error = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search(_query, generation),
    );
  }

  Future<void> _search(String query, int generation) async {
    try {
      final page = await widget.backend.searchPublicRooms(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _rooms = page.rooms;
        _nextBatch = page.nextBatch;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Couldn’t search this server’s public rooms.';
        });
      }
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    if (!mounted || _loading || token == null || _loadingMore) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.backend.searchPublicRooms(
        _query,
        nextBatch: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final known = _rooms.map((room) => room.id).toSet();
        _rooms = [
          ..._rooms,
          for (final room in page.rooms)
            if (known.add(room.id)) room,
        ];
        _nextBatch = page.nextBatch;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t load more rooms.')),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _join(PublicRoom room) async {
    if (_joining != null) return;
    setState(() => _joining = room.id);
    try {
      final backend = widget.backend;
      final user = backend.userId;
      final id = await showRoomJoin(context, backend, room.id);
      if (id != null &&
          mounted &&
          identical(backend, widget.backend) &&
          user == backend.userId) {
        Navigator.pop(context, id);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t join this room.')),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
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
                        'Explore rooms',
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
                    Eyebrow('Public room directory', palette: p),
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: false,
                      onChanged: _queueSearch,
                      decoration: const InputDecoration(
                        hintText: 'Search published rooms',
                        prefixIcon: Icon(Icons.travel_explore_rounded),
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      'Searches public rooms on your homeserver. Private '
                      'rooms and encrypted messages are not indexed here.',
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
                    : _rooms.isEmpty
                    ? Center(
                        child: Text(
                          'No public rooms found.',
                          style: TextStyle(color: p.muted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 26),
                        itemCount: _rooms.length + (_nextBatch == null ? 0 : 1),
                        itemBuilder: (context, index) {
                          if (index == _rooms.length) {
                            return Center(
                              child: TextButton(
                                onPressed: _loadingMore ? null : _more,
                                child: Text(
                                  _loadingMore ? 'Loading…' : 'Load more',
                                ),
                              ),
                            );
                          }
                          final room = _rooms[index];
                          return Card(
                            color: p.surface,
                            margin: const EdgeInsets.only(bottom: 9),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  InitialAvatar(
                                    name: room.name,
                                    palette: p,
                                    size: 44,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          room.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: p.foreground,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${room.members} members',
                                          style: TextStyle(
                                            color: p.secondary,
                                            fontSize: 11,
                                          ),
                                        ),
                                        if (room.topic case final topic?)
                                          Text(
                                            topic,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: p.muted,
                                              fontSize: 12,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton.filledTonal(
                                    tooltip: 'Join ${room.name}',
                                    onPressed: _joining == null
                                        ? () => _join(room)
                                        : null,
                                    icon: _joining == room.id
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.arrow_forward_rounded,
                                          ),
                                  ),
                                ],
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
