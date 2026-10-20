import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'chat_backend.dart';
import 'directory_screen.dart';
import 'message_search_screen.dart';
import 'room_avatar.dart';
import 'room_screen.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.style,
    required this.onThemeChanged,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final VisualTheme style;
  final ValueChanged<VisualTheme> onThemeChanged;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  String _query = '';
  bool _unreadOnly = false;
  bool _invitesOnly = false;

  Future<void> _showInvitation(ChatRoom room) async {
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Join ${room.name}?'),
        content: const Text('You were invited to this Matrix room.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join room'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice) {
        await widget.backend.acceptInvite(room.id);
        if (mounted) _open(room.id);
      } else {
        await widget.backend.declineInvite(room.id);
      }
    } catch (_) {
      if (mounted) {
        _showError(
          choice
              ? 'Couldn’t join this room.'
              : 'Couldn’t decline this invitation.',
        );
      }
    }
  }

  Future<void> _newConversation() async {
    final controller = TextEditingController();
    try {
      final userId = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('New conversation'),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: '@someone:example.org',
              labelText: 'Matrix user ID',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Start chat'),
            ),
          ],
        ),
      );
      if (!mounted || userId == null || userId.isEmpty) return;
      if (!RegExp(r'^@[^:\s]+:[^:\s]+$').hasMatch(userId)) {
        _showError('Enter a full Matrix user ID, like @alex:example.org.');
        return;
      }
      await widget.backend.createDirectChat(userId);
      if (!mounted) return;
      final roomId = widget.backend.activeRoomId;
      if (roomId != null) _open(roomId);
    } catch (_) {
      if (mounted) _showError('Couldn’t start this conversation. Try again.');
    } finally {
      controller.dispose();
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  void _open(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RoomScreen(
        backend: widget.backend,
        palette: widget.palette,
        roomId: id,
      ),
    ),
  );

  Future<void> _explore() async {
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            DirectoryScreen(backend: widget.backend, palette: widget.palette),
      ),
    );
    if (mounted && roomId != null) _open(roomId);
  }

  Future<void> _searchMessages() async {
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => MessageSearchScreen(
          backend: widget.backend,
          palette: widget.palette,
        ),
      ),
    );
    if (mounted && roomId != null) _open(roomId);
  }

  String _time(DateTime? value) {
    if (value == null) return '';
    final now = DateTime.now();
    final local = value.toLocal();
    if (now.year == local.year &&
        now.month == local.month &&
        now.day == local.day) {
      return TimeOfDay.fromDateTime(local).format(context);
    }
    return '${local.day}/${local.month}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final rooms = widget.backend.rooms
            .where(
              (room) =>
                  (!_unreadOnly ||
                      room.invited ||
                      room.unread > 0 ||
                      room.manuallyUnread) &&
                  (!_invitesOnly || room.invited) &&
                  (room.name.toLowerCase().contains(_query.toLowerCase()) ||
                      room.id.toLowerCase().contains(_query.toLowerCase())),
            )
            .toList();
        return Scaffold(
          body: GlowBackdrop(
            palette: p,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 22, 16, 0),
                    child: Row(
                      children: [
                        BrandMark(palette: p, size: 46),
                        const SizedBox(width: 13),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'MatriXpress',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontSize: 23,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -1.1,
                                ),
                              ),
                              Text(
                                'YOUR SPACE TO CONNECT',
                                style: TextStyle(
                                  color: p.secondary,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.7,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Explore public rooms',
                          onPressed: _explore,
                          icon: const Icon(Icons.travel_explore_rounded),
                        ),
                        IconButton(
                          tooltip: 'Settings',
                          iconSize: 25,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SettingsScreen(
                                backend: widget.backend,
                                palette: p,
                                style: widget.style,
                                onThemeChanged: widget.onThemeChanged,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 30, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow('The good stuff', palette: p),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Messages',
                                style: TextStyle(
                                  fontSize: 37,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1.7,
                                  color: p.foreground,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: p.secondary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(40),
                              ),
                              child: Text(
                                '${widget.backend.rooms.length} ROOMS',
                                style: TextStyle(
                                  color: p.secondary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.8,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 19),
                        TextField(
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            hintText: 'Find a conversation',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: IconButton(
                              tooltip: 'Search messages',
                              onPressed: _searchMessages,
                              icon: const Icon(Icons.manage_search_rounded),
                            ),
                          ),
                        ),
                        const SizedBox(height: 17),
                        Row(
                          children: [
                            _FilterChip(
                              label: 'All chats',
                              selected: !_unreadOnly && !_invitesOnly,
                              palette: p,
                              onTap: () => setState(() {
                                _unreadOnly = false;
                                _invitesOnly = false;
                              }),
                            ),
                            const SizedBox(width: 9),
                            _FilterChip(
                              label: 'Unread',
                              selected: _unreadOnly,
                              palette: p,
                              onTap: () => setState(() {
                                _unreadOnly = true;
                                _invitesOnly = false;
                              }),
                            ),
                            const SizedBox(width: 9),
                            _FilterChip(
                              label: 'Invites',
                              selected: _invitesOnly,
                              palette: p,
                              onTap: () => setState(() {
                                _invitesOnly = true;
                                _unreadOnly = false;
                              }),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                      ],
                    ),
                  ),
                  Expanded(
                    child: rooms.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(35),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _query.isNotEmpty
                                        ? Icons.search_off_rounded
                                        : Icons.forum_outlined,
                                    size: 50,
                                    color: p.secondary,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    _query.isNotEmpty
                                        ? 'No matches yet'
                                        : _invitesOnly
                                        ? 'No invitations'
                                        : _unreadOnly
                                        ? 'All caught up'
                                        : 'A quiet start.',
                                    style: TextStyle(
                                      color: p.foreground,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _query.isNotEmpty
                                        ? 'Try another search.'
                                        : _invitesOnly
                                        ? 'Invitations will appear here.'
                                        : _unreadOnly
                                        ? 'No unread rooms right now.'
                                        : 'Your joined rooms will appear here. '
                                              'Start a conversation to break the silence.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: p.muted,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                            itemCount: rooms.length,
                            itemBuilder: (context, index) {
                              final room = rooms[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Material(
                                  color: p.surface,
                                  borderRadius: BorderRadius.circular(20),
                                  child: InkWell(
                                    onTap: room.invited
                                        ? () => _showInvitation(room)
                                        : () => _open(room.id),
                                    borderRadius: BorderRadius.circular(20),
                                    child: Padding(
                                      padding: const EdgeInsets.all(14),
                                      child: Row(
                                        children: [
                                          RoomAvatar(
                                            room: room,
                                            backend: widget.backend,
                                            palette: p,
                                          ),
                                          const SizedBox(width: 13),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        room.name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: p.foreground,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      _time(room.lastActivity),
                                                      style: TextStyle(
                                                        color: p.muted,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 5),
                                                Row(
                                                  children: [
                                                    if (room.encrypted) ...[
                                                      Icon(
                                                        Icons.lock_outline,
                                                        size: 13,
                                                        color: p.secondary,
                                                      ),
                                                      const SizedBox(width: 4),
                                                    ],
                                                    Expanded(
                                                      child: Text(
                                                        room.invited
                                                            ? 'Invited to join'
                                                            : room
                                                                  .preview
                                                                  .isEmpty
                                                            ? 'No messages yet'
                                                            : room.preview,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: p.muted,
                                                          fontSize: 13,
                                                        ),
                                                      ),
                                                    ),
                                                    if (room.invited) ...[
                                                      const SizedBox(width: 8),
                                                      Text(
                                                        'INVITE',
                                                        style: TextStyle(
                                                          color: p.secondary,
                                                          fontSize: 10,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                      ),
                                                    ] else if (room.unread >
                                                            0 ||
                                                        room.manuallyUnread) ...[
                                                      const SizedBox(width: 8),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 7,
                                                              vertical: 3,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: p.accent,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                11,
                                                              ),
                                                        ),
                                                        child: Text(
                                                          room.unread == 0
                                                              ? '•'
                                                              : room.unread > 99
                                                              ? '99+'
                                                              : '${room.unread}',
                                                          style: TextStyle(
                                                            color: p.accentOn,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
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
          floatingActionButton: FloatingActionButton.extended(
            tooltip: 'New conversation',
            onPressed: _newConversation,
            backgroundColor: p.accent,
            foregroundColor: p.accentOn,
            icon: const Icon(Icons.edit_rounded),
            label: const Text(
              'New chat',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ActionChip(
    onPressed: onTap,
    label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    backgroundColor: selected ? palette.accent : palette.surface,
    labelStyle: TextStyle(
      color: selected ? palette.accentOn : palette.foreground,
    ),
    side: BorderSide(color: selected ? palette.accent : palette.stroke),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}
