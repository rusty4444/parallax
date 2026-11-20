import 'package:flutter/material.dart';

import '../chat_backend.dart';
import '../features/threads/timeline_navigation.dart';

/// The quoted source of a reply. Tapping or clicking it loads the room's
/// live timeline and scrolls up to the original message (the same jump as
/// search results and permalinks), marking it with a "Jumped to this
/// message" footer. Newer messages stay visible below, so scrolling back
/// down just works.
///
/// Quotes without a server event ID (pending local echoes) or on backends
/// that cannot jump stay inert, exactly as before.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.backend,
    required this.roomId,
    required this.replyToId,
    required this.child,
  });

  final ChatBackend backend;
  final String roomId;
  final String replyToId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final navigation = timelineNavigationOf(backend);
    if (navigation == null || !replyToId.startsWith(r'$')) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _jumpToSource(context, navigation),
        child: child,
      ),
    );
  }

  Future<void> _jumpToSource(
    BuildContext context,
    TimelineNavigation navigation,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await navigation.openRoomAt(roomId, replyToId);
    } catch (_) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Couldn’t jump to that message.')),
      );
    }
  }
}
