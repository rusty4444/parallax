import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_backend.dart';
import 'messaging_features.dart';

/// Pops the selected Matrix user ID; the caller decides whether to create a DM.
class UserDirectoryScreen extends StatefulWidget {
  const UserDirectoryScreen({super.key, required this.backend});
  final ChatBackend backend;

  @override
  State<UserDirectoryScreen> createState() => _UserDirectoryScreenState();
}

class _UserDirectoryScreenState extends State<UserDirectoryScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _loading = false;
  bool _expired = false;
  String? _error;
  List<DirectoryUser> _users = const [];
  String? _account;
  String? _userId;

  MessagingFeatures? get _features => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _account = _features?.accountKey;
    _userId = widget.backend.userId;
    widget.backend.addListener(_changed);
  }

  bool get _ownerCurrent =>
      !_expired &&
      _account == _features?.accountKey &&
      _userId == widget.backend.userId;
  bool _current(int generation) =>
      mounted && _ownerCurrent && generation == _generation;

  void _changed() {
    if (_ownerCurrent || _expired) return;
    _debounce?.cancel();
    _generation++;
    _query.clear();
    setState(() {
      _expired = true;
      _loading = false;
      _users = const [];
      _error = null;
    });
  }

  @override
  void didUpdateWidget(covariant UserDirectoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend == widget.backend) return;
    oldWidget.backend.removeListener(_changed);
    _generation++;
    _debounce?.cancel();
    _query.clear();
    _expired = false;
    _loading = false;
    _users = const [];
    _error = null;
    _bind();
  }

  void _queueSearch(String text, {bool immediate = false}) {
    if (!_ownerCurrent || _features == null) return;
    _debounce?.cancel();
    final generation = ++_generation;
    final term = text.trim();
    setState(() {
      _users = const [];
      _error = null;
      _loading = term.isNotEmpty;
    });
    if (term.isEmpty) return;
    if (immediate) {
      unawaited(_search(term, generation));
    } else {
      _debounce = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_search(term, generation)),
      );
    }
  }

  Future<void> _search(String term, int generation) async {
    if (!_current(generation)) return;
    try {
      final users = await _features!.searchUsers(term);
      if (!_current(generation)) return;
      setState(() => _users = users);
    } catch (_) {
      if (!_current(generation)) return;
      setState(() => _error = 'Couldn’t search the user directory. Try again.');
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    widget.backend.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Find people')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _query,
              autofocus: true,
              enabled: !_expired && _features != null,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Name or Matrix user ID',
                prefixIcon: Icon(Icons.person_search),
              ),
              onChanged: _queueSearch,
              onSubmitted: (text) => _queueSearch(text, immediate: true),
            ),
          ),
          Expanded(
            child: switch (true) {
              _ when _expired => const Center(
                child: Text('Account changed. Reopen the directory.'),
              ),
              _ when _features == null => const Center(
                child: Text('User search is unavailable for this account.'),
              ),
              _ when _loading => const Center(
                child: CircularProgressIndicator(),
              ),
              _ when _error != null => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: () =>
                          _queueSearch(_query.text, immediate: true),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
              _ when _users.isEmpty => Center(
                child: Text(
                  _query.text.trim().isEmpty
                      ? 'Search your server’s user directory.'
                      : 'No people found. Try a full Matrix user ID.',
                ),
              ),
              _ => ListView.builder(
                itemCount: _users.length,
                itemBuilder: (context, index) {
                  final user = _users[index];
                  final name = user.name?.trim();
                  return ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.person_outline),
                    ),
                    title: Text(name == null || name.isEmpty ? user.id : name),
                    subtitle: Text(user.id),
                    onTap: () {
                      if (_ownerCurrent) Navigator.pop(context, user.id);
                    },
                  );
                },
              ),
            },
          ),
        ],
      ),
    ),
  );
}
