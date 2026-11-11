import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'hooks/registry.dart';
import 'room_details.dart';

class RoomDetailsScreen extends StatefulWidget {
  const RoomDetailsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

class _RoomDetailsScreenState extends State<RoomDetailsScreen> {
  RoomDetails? _details;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || _busy) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.backend.getRoomDetails(widget.roomId);
      if (mounted && generation == _generation) {
        setState(() => _details = details);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _details = null; // Never retain stale permissions on fetch failure.
          _error =
              'Couldn’t load room details. Check your connection and retry.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(); // Backend re-fetches power levels immediately before write.
    } catch (_) {
      if (mounted) {
        setState(() {
          _details = null;
          _error =
              'Couldn’t $label. Your permissions or the room may have changed. Refresh to retry.';
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    // Success is not optimistic: show the server's state, or a refresh error.
    await _load();
  }

  Future<String?> _askText({
    required String title,
    required String initial,
    required String label,
    bool allowEmpty = false,
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          onChanged: (text) => value = text,
          autofocus: true,
          maxLines: label == 'Topic' ? 3 : 1,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = value.trim();
              if (trimmed.isEmpty && !allowEmpty) return;
              Navigator.pop(dialogContext, trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(RoomAction action) async {
    final details = _details;
    if (details == null || !details.can(action) || _busy) return;
    final name = action == RoomAction.name;
    final value = await _askText(
      title: name ? 'Edit room name' : 'Edit room topic',
      initial: name ? details.name : details.topic,
      label: name ? 'Room name' : 'Topic',
      allowEmpty: !name,
    );
    if (value == null || !mounted) return;
    await _run(
      name ? 'update room name' : 'update room topic',
      () => name
          ? widget.backend.editRoomName(widget.roomId, value)
          : widget.backend.editRoomTopic(widget.roomId, value),
    );
  }

  Future<void> _invite() async {
    if (_details?.can(RoomAction.invite) != true || _busy) return;
    final id = await _askText(
      title: 'Invite someone',
      initial: '',
      label: 'Matrix ID (@user:server)',
    );
    if (id == null || !mounted) return;
    if (!isValidRoomInviteId(id)) {
      setState(() => _error = 'Enter a valid Matrix ID, such as @user:server.');
      return;
    }
    await _run(
      'invite $id',
      () => widget.backend.inviteToRoom(widget.roomId, id),
    );
  }

  Future<void> _moderate(RoomMemberDetails member, RoomAction action) async {
    if (_details?.can(action, member) != true ||
        member.id == widget.backend.userId ||
        _busy) {
      return;
    }
    final verb = action.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          '${verb[0].toUpperCase()}${verb.substring(1)} ${member.name}?',
        ),
        content: Text('$verb ${member.id} in this room?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('${verb[0].toUpperCase()}${verb.substring(1)}'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      '$verb ${member.id}',
      () => widget.backend.moderateRoomMember(widget.roomId, member.id, action),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back to room',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'Room details',
                      style: TextStyle(
                        color: p.foreground,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh room details',
                    onPressed: _loading || _busy ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              if (_loading || _busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: TextStyle(color: p.foreground)),
                ),
              if (details == null && !_loading)
                TextButton(onPressed: _load, child: const Text('Retry')),
              if (details != null)
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(
                        title: Text(details.name),
                        subtitle: Text(details.roomId),
                        trailing:
                            details.can(RoomAction.name) && !_busy && !_loading
                            ? IconButton(
                                tooltip: 'Edit room name',
                                onPressed: () => _edit(RoomAction.name),
                                icon: const Icon(Icons.edit_outlined),
                              )
                            : null,
                      ),
                      ListTile(
                        title: const Text('Topic'),
                        subtitle: Text(
                          details.topic.isEmpty ? 'No topic' : details.topic,
                        ),
                        trailing:
                            details.can(RoomAction.topic) && !_busy && !_loading
                            ? IconButton(
                                tooltip: 'Edit room topic',
                                onPressed: () => _edit(RoomAction.topic),
                                icon: const Icon(Icons.edit_outlined),
                              )
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Members (${details.members.length})',
                                style: TextStyle(
                                  color: p.foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (details.can(RoomAction.invite) &&
                                !_busy &&
                                !_loading)
                              TextButton.icon(
                                onPressed: _invite,
                                icon: const Icon(
                                  Icons.person_add_alt_1_outlined,
                                ),
                                label: const Text('Invite'),
                              ),
                          ],
                        ),
                      ),
                      for (final member in details.members)
                        ListTile(
                          title: Text(member.name),
                          subtitle: Text(
                            '${member.id} · ${member.status.name}',
                          ),
                          trailing:
                              member.id == widget.backend.userId ||
                                  _busy ||
                                  _loading ||
                                  ![
                                    RoomAction.kick,
                                    RoomAction.ban,
                                    RoomAction.unban,
                                  ].any((action) => details.can(action, member))
                              ? null
                              : PopupMenuButton<RoomAction>(
                                  tooltip: 'Moderate ${member.id}',
                                  onSelected: (action) =>
                                      _moderate(member, action),
                                  itemBuilder: (_) => [
                                    for (final action in [
                                      RoomAction.kick,
                                      RoomAction.ban,
                                      RoomAction.unban,
                                    ])
                                      if (details.can(action, member))
                                        PopupMenuItem(
                                          value: action,
                                          child: Text(
                                            '${action.name[0].toUpperCase()}${action.name.substring(1)}',
                                          ),
                                        ),
                                  ],
                                ),
                        ),
                      ...roomDetailsSectionsFor(
                        context,
                        RoomHookContext(
                          backend: widget.backend,
                          roomId: widget.roomId,
                          palette: p,
                          room: [
                            for (final room in widget.backend.rooms)
                              if (room.id == widget.roomId) room,
                          ].firstOrNull,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
