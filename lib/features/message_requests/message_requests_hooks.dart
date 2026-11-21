// Hook implementations for the message-requests module.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'message_requests.dart';

/// Wraps the signed-in app with the message-requests controller, bound to the
/// active backend.
Widget wrapWithMessageRequests(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _MessageRequestsHost(backend: ctx.backend, child: child);

class _MessageRequestsHost extends StatefulWidget {
  const _MessageRequestsHost({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_MessageRequestsHost> createState() => _MessageRequestsHostState();
}

class _MessageRequestsHostState extends State<_MessageRequestsHost> {
  final _controller = MessageRequestsController.shared;

  @override
  void initState() {
    super.initState();
    _controller.bindBackend(widget.backend);
    unawaited(_controller.load());
  }

  @override
  void didUpdateWidget(_MessageRequestsHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      _controller.bindBackend(widget.backend);
    }
  }

  @override
  Widget build(BuildContext context) =>
      MessageRequestsScope(controller: _controller, child: widget.child);
}

/// Settings → Privacy → "Separate message requests".
List<Widget> messageRequestsPrivacySections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final controller = MessageRequestsScope.maybeOf(context);
  if (controller == null) return const [];
  return [
    ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('message-requests-toggle'),
        value: controller.separate,
        secondary: const Icon(Icons.mark_email_unread_outlined),
        title: const Text('Separate message requests'),
        subtitle: const Text(
          'Review invitations from unknown senders in their own inbox',
        ),
        onChanged: (value) => controller.setSeparate(value),
      ),
    ),
  ];
}
