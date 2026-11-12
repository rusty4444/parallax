import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import 'message_composition.dart';
import 'rich_timeline_features.dart';

/// One row in the composer's @-mention list.
@immutable
class MentionSuggestion {
  const MentionSuggestion({
    required this.id,
    required this.label,
    required this.insertText,
    this.subtitle,
    this.leading,
  });

  /// User ID, or `@room`.
  final String id;
  final String label;
  final String? subtitle;

  /// Text that replaces the typed `@query` (a user ID or `@room`, followed by
  /// a space). User IDs become pills and `m.mentions` at send time.
  final String insertText;
  final Widget? leading;
}

/// Returns suggestions for the text typed after `@`.
typedef MentionSource = List<MentionSuggestion> Function(String query);

/// The `@query` being typed at the caret, if any.
@immutable
class MentionQuery {
  const MentionQuery(this.start, this.end, this.query);

  /// Index of the `@`.
  final int start;

  /// Caret position.
  final int end;
  final String query;
}

final _mentionTrigger = RegExp(r'(?:^|[\s(])@([^\s@:]{0,40})$');

/// Finds an `@mention` being typed immediately before a collapsed caret.
MentionQuery? mentionQueryAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.baseOffset;
  if (caret < 1 || caret > value.text.length) return null;
  final before = value.text.substring(0, caret);
  final match = _mentionTrigger.firstMatch(before);
  if (match == null) return null;
  final query = match[1]!;
  return MentionQuery(caret - query.length - 1, caret, query);
}

/// Replaces the typed `@query` with [suggestion]'s insert text.
TextEditingValue applyMention(
  TextEditingValue value,
  MentionQuery query,
  MentionSuggestion suggestion,
) {
  final text = value.text.replaceRange(
    query.start,
    query.end,
    suggestion.insertText,
  );
  final caret = query.start + suggestion.insertText.length;
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// Builds a [MentionSource] for a room: cached joined/invited members and,
/// when the user may notify everyone, `@room` ("Everyone").
MentionSource? roomMentionSource({
  required ChatBackend backend,
  required String roomId,
  required AppPalette palette,
}) {
  final features = richTimelineFeaturesOf(backend);
  if (features == null) return null;
  return (query) {
    final needle = query.toLowerCase();
    return [
      if (features.canMentionRoom(roomId) &&
          ('room'.startsWith(needle) || 'everyone'.startsWith(needle)))
        MentionSuggestion(
          id: '@room',
          label: 'Everyone',
          subtitle: '@room',
          insertText: '@room ',
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: palette.accent.withValues(alpha: 0.3),
            child: Icon(
              Icons.campaign_outlined,
              size: 18,
              color: palette.foreground,
            ),
          ),
        ),
      for (final member in features.searchMembers(roomId, query))
        MentionSuggestion(
          id: member.userId,
          label: member.label,
          subtitle: member.userId,
          insertText: mentionInsertText(member.userId),
          leading: UserAvatar(
            name: member.label,
            url: member.avatar,
            backend: backend,
            palette: palette,
            size: 32,
          ),
        ),
    ];
  };
}

class _RouteRoom {
  const _RouteRoom(this.backend, this.roomId, this.palette);
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
}

final _routeRooms = Expando<_RouteRoom>('richTimelineRouteRoom');

/// Records which room the current route shows. The timeline calls this so
/// the composer on the same route can offer mentions without extra wiring.
void bindTimelineRoute(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required AppPalette palette,
}) {
  final route = ModalRoute.of(context);
  if (route == null) return;
  _routeRooms[route] = _RouteRoom(backend, roomId, palette);
}

/// The mention source for the room shown on [context]'s route, if any.
MentionSource? mentionSourceFor(BuildContext context) {
  final route = ModalRoute.of(context);
  final room = route == null ? null : _routeRooms[route];
  if (room == null) return null;
  return roomMentionSource(
    backend: room.backend,
    roomId: room.roomId,
    palette: room.palette,
  );
}
