import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_backend.dart';
import 'messaging_features.dart';

class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.backend,
    required this.roomId,
    required this.root,
  });
  final ChatBackend backend;
  final String roomId;
  final ChatEntry root;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _draft = TextEditingController();
  int _generation = 0;
  int _sendGeneration = 0;
  int _draftRevision = 0;
  bool _loading = false;
  bool _paging = false;
  bool _sending = false;
  bool _expired = false;
  String? _account;
  String? _userId;
  String? _error;
  String? _sendError;
  String? _nextBatch;
  List<ChatEntry> _replies = const [];

  MessagingFeatures? get _features => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };
  bool get _ownerCurrent =>
      !_expired &&
      _account == _features?.accountKey &&
      _userId == widget.backend.userId;
  bool _current(int generation) =>
      mounted && _ownerCurrent && generation == _generation;

  @override
  void initState() {
    super.initState();
    _draft.addListener(_draftChanged);
    _bind();
    unawaited(_refresh());
  }

  void _bind() {
    _account = _features?.accountKey;
    _userId = widget.backend.userId;
    widget.backend.addListener(_changed);
  }

  void _draftChanged() {
    _draftRevision++;
  }

  void _changed() {
    if (_expired || _ownerCurrent) return;
    _generation++;
    _sendGeneration++;
    _draft.clear();
    setState(() {
      _expired = true;
      _loading = _paging = _sending = false;
      _replies = const [];
      _nextBatch = _error = _sendError = null;
    });
  }

  @override
  void didUpdateWidget(covariant ThreadScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend &&
        oldWidget.roomId == widget.roomId &&
        oldWidget.root.id == widget.root.id) {
      return;
    }
    oldWidget.backend.removeListener(_changed);
    _generation++;
    _sendGeneration++;
    _draft.clear();
    _expired = _sending = false;
    _sendError = null;
    _replies = const [];
    _bind();
    unawaited(_refresh());
  }

  List<ChatEntry> _merge(Iterable<ChatEntry> entries) {
    final byId = <String, ChatEntry>{};
    for (final entry in entries) {
      if (entry.id != widget.root.id) byId[entry.id] = entry;
    }
    return byId.values.toList()..sort((a, b) {
      final time = a.time.compareTo(b.time);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
  }

  Future<void> _refresh() async {
    if (!_ownerCurrent || _features == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _paging = false;
      _error = null;
      _nextBatch = null;
      _replies = const [];
    });
    try {
      final page = await _features!.loadThread(widget.roomId, widget.root.id);
      if (!_current(generation)) return;
      setState(() {
        _replies = _merge(page.messages);
        _nextBatch = page.nextBatch;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = 'Couldn’t load this thread. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final token = _nextBatch;
    if (!_ownerCurrent || _loading || _paging || token == null) return;
    final generation = _generation;
    setState(() {
      _paging = true;
      _error = null;
    });
    try {
      final page = await _features!.loadThread(
        widget.roomId,
        widget.root.id,
        nextBatch: token,
      );
      if (!_current(generation)) return;
      setState(() {
        // Keep already displayed entries on overlapping backwards pages.
        _replies = _merge([...page.messages, ..._replies]);
        _nextBatch = page.nextBatch == token ? null : page.nextBatch;
      });
    } catch (_) {
      if (_current(generation)) {
        setState(() => _error = 'Couldn’t load older replies. Try again.');
      }
    } finally {
      if (_current(generation)) setState(() => _paging = false);
    }
  }

  Future<void> _send() async {
    if (!_ownerCurrent || _sending || _features == null) return;
    final text = _draft.text;
    if (text.trim().isEmpty) return;
    final revision = _draftRevision;
    final generation = ++_sendGeneration;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await _features!.queueMessage(
        widget.roomId,
        text,
        threadRootId: widget.root.id,
      );
      if (!mounted || !_ownerCurrent || generation != _sendGeneration) return;
      if (_draftRevision == revision) _draft.clear();
      unawaited(_refresh());
    } catch (_) {
      if (mounted && _ownerCurrent && generation == _sendGeneration) {
        setState(
          () => _sendError =
              'Couldn’t send this reply. Your draft is kept; tap send to retry.',
        );
      }
    } finally {
      if (mounted && _ownerCurrent && generation == _sendGeneration) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _sendGeneration++;
    widget.backend.removeListener(_changed);
    _draft.removeListener(_draftChanged);
    _draft.dispose();
    super.dispose();
  }

  Widget _entry(ChatEntry entry, {bool root = false}) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.sender,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                MaterialLocalizations.of(
                  context,
                ).formatTimeOfDay(TimeOfDay.fromDateTime(entry.time.toLocal())),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          if (root)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Thread started here',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          const SizedBox(height: 6),
          SelectableText(
            entry.redacted
                ? 'Message removed'
                : entry.body.isNotEmpty
                ? entry.body
                : entry.isImage
                ? 'Image'
                : entry.isAttachment
                ? 'Attachment'
                : 'Message',
          ),
          if (entry.edited && !entry.redacted)
            const Text('Edited', style: TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Thread'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _expired || _features == null ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: _expired
          ? const Center(child: Text('Account changed. Reopen this thread.'))
          : _features == null
          ? const Center(
              child: Text('Threads are unavailable for this account.'),
            )
          : Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        _entry(widget.root, root: true),
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Replies'),
                        ),
                        if (_loading)
                          const Center(child: CircularProgressIndicator()),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                Text(_error!, textAlign: TextAlign.center),
                                TextButton(
                                  onPressed: _nextBatch == null
                                      ? _refresh
                                      : _more,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          ),
                        if (_nextBatch != null && !_paging && !_loading)
                          TextButton(
                            onPressed: _more,
                            child: const Text('Load older replies'),
                          ),
                        if (_paging)
                          const Center(child: CircularProgressIndicator()),
                        if (!_loading && _replies.isEmpty && _error == null)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'No replies yet. Start the conversation.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        for (final entry in _replies) _entry(entry),
                      ],
                    ),
                  ),
                ),
                if (_sendError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _sendError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _draft,
                          minLines: 1,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: 'Reply in thread',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Send reply',
                        onPressed: _sending ? null : _send,
                        icon: Icon(_sending ? Icons.hourglass_top : Icons.send),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
}
