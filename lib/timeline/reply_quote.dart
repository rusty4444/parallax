import 'package:flutter/material.dart';

import '../chat_backend.dart';
import '../features/threads/timeline_navigation.dart';

/// The quoted source of a reply. Tapping or clicking it jumps the timeline
/// to the original message, using the same focus as search results and
/// permalinks: the source becomes the newest visible entry ("Jumped to this
/// message" footer) and "Jump to latest" returns to the live end.
///
/// Quotes without a server event ID (pending local echoes) or on backends
/// that cannot focus events stay inert, exactly as before.
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
    // Already focused on the source: there is nothing to jump to.
    if (navigation.focusedEventIn(roomId) == replyToId) return;
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
