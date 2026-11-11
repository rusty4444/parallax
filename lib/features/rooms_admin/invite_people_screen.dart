import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../messaging_features.dart';
import 'admin_ui.dart';
import 'user_search.dart';

/// Element X "Invite people": multi-select from the user directory (or typed
/// Matrix IDs), then send one permission-checked invite per person. Pops the
/// number of invitations sent.
class InvitePeopleScreen extends StatefulWidget {
  const InvitePeopleScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.excluded = const {},
    this.skippable = false,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  /// Users already in the room (joined, invited or banned).
  final Set<String> excluded;

  /// Shown after creating a room: offers "Skip" instead of plain back.
  final bool skippable;

  @override
  State<InvitePeopleScreen> createState() => _InvitePeopleScreenState();
}

class _InvitePeopleScreenState extends State<InvitePeopleScreen>
    with UserSearchMixin {
  final _selected = <String, DirectoryUser>{};
  bool _sending = false;
  String? _error;

  @override
  ChatBackend get searchBackend => widget.backend;

  @override
  void initState() {
    super.initState();
    searchOwner; // Pin the session before any account change.
  }

  @override
  void dispose() {
    disposeSearch();
    super.dispose();
  }

  void _toggle(DirectoryUser user) {
    if (_sending || widget.excluded.contains(user.id)) return;
    setState(() {
      if (_selected.remove(user.id) == null) _selected[user.id] = user;
    });
  }

  Future<void> _invite() async {
    if (_sending || _selected.isEmpty || !searchOwner.isCurrent) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    var sent = 0;
    final failed = <String>[];
    for (final id in _selected.keys.toList()) {
      if (!mounted || !searchOwner.isCurrent) return;
      try {
        await widget.backend.inviteToRoom(widget.roomId, id);
        sent++;
        if (mounted) setState(() => _selected.remove(id));
      } catch (_) {
        failed.add(id);
      }
    }
    if (!mounted || !searchOwner.isCurrent) return;
    setState(() => _sending = false);
    if (failed.isEmpty) {
      Navigator.pop(context, sent);
    } else {
      setState(
        () => _error = failed.length == 1
            ? 'Couldn’t invite ${failed.single}. Check the ID and your '
                  'permissions, then try again.'
            : 'Couldn’t invite ${failed.length} people. Try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final candidates = searchCandidates;
    final term = searchController.text.trim();
    return AdminPage(
      palette: p,
      title: 'Invite people',
      busy: _sending || searching,
      onBack: widget.skippable ? () => Navigator.pop(context, 0) : null,
      actions: [
        if (widget.skippable)
          TextButton(
            onPressed: _sending ? null : () => Navigator.pop(context, 0),
            child: const Text('Skip'),
          ),
        FilledButton(
          onPressed: _selected.isEmpty || _sending ? null : _invite,
          child: Text(
            _selected.isEmpty ? 'Invite' : 'Invite (${_selected.length})',
          ),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserSearchField(
            controller: searchController,
            autofocus: true,
            enabled: !_sending,
            onChanged: (text) => queueSearch(text),
            onSubmitted: (text) => queueSearch(text, immediate: true),
          ),
          if (_selected.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final user in _selected.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        label: Text(user.name ?? user.id),
                        onDeleted: _sending ? null : () => _toggle(user),
                        deleteButtonTooltipMessage: 'Remove ${user.id}',
                      ),
                    ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(_error!, style: TextStyle(color: p.foreground)),
            ),
          if (_sending)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'Preparing invitations… Don’t close the app until finished.',
                style: TextStyle(color: p.muted),
              ),
            ),
          Expanded(
            child: candidates.isEmpty
                ? AdminPlaceholder(
                    palette: p,
                    icon: Icons.person_search_outlined,
                    title:
                        searchError ??
                        (term.isEmpty
                            ? 'Search for people to invite'
                            : searching
                            ? 'Searching…'
                            : 'No people found'),
                    message: term.isEmpty || searching
                        ? (directorySearchAvailable
                              ? null
                              : 'Enter a full Matrix ID, like @alex:example.org.')
                        : 'Try a full Matrix ID, like @alex:example.org.',
                    onRetry: searchError == null
                        ? null
                        : () => queueSearch(term, immediate: true),
                  )
                : ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final user = candidates[index];
                      final member = widget.excluded.contains(user.id);
                      return UserResultTile(
                        backend: widget.backend,
                        palette: p,
                        user: user,
                        subtitle: member ? 'Already a member' : null,
                        onTap: member ? null : () => _toggle(user),
                        trailing: Checkbox(
                          value: member || _selected.containsKey(user.id),
                          onChanged: member || _sending
                              ? null
                              : (_) => _toggle(user),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
