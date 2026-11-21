// Hook implementations for the stories module.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import 'stories.dart';

/// Wraps the signed-in app with the stories controller.
Widget wrapWithStories(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => _StoriesHost(backend: ctx.backend, child: child);

class _StoriesHost extends StatefulWidget {
  const _StoriesHost({required this.backend, required this.child});
  final ChatBackend backend;
  final Widget child;

  @override
  State<_StoriesHost> createState() => _StoriesHostState();
}

class _StoriesHostState extends State<_StoriesHost> {
  final _controller = StoriesController.shared;

  @override
  void initState() {
    super.initState();
    _controller.bindBackend(widget.backend);
  }

  @override
  void didUpdateWidget(_StoriesHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      _controller.bindBackend(widget.backend);
    }
  }

  @override
  Widget build(BuildContext context) =>
      StoriesScope(controller: _controller, child: widget.child);
}

/// Settings → Chats → "Stories" opt-in toggle.
List<Widget> storiesChatsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final controller = StoriesScope.maybeOf(context);
  if (controller == null) return const [];
  return [
    ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SwitchListTile(
        key: const ValueKey('stories-toggle'),
        value: controller.enabled,
        secondary: const Icon(Icons.auto_stories_outlined),
        title: const Text('Stories'),
        subtitle: const Text(
          'Show 24-hour photo and text updates at the top of your inbox',
        ),
        onChanged: (value) => controller.setEnabled(value),
      ),
    ),
  ];
}
