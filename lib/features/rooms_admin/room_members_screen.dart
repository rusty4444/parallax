import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'invite_people_screen.dart';
import 'member_moderation.dart';
import 'user_profile_screen.dart';

/// People in a room with search and Members / Invited / Banned filters.
class RoomMembersScreen extends StatefulWidget {
  const RoomMembersScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<RoomMembersScreen> createState() => _RoomMembersScreenState();
}

class _RoomMembersScreenState extends State<RoomMembersScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _query = TextEditingController();
  RoomDetails? _details;
  RoomMemberStatus _filter = RoomMemberStatus.joined;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.backend.getRoomDetails(widget.roomId);
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _details = details);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() {
          _details = null;
          _error = 'Couldn’t load people. Check your connection and retry.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _invite() async {
    final details = _details;
    if (details == null || !details.can(RoomAction.invite) || _busy) return;
    final sent = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => InvitePeopleScreen(
          backend: widget.backend,
          palette: widget.palette,
          roomId: widget.roomId,
          excluded: {
            for (final member in details.members)
              if (member.status != RoomMemberStatus.knocking) member.id,
          },
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent) return;
    if (sent != null && sent > 0) {
      showAdminMessage(
        context,
        sent == 1 ? 'Invitation sent.' : '$sent invitations sent.',
      );
    }
    await _load();
  }

  Future<void> _open(RoomMemberDetails member) async {
    final details = _details;
    if (details == null || _busy) return;
    final choice = await showMemberSheet(
      context,
      backend: widget.backend,
      palette: widget.palette,
      details: details,
      member: member,
    );
    if (!mounted || !_owner.isCurrent || choice == null) return;
    if (choice == MemberChoice.profile) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UserProfileScreen(
            backend: widget.backend,
            palette: widget.palette,
            userId: member.id,
            roomId: widget.roomId,
          ),
        ),
      );
    } else {
      final done = await moderateFromChoice(
        context,
        backend: widget.backend,
        roomId: widget.roomId,
        member: member,
        choice: choice,
        onBusy: (busy) {
          if (mounted) setState(() => _busy = busy);
        },
      );
      if (!done || !mounted || !_owner.isCurrent) return;
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    final term = _query.text.trim().toLowerCase();
    final visible = details == null
        ? const <RoomMemberDetails>[]
        : [
            for (final member in details.membersWith(_filter))
              if (term.isEmpty ||
                  member.name.toLowerCase().contains(term) ||
                  member.id.toLowerCase().contains(term))
                member,
          ];
    return AdminPage(
      palette: p,
      title: 'People',
      busy: _loading || _busy,
      actions: [
        if (details != null && details.can(RoomAction.invite))
          TextButton.icon(
            onPressed: _busy ? null : _invite,
            icon: const Icon(Icons.person_add_alt_1_outlined),
            label: const Text('Invite'),
          ),
      ],
      body: details == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'People unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      labelText: 'Search people',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Row(
                    children: [
                      for (final (status, label) in const [
                        (RoomMemberStatus.joined, 'Members'),
                        (RoomMemberStatus.invited, 'Invited'),
                        (RoomMemberStatus.banned, 'Banned'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              '$label (${details.membersWith(status).length})',
                            ),
                            selected: _filter == status,
                            onSelected: (_) => setState(() => _filter = status),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? AdminPlaceholder(
                          palette: p,
                          icon: Icons.person_off_outlined,
                          title: term.isNotEmpty
                              ? 'No results for “${_query.text.trim()}”'
                              : switch (_filter) {
                                  RoomMemberStatus.banned =>
                                    'There are no banned users.',
                                  RoomMemberStatus.invited =>
                                    'No pending invitations.',
                                  _ => 'No members.',
                                },
                          message: term.isNotEmpty
                              ? 'Check the spelling or try a new search'
                              : null,
                        )
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) =>
                              _tile(details, visible[index]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _tile(RoomDetails details, RoomMemberDetails member) {
    final p = widget.palette;
    final self = member.id == widget.backend.userId;
    final canModerate =
        !self &&
        [
          RoomAction.kick,
          RoomAction.ban,
          RoomAction.unban,
        ].any((action) => details.can(action, member));
    return ListTile(
      onTap: _busy ? null : () => _open(member),
      leading: PersonAvatar(
        backend: widget.backend,
        palette: p,
        name: member.name,
        url: member.avatarUrl,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              self ? '${member.name} (you)' : member.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          RoleBadge(role: member.role, palette: p),
        ],
      ),
      subtitle: Text(
        member.status == RoomMemberStatus.invited
            ? '${member.id} · Pending'
            : member.status == RoomMemberStatus.banned && member.reason != null
            ? '${member.id} · ${member.reason}'
            : member.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.muted),
      ),
      trailing: canModerate
          ? IconButton(
              tooltip: 'Moderate ${member.id}',
              onPressed: _busy ? null : () => _open(member),
              icon: const Icon(Icons.more_vert_rounded),
            )
          : null,
    );
  }
}
