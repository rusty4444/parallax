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

  /// Text that replaces the typed `@query`: a unique display name followed by
  /// a space, or the user ID when names are ambiguous. IDs are restored before
  /// sending so HTML pills and `m.mentions` always address the right person.
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

/// A trigger (`@`, `:`, `/` …) and the query typed after it, immediately
/// before a collapsed caret. Generalises [MentionQuery] for the composer's
/// other autocomplete sources.
@immutable
class ComposerTriggerQuery {
  const ComposerTriggerQuery(this.trigger, this.start, this.end, this.query);
  final String trigger;

  /// Index of the trigger character.
  final int start;

  /// Caret position.
  final int end;
  final String query;
}

/// Finds [trigger] typed after whitespace, `(` or at the start of the text,
/// followed by up to [maxQueryLength] non-space characters up to the caret.
/// With [startOfTextOnly] the trigger must be the first character (slash
/// commands).
ComposerTriggerQuery? triggerQueryAt(
  TextEditingValue value,
  String trigger, {
  bool startOfTextOnly = false,
  int maxQueryLength = 40,
}) {
  if (trigger.length != 1 || trigger.trim().isEmpty) return null;
  if (trigger == '@') {
    final mention = mentionQueryAt(value);
    return mention == null
        ? null
        : ComposerTriggerQuery('@', mention.start, mention.end, mention.query);
  }
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.baseOffset;
  if (caret < 1 || caret > value.text.length) return null;
  final escaped = RegExp.escape(trigger);
  final pattern = RegExp(
    '${startOfTextOnly ? '^' : r'(?:^|[\s(])'}'
    '$escaped([^\\s$escaped]{0,$maxQueryLength})\$',
  );
  final match = pattern.firstMatch(value.text.substring(0, caret));
  if (match == null) return null;
  final query = match[1]!;
  return ComposerTriggerQuery(trigger, caret - query.length - 1, caret, query);
}

/// Replaces the typed trigger and query with [insertText].
TextEditingValue applySuggestionText(
  TextEditingValue value,
  ComposerTriggerQuery query,
  String insertText,
) {
  final text = value.text.replaceRange(query.start, query.end, insertText);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: query.start + insertText.length),
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
    // Ranking already scans cached membership; retain the full result here so
    // duplicate display names can safely keep their unambiguous Matrix IDs.
    final allMembers = features.searchMembers(roomId, '', limit: 1000000);
    final labelCounts = <String, int>{};
    for (final member in allMembers) {
      final label = member.label.toLowerCase();
      labelCounts[label] = (labelCounts[label] ?? 0) + 1;
    }
    final members = rankMembers(allMembers, query);
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
      for (final member in members)
        MentionSuggestion(
          id: member.userId,
          label: member.label,
          subtitle: member.userId,
          insertText:
              member.displayName != null &&
                  labelCounts[member.label.toLowerCase()] == 1
              ? '@${member.label} '
              : mentionInsertText(member.userId),
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
