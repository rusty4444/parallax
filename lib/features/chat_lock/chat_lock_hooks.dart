// Hook implementations for the per-chat lock module.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import 'chat_lock_gate.dart';
import 'chat_lock_store.dart';

/// Wraps the signed-in app with the per-chat lock store, bound to the active
/// account.
Widget wrapWithChatLock(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _ChatLockHost(backend: ctx.backend, child: child);

class _ChatLockHost extends StatefulWidget {
  const _ChatLockHost({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_ChatLockHost> createState() => _ChatLockHostState();
}

class _ChatLockHostState extends State<_ChatLockHost> {
  final _store = ChatLockStore.shared;

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_accountChanged);
    _bind();
  }

  @override
  void didUpdateWidget(_ChatLockHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_accountChanged);
      widget.backend.addListener(_accountChanged);
      _bind();
    }
  }

  @override
  void dispose() {
    widget.backend.removeListener(_accountChanged);
    super.dispose();
  }

  void _accountChanged() => _bind();

  void _bind() =>
      _store.bindAccount(BackendSessionOwner.keyFor(widget.backend));

  @override
  Widget build(BuildContext context) =>
      ChatLockScope(store: _store, child: widget.child);
}

/// Room details → "Lock chat" / "Unlock chat" toggle.
List<Widget> chatLockRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) {
  final store = ChatLockScope.maybeOf(context);
  if (store == null) return const [];
  final locked = store.isLocked(ctx.roomId);
  return [
    SwitchListTile(
      key: const ValueKey('chat-lock-toggle'),
      value: locked,
      secondary: Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded),
      title: Text(locked ? 'Chat locked' : 'Lock chat'),
      subtitle: Text(
        locked
            ? 'Preview hidden; unlock to read'
            : 'Require biometrics or your PIN to open',
      ),
      onChanged: (value) async {
        if (value && !store.canLock) {
          await store.refreshCredential();
          if (!store.canLock && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Set up an app lock PIN in Settings → Security first.',
                ),
              ),
            );
            return;
          }
        }
        await store.setLocked(ctx.roomId, value);
      },
    ),
  ];
}
