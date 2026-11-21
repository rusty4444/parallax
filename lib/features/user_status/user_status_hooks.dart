// Hook implementations for the user-status / notes module.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../room_events.dart';
import 'user_status.dart';
import 'user_status_screen.dart';

/// Wraps the signed-in app with the user-status controller.
Widget wrapWithUserStatus(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _UserStatusHost(backend: ctx.backend, child: child);

class _UserStatusHost extends StatefulWidget {
  const _UserStatusHost({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_UserStatusHost> createState() => _UserStatusHostState();
}

class _UserStatusHostState extends State<_UserStatusHost> {
  final _controller = UserStatusController.shared;

  @override
  void initState() {
    super.initState();
    _controller.bindBackend(widget.backend);
  }

  @override
  void didUpdateWidget(_UserStatusHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      _controller.bindBackend(widget.backend);
    }
  }

  @override
  Widget build(BuildContext context) =>
      UserStatusScope(controller: _controller, child: widget.child);
}

/// Settings → Account → "Status".
List<Widget> userStatusAccountRows(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final controller = UserStatusScope.maybeOf(context);
  if (controller == null) return const [];
  return [
    ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        final active = status.isActive(DateTime.now());
        return ListTile(
          key: const ValueKey('user-status-row'),
          leading: const Icon(Icons.mode_comment_outlined),
          title: const Text('Status'),
          subtitle: Text(active ? status.label : 'Set a status or note'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => UserStatusScreen(
                controller: controller,
                palette: ctx.palette,
              ),
            ),
          ),
        );
      },
    ),
  ];
}

/// A subtle banner showing a DM partner's presence status, when available.
List<Widget> userStatusRoomBanners(BuildContext context, RoomHookContext ctx) {
  if (UserStatusScope.maybeOf(context) == null) return const [];
  if (!(ctx.room?.isDirect ?? false)) return const [];
  return [
    _PartnerStatusBanner(
      key: ValueKey('user-status.banner.${ctx.roomId}'),
      backend: ctx.backend,
      roomId: ctx.roomId,
      palette: ctx.palette,
    ),
  ];
}

class _PartnerStatusBanner extends StatefulWidget {
  const _PartnerStatusBanner({
    super.key,
    required this.backend,
    required this.roomId,
    required this.palette,
  });
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  @override
  State<_PartnerStatusBanner> createState() => _PartnerStatusBannerState();
}

class _PartnerStatusBannerState extends State<_PartnerStatusBanner> {
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final controller = UserStatusController.shared;
    final backend = widget.backend;
    final sdk = backend is MatrixSdkAccess
        ? (backend as MatrixSdkAccess).sdkClient
        : null;
    final partner = sdk?.getRoomById(widget.roomId)?.directChatMatrixID;
    if (partner == null || partner == backend.userId) return;
    final status = await controller.contactStatus(partner);
    if (mounted && status != null) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          Icon(Icons.mode_comment_outlined, size: 15, color: p.secondary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
