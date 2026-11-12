import 'pack_model.dart';

/// Converts known `:shortcode:` occurrences into MSC2545 emoticon images in
/// an outgoing message's `formatted_body`. The plain `body` keeps the
/// shortcodes, as FluffyChat, Cinny and Element Web do.
const maxEmoticonsPerMessage = 100;

const _textMsgtypes = {'m.text', 'm.emote', 'm.notice'};
const _htmlFormat = 'org.matrix.custom.html';

/// Elements whose text is never converted (code, links and mention pills,
/// reply fallbacks).
const _skippedElements = {'code', 'pre', 'a', 'mx-reply'};

final _codeAt = RegExp(':([^\\s:<>&"\']{1,$maxShortcodeLength}):');
final _tag = RegExp(r'<!--[\s\S]*?-->|<[^>]*>');
final _tagName = RegExp(r'^<\s*(/)?\s*([A-Za-z][A-Za-z0-9-]*)');

String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// The `<img>` tag for one emoticon, as other clients send it.
String emoticonImgTag(Uri url, String shortcode) {
  final label = escapeHtml(':$shortcode:');
  return '<img data-mx-emoticon src="${escapeHtml(url.toString())}" '
      'alt="$label" title="$label" height="32" />';
}

/// Plain text → HTML with the same line breaks the markdown step produces.
String plainTextToHtml(String text) =>
    escapeHtml(text).replaceAll('\r\n', '\n').replaceAll('\n', '<br />');

class _Budget {
  int remaining = maxEmoticonsPerMessage;
}

String _replaceInText(String text, AvailablePacks packs, _Budget budget) {
  if (!text.contains(':')) return text;
  final out = StringBuffer();
  var i = 0;
  var copied = 0;
  while (i < text.length && budget.remaining > 0) {
    final colon = text.indexOf(':', i);
    if (colon < 0) break;
    final match = _codeAt.matchAsPrefix(text, colon);
    final entry = match == null ? null : packs.resolve(match[1]!);
    if (match == null || entry == null) {
      // Unknown: the closing colon may open the next code (":a:b:").
      i = colon + 1;
      continue;
    }
    out
      ..write(text.substring(copied, colon))
      ..write(emoticonImgTag(entry.image.url, entry.image.shortcode));
    budget.remaining--;
    i = copied = match.end;
  }
  if (copied == 0) return text;
  out.write(text.substring(copied));
  return out.toString();
}

/// Replaces known shortcodes in the text of [html] (outside code, links and
/// reply fallbacks), leaving markup untouched. Returns null when nothing
/// was replaced.
String? replaceEmoticonsInHtml(String html, AvailablePacks packs) {
  final budget = _Budget();
  final out = StringBuffer();
  var skipDepth = 0;
  var last = 0;
  var changed = false;
  void text(String segment) {
    final replaced = skipDepth > 0
        ? segment
        : _replaceInText(segment, packs, budget);
    if (!identical(replaced, segment)) changed = true;
    out.write(replaced);
  }

  for (final match in _tag.allMatches(html)) {
    text(html.substring(last, match.start));
    final tag = match[0]!;
    out.write(tag);
    last = match.end;
    final name = _tagName.firstMatch(tag);
    if (name == null) continue;
    final element = name[2]!.toLowerCase();
    if (!_skippedElements.contains(element)) continue;
    if (name[1] != null) {
      if (skipDepth > 0) skipDepth--;
    } else if (!tag.endsWith('/>')) {
      skipDepth++;
    }
  }
  text(html.substring(last));
  return changed ? out.toString() : null;
}

Map<String, Object?> _transformMessage(
  Map<String, Object?> content,
  AvailablePacks packs,
) {
  final msgtype = content['msgtype'];
  final body = content['body'];
  if (!_textMsgtypes.contains(msgtype) || body is! String) return content;
  final formatted = content['format'] == _htmlFormat
      ? content['formatted_body']
      : null;
  final String? html;
  if (formatted is String) {
    html = replaceEmoticonsInHtml(formatted, packs);
  } else if (content.containsKey('formatted_body') || !body.contains(':')) {
    // A formatted body in another format: leave the message alone.
    html = null;
  } else {
    html = replaceEmoticonsInHtml(plainTextToHtml(body), packs);
  }
  if (html == null) return content;
  return {...content, 'format': _htmlFormat, 'formatted_body': html};
}

/// Applies emoticon images to a text message's content, including an edit's
/// `m.new_content`. Returns [content] itself when nothing changes.
Map<String, Object?> transformOutgoingEmoticons(
  Map<String, Object?> content,
  AvailablePacks packs,
) {
  if (!packs.supports(PackUsage.emoticon)) return content;
  var result = _transformMessage(content, packs);
  final replacement = content['m.new_content'];
  if (replacement is Map<String, Object?>) {
    final next = _transformMessage(replacement, packs);
    if (!identical(next, replacement)) {
      result = {...result, 'm.new_content': next};
    }
  }
  return result;
}
