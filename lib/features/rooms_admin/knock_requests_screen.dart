import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';

/// Element X "Requests to join": accept (invite), decline (kick) or decline
/// and ban each knock, or accept all.
class KnockRequestsScreen extends StatefulWidget {
  const KnockRequestsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<KnockRequestsScreen> createState() => _KnockRequestsScreenState();
}

class _KnockRequestsScreenState extends State<KnockRequestsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  RoomDetails? _details;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
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
          _error = 'Couldn’t load requests to join. Check your connection.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _act(
    String failureTitle,
    Future<void> Function(RoomsAdminFeatures admin) action,
  ) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(admin);
    } catch (_) {
      if (mounted && _owner.isCurrent) showAdminMessage(context, failureTitle);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _decline(RoomMemberDetails member, {required bool ban}) async {
    final reason = await askReason(
      context,
      title: ban ? 'Decline and ban from accessing' : 'Decline access',
      message: ban
          ? 'Are you sure you want to decline and ban ${member.name}? This '
                'user won’t be able to request access to join this room again.'
          : 'Are you sure you want to decline ${member.name}’s request to '
                'join this room?',
      confirm: ban ? 'Yes, decline and ban' : 'Yes, decline',
    );
    if (reason == null || !mounted || !_owner.isCurrent) return;
    await _act(
      ban
          ? 'We couldn’t decline and ban this request. Try again.'
          : 'We couldn’t decline this request. Try again.',
      (admin) => admin.declineKnock(
        widget.roomId,
        member.id,
        ban: ban,
        reason: reason,
      ),
    );
  }

  Future<void> _acceptAll(List<RoomMemberDetails> requests) async {
    final confirmed = await confirmAction(
      context,
      title: 'Accept all requests',
      message: 'Are you sure you want to accept all requests to join?',
      confirm: 'Yes, accept all',
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    await _act('We couldn’t accept all requests. Try again.', (admin) async {
      Object? failure;
      for (final member in requests) {
        try {
          await admin.acceptKnock(widget.roomId, member.id);
        } catch (error) {
          failure ??= error;
        }
      }
      if (failure != null) throw failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    final requests = details?.knockRequests ?? const <RoomMemberDetails>[];
    final idle = !_busy && !_loading;
    final canAccept = details?.can(RoomAction.invite) ?? false;
    return AdminPage(
      palette: p,
      title: 'Requests to join',
      busy: _loading || _busy,
      actions: [
        if (canAccept && requests.length > 1)
          TextButton(
            onPressed: idle ? () => _acceptAll(requests) : null,
            child: const Text('Accept all'),
          ),
      ],
      body: details == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Requests unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : requests.isEmpty
          ? AdminPlaceholder(
              palette: p,
              icon: Icons.front_hand_outlined,
              title: 'No pending request to join',
              message:
                  'When somebody asks to join the room, you’ll be able to '
                  'see their request here.',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: requests.length,
              itemBuilder: (context, index) {
                final member = requests[index];
                return AdminSection(
                  palette: p,
                  children: [
                    ListTile(
                      leading: PersonAvatar(
                        backend: widget.backend,
                        palette: p,
                        name: member.name,
                        url: member.avatarUrl,
                      ),
                      title: Text(
                        member.name,
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        member.id,
                        style: TextStyle(color: p.muted),
                      ),
                    ),
                    if (member.reason != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            member.reason!,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.foreground),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.end,
                        children: [
                          if (details.can(RoomAction.ban, member))
                            TextButton(
                              onPressed: idle
                                  ? () => _decline(member, ban: true)
                                  : null,
                              child: const Text('Decline and ban'),
                            ),
                          if (details.can(RoomAction.kick, member))
                            OutlinedButton(
                              onPressed: idle
                                  ? () => _decline(member, ban: false)
                                  : null,
                              child: const Text('Decline'),
                            ),
                          if (canAccept)
                            FilledButton(
                              onPressed: idle
                                  ? () => _act(
                                      'We couldn’t accept this request. '
                                      'Try again.',
                                      (admin) => admin.acceptKnock(
                                        widget.roomId,
                                        member.id,
                                      ),
                                    )
                                  : null,
                              child: const Text('Accept'),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// Room-screen banner for pending knocks, from synced state. Actions open
/// the list, which re-reads server state before anything is written.
class KnockRequestsBanner extends StatefulWidget {
  const KnockRequestsBanner({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<KnockRequestsBanner> createState() => _KnockRequestsBannerState();
}

class _KnockRequestsBannerState extends State<KnockRequestsBanner> {
  final _dismissed = <String>{};
  bool _accepting = false;

  Future<void> _accept(String userId) async {
    final admin = roomsAdminFeaturesOf(widget.backend);
    if (admin == null || _accepting) return;
    setState(() => _accepting = true);
    try {
      await admin.acceptKnock(widget.roomId, userId);
      if (mounted) setState(() => _dismissed.add(userId));
    } catch (_) {
      if (mounted) {
        showAdminMessage(
          context,
          'We couldn’t accept this request. Would you like to try again?',
        );
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  void _viewAll() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => KnockRequestsScreen(
        backend: widget.backend,
        palette: widget.palette,
        roomId: widget.roomId,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.backend,
    builder: (context, _) {
      final admin = roomsAdminFeaturesOf(widget.backend);
      if (admin == null) return const SizedBox.shrink();
      // Cheap first: only knockable rooms with pending requests continue.
      final requests = [
        for (final member in admin.cachedKnockRequests(widget.roomId))
          if (!_dismissed.contains(member.id)) member,
      ];
      if (requests.isEmpty) return const SizedBox.shrink();
      final details = admin.cachedRoomDetails(widget.roomId);
      if (details == null || !details.canManageKnocks) {
        return const SizedBox.shrink();
      }
      final p = widget.palette;
      final single = requests.length == 1 ? requests.single : null;
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: p.raised.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.accent.withValues(alpha: 0.45)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Icon(Icons.front_hand_outlined, color: p.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    single != null
                        ? '${single.name} wants to join this room'
                        : '${requests.length} people want to join this room',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _viewAll,
                  child: Text(single != null ? 'View' : 'View all'),
                ),
                if (single != null && details.can(RoomAction.invite))
                  FilledButton(
                    onPressed: _accepting ? null : () => _accept(single.id),
                    child: const Text('Accept'),
                  ),
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: () => setState(
                    () => _dismissed.addAll(requests.map((m) => m.id)),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
