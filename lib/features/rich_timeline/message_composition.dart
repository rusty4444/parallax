import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:matrix/matrix.dart' show MatrixIdExtension;
// The SDK's own Matrix-flavoured markdown (pills, spoilers, strikethrough),
// exactly as Room.sendTextEvent(parseMarkdown: true) uses it. Pinned SDK.
// ignore: implementation_imports
import 'package:matrix/src/utils/markdown.dart' as sdk_markdown;

import '../composer/markdown_format.dart' show InlineFormat, scanMarkdown;
import 'permalinks.dart';

/// Builds `m.room.message` content from the composer's plain text.
///
/// Deterministic: the result depends only on the arguments, so persisted
/// outbox payloads stay plain text and are converted at transmit time.
///
/// * `/me text` becomes an `m.emote` (not for edits).
/// * Markdown becomes `formatted_body` only when it adds formatting.
/// * `m.mentions` lists matrix.to / `matrix:u/` user links and bare user IDs
///   (as inserted by mention autocomplete), `@room`, and the replied-to
///   sender. Your own ID is never mentioned.
/// * For [editEventId] the content is an `m.replace` with `m.new_content`;
///   the top-level `m.mentions` only lists users not in [previousMentions].
Map<String, Object?> composeTextMessage(
  String text, {
  String? ownUserId,
  String? replyToSender,
  String? editEventId,
  Iterable<String> previousMentions = const [],
}) {
  var body = text;
  var msgtype = 'm.text';
  if (editEventId == null && body.startsWith('/me ')) {
    body = body.substring(4);
    msgtype = 'm.emote';
  }
  final content = <String, Object?>{'msgtype': msgtype, 'body': body};
  final html = markdownToMatrixHtml(body);
  if (html != null) {
    content['format'] = 'org.matrix.custom.html';
    content['formatted_body'] = html;
  }
  final mentions = mentionsFor(
    body,
    ownUserId: ownUserId,
    replyToSender: editEventId == null ? replyToSender : null,
  );
  content['m.mentions'] = mentions.toJson();
  if (editEventId == null) return content;

  final previous = previousMentions.toSet();
  final added = MessageMentions(
    userIds: [
      for (final id in mentions.userIds)
        if (!previous.contains(id)) id,
    ],
    room: mentions.room,
  );
  return {
    'msgtype': msgtype,
    'body': '* $body',
    if (html != null) ...{
      'format': 'org.matrix.custom.html',
      'formatted_body': '* $html',
    },
    'm.new_content': content,
    'm.mentions': added.toJson(),
    'm.relates_to': {'rel_type': 'm.replace', 'event_id': editEventId},
  };
}

/// Intentional mentions (`m.mentions`).
class MessageMentions {
  const MessageMentions({this.userIds = const [], this.room = false});
  final List<String> userIds;
  final bool room;

  Map<String, Object?> toJson() => {
    if (userIds.isNotEmpty) 'user_ids': userIds,
    if (room) 'room': true,
  };
}

final _userLink = RegExp(
  r'https?://matrix\.to/#/((?:@|%40)[^\s)\]>"/?]+)|matrix:u/([^\s)\]>"/?]+)',
  caseSensitive: false,
);
final _bareUserId = RegExp(
  r'(?<=^|[\s.!?:;(\[])@[^\s:@]+:(?:[^\s]+\.[a-z]+|[\d.]+|\[[a-f0-9:]+\])(?::\d+)?',
  caseSensitive: false,
);
final _roomMention = RegExp(r'(?<![\w@])@room(?![\w:])');

/// Extracts mentions from composer text. See [composeTextMessage].
MessageMentions mentionsFor(
  String text, {
  String? ownUserId,
  String? replyToSender,
}) {
  final ids = <String>[];
  void add(String candidate) {
    var id = candidate;
    try {
      id = Uri.decodeComponent(candidate);
    } catch (_) {}
    if (!id.startsWith('@')) id = '@$id';
    if (id == ownUserId || ids.contains(id)) return;
    if (!id.isValidMatrixIdStrict(strictDomainCheck: true)) return;
    ids.add(id);
  }

  for (final match in _userLink.allMatches(text)) {
    add(match[1] ?? match[2]!);
  }
  final withoutLinks = text.replaceAll(_userLink, ' ');
  for (final match in _bareUserId.allMatches(withoutLinks)) {
    add(match[0]!);
  }
  if (replyToSender != null) add(replyToSender);
  return MessageMentions(userIds: ids, room: _roomMention.hasMatch(text));
}

const _underlineOpen = '\uE000';
const _underlineClose = '\uE001';

/// Replaces paired `<u>…</u>` outside code with placeholders the SDK
/// converter leaves alone (it escapes all other inline HTML).
String _protectUnderline(String body) {
  if (!body.contains('<u>') ||
      body.contains(_underlineOpen) ||
      body.contains(_underlineClose)) {
    return body;
  }
  final spans = [
    for (final span in scanMarkdown(body).spans)
      if (span.format == InlineFormat.underline) span,
  ];
  if (spans.isEmpty) return body;
  final buffer = StringBuffer();
  var cursor = 0;
  for (final span in spans) {
    buffer
      ..write(body.substring(cursor, span.start))
      ..write(_underlineOpen)
      ..write(body.substring(span.contentStart, span.contentEnd))
      ..write(_underlineClose);
    cursor = span.end;
  }
  buffer.write(body.substring(cursor));
  return buffer.toString();
}

/// Converts composer markdown to Matrix HTML, or returns null when the
/// result carries no formatting beyond paragraphs and line breaks.
///
/// Besides the SDK's Matrix-flavoured markdown, `<u>text</u>` (the
/// composer's underline, as in Element Web's markdown mode) becomes `<u>`.
String? markdownToMatrixHtml(String body) {
  if (body.trim().isEmpty) return null;
  final protected = _protectUnderline(body);
  String html;
  try {
    html = sdk_markdown.markdown(
      protected,
      convertLinebreaks: true,
      enableLatex: false,
    );
  } catch (_) {
    return null;
  }
  if (!identical(protected, body)) {
    html = html
        .replaceAll(_underlineOpen, '<u>')
        .replaceAll(_underlineClose, '</u>');
    // Re-serialise so underline crossing other inline markup stays nested.
    html = html_parser.parseFragment(html).outerHtml;
  }
  final fragment = html_parser.parseFragment(html);
  final tags = <String>{};
  void collect(dom.Node node) {
    for (final child in node.nodes) {
      if (child is dom.Element) {
        tags.add(child.localName ?? '');
        collect(child);
      }
    }
  }

  collect(fragment);
  if (tags.difference(const {'p', 'br'}).isEmpty) return null;
  return html;
}

/// User IDs in an event content's `m.mentions` (for edits).
List<String> mentionedUserIds(Map<String, Object?>? content) {
  final mentions = content?['m.mentions'];
  final ids = mentions is Map ? mentions['user_ids'] : null;
  return ids is List ? ids.whereType<String>().toList() : const [];
}

/// The plain-text pill label for a user, for composer insertion.
String mentionInsertText(String userId) => '$userId ';

/// A permalink for [userId] (used by tests and HTML output).
String mentionLink(String userId) => userPermalink(userId);
