import 'package:flutter/foundation.dart';

import 'permalinks.dart';

enum TextTokenKind { text, link, permalink, roomMention }

/// A run of plain message text, classified for rendering.
@immutable
class TextToken {
  const TextToken(this.kind, this.text, {this.href, this.permalink});
  final TextTokenKind kind;

  /// Text as written in the message.
  final String text;

  /// Target for [TextTokenKind.link] (already safe-checked).
  final Uri? href;
  final MatrixPermalink? permalink;

  @override
  String toString() => '$kind($text)';
}

final _tokenPattern = RegExp(
  r'(?<url>(?:https?://|www\.)[^\s<>"]+)'
  r'|(?<matrix>matrix:[a-z]+/[^\s<>"]+)'
  r'|(?<email>(?<![\w.%+-])[\w.%+-]+@[a-z0-9.-]+\.[a-z]{2,}(?![\w-]))'
  r'|(?<room>(?<![\w@])@room(?![\w:]))',
  caseSensitive: false,
);

const _trailing = '.,;:!?\'"*_~';

/// Splits [input] into text, links, Matrix permalinks (pills) and `@room`.
/// Only http(s), mailto and matrix links are produced; trailing punctuation
/// and unbalanced closing brackets are left as text.
List<TextToken> tokenizeText(String input, {bool pillRoomMention = true}) {
  final tokens = <TextToken>[];
  var cursor = 0;
  void addText(String text) {
    if (text.isEmpty) return;
    if (tokens.isNotEmpty && tokens.last.kind == TextTokenKind.text) {
      tokens[tokens.length - 1] = TextToken(
        TextTokenKind.text,
        tokens.last.text + text,
      );
    } else {
      tokens.add(TextToken(TextTokenKind.text, text));
    }
  }

  for (final match in _tokenPattern.allMatches(input)) {
    if (match.start < cursor) continue;
    var raw = match[0]!;
    if (match.namedGroup('room') != null) {
      addText(input.substring(cursor, match.start));
      if (pillRoomMention) {
        tokens.add(const TextToken(TextTokenKind.roomMention, '@room'));
      } else {
        addText(raw);
      }
      cursor = match.end;
      continue;
    }
    if (match.namedGroup('email') == null) raw = _trimLink(raw);
    final end = match.start + raw.length;
    addText(input.substring(cursor, match.start));
    cursor = end;
    final href = match.namedGroup('email') != null
        ? 'mailto:$raw'
        : raw.toLowerCase().startsWith('www.')
        ? 'https://$raw'
        : raw;
    final permalink = MatrixPermalink.parse(href);
    if (permalink != null) {
      tokens.add(TextToken(TextTokenKind.permalink, raw, permalink: permalink));
      continue;
    }
    final uri = safeLinkUri(href);
    if (uri == null) {
      addText(raw);
    } else {
      tokens.add(TextToken(TextTokenKind.link, raw, href: uri));
    }
  }
  addText(input.substring(cursor));
  return tokens;
}

String _trimLink(String raw) {
  var value = raw;
  while (value.isNotEmpty) {
    final last = value[value.length - 1];
    if (_trailing.contains(last)) {
      value = value.substring(0, value.length - 1);
      continue;
    }
    final pairs = {')': '(', ']': '[', '}': '{'};
    final open = pairs[last];
    if (open != null &&
        open.allMatches(value).length < last.allMatches(value).length) {
      value = value.substring(0, value.length - 1);
      continue;
    }
    break;
  }
  return value;
}
