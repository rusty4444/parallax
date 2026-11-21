import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../rooms_admin/decline_and_block.dart';
import 'message_requests.dart';

/// The dedicated message-requests inbox: invitations from unknown senders,
/// with avatars hidden until revealed and accept / decline / block actions.
class MessageRequestsScreen extends StatefulWidget {
  const MessageRequestsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.controller,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final MessageRequestsController controller;

  @override
  State<MessageRequestsScreen> createState() => _MessageRequestsScreenState();
}

class _MessageRequestsScreenState extends State<MessageRequestsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _revealed = <String>{};
  String? _busyRoom;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.backend.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _owner.release();
    super.dispose();
  }

  void _changed() {
    if (mounted && _owner.isCurrent) setState(() {});
  }

  Future<void> _accept(ChatRoom room) async {
    setState(() => _busyRoom = room.id);
    try {
      await widget.backend.acceptInvite(room.id);
    } catch (_) {
      if (mounted) _showError('Couldn’t accept the invitation.');
    } finally {
      if (mounted) setState(() => _busyRoom = null);
    }
  }

  Future<void> _decline(ChatRoom room) async {
    setState(() => _busyRoom = room.id);
    try {
      await widget.backend.declineInvite(room.id);
    } catch (_) {
      if (mounted) _showError('Couldn’t decline the invitation.');
    } finally {
      if (mounted) setState(() => _busyRoom = null);
    }
  }

  Future<void> _declineAndBlock(ChatRoom room) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DeclineAndBlockScreen(
          backend: widget.backend,
          palette: widget.palette,
          roomId: room.id,
          roomName: room.name,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showError(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final requests = widget.controller.requests(widget.backend.rooms);
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Message requests'),
        backgroundColor: p.background,
      ),
      body: requests.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.mark_email_read_outlined,
                      size: 48,
                      color: p.secondary,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'No message requests',
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Invitations from people you don’t share a room with '
                      'appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.muted),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: requests.length,
              itemBuilder: (context, index) {
                final room = requests[index];
                final inviter = widget.controller.inviterOf(room.id);
                final revealed = _revealed.contains(room.id);
                final busy = _busyRoom == room.id;
                return Card(
                  key: ValueKey('request-${room.id}'),
                  color: p.surface,
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: p.stroke),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            GestureDetector(
                              onTap: () => setState(() {
                                if (revealed) {
                                  _revealed.remove(room.id);
                                } else {
                                  _revealed.add(room.id);
                                }
                              }),
                              child: CircleAvatar(
                                radius: 22,
                                backgroundColor: p.raised,
                                foregroundColor: p.secondary,
                                child: revealed
                                    ? Text(
                                        room.name.characters.first
                                            .toUpperCase(),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      )
                                    : const Icon(Icons.person_outline_rounded),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    room.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.foreground,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    room.isDirect
                                        ? 'Invited you to chat'
                                        : 'Invited you to join',
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (inviter != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            revealed
                                ? 'From $inviter'
                                : 'From an unknown sender',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ],
                        if (!revealed) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Avatar and sender hidden. Tap the avatar to reveal.',
                            style: TextStyle(color: p.muted, fontSize: 11.5),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              key: ValueKey('request-accept-${room.id}'),
                              onPressed: busy ? null : () => _accept(room),
                              child: const Text('Accept'),
                            ),
                            OutlinedButton(
                              key: ValueKey('request-decline-${room.id}'),
                              onPressed: busy ? null : () => _decline(room),
                              child: const Text('Decline'),
                            ),
                            TextButton(
                              key: ValueKey('request-block-${room.id}'),
                              onPressed: busy
                                  ? null
                                  : () => _declineAndBlock(room),
                              child: const Text('Decline & block'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
