import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../chat_backend.dart';
import '../rich_timeline/message_composition.dart';

/// Composer text for editing [entry]: its markdown-ish source.
///
/// Messages sent from markdown composers (Parallax, Element Web) carry the
/// markdown in `body`, which is returned unchanged when it reproduces the
/// `formatted_body`. Messages from rich-text editors (Element X) have a
/// plain `body`, so their HTML is converted back to composer markdown.
/// Anything unexpected falls back to the plain body.
String composerTextForEdit(ChatEntry entry) {
  final html = entry.formattedBody;
  if (html == null || html.trim().isEmpty || html.length > 65536) {
    return entry.body;
  }
  try {
    final own = markdownToMatrixHtml(entry.body);
    if (own != null && _sameHtml(own, html)) return entry.body;
    final markdown = htmlToComposerMarkdown(html).trim();
    return markdown.isEmpty ? entry.body : markdown;
  } catch (_) {
    return entry.body;
  }
}

bool _sameHtml(String a, String b) {
  String normalise(String html) => html_parser
      .parseFragment(html)
      .outerHtml
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return normalise(a) == normalise(b);
}

final _escapable = RegExp(r'([\\`*_\[\]~|])');
final _userPermalink = RegExp(r'^https://matrix\.to/#/(@[^/?]+)');

/// Converts Matrix HTML (`formatted_body`) to composer markdown. Unknown
/// tags keep their text; replies (`mx-reply`) are dropped.
String htmlToComposerMarkdown(String html) {
  final fragment = html_parser.parseFragment(html);
  final buffer = StringBuffer();
  _blocks(fragment.nodes, buffer, prefix: '');
  return buffer
      .toString()
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n');
}

void _blocks(List<dom.Node> nodes, StringBuffer out, {required String prefix}) {
  final inline = StringBuffer();
  void flush() {
    final text = inline.toString();
    inline.clear();
    if (text.trim().isEmpty) return;
    _writeLines(out, text.trim(), prefix);
    out.write('\n');
  }

  for (final node in nodes) {
    if (node is dom.Element && _isBlock(node.localName)) {
      flush();
      _block(node, out, prefix: prefix);
    } else {
      _inline(node, inline);
    }
  }
  flush();
}

bool _isBlock(String? tag) => const {
  'p',
  'div',
  'blockquote',
  'ul',
  'ol',
  'pre',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'table',
  'mx-reply',
}.contains(tag);

void _writeLines(StringBuffer out, String text, String prefix) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (i > 0) out.write('\n');
    out.write(lines[i].isEmpty ? prefix.trimRight() : '$prefix${lines[i]}');
  }
}

void _block(dom.Element element, StringBuffer out, {required String prefix}) {
  switch (element.localName) {
    case 'mx-reply':
      return;
    case 'blockquote':
      final inner = StringBuffer();
      _blocks(element.nodes, inner, prefix: '');
      _writeLines(out, inner.toString().trimRight(), '$prefix> ');
      out.write('\n\n');
    case 'ul' || 'ol':
      final ordered = element.localName == 'ol';
      var number = int.tryParse(element.attributes['start'] ?? '') ?? 1;
      for (final item in element.children) {
        if (item.localName != 'li') continue;
        final marker = ordered ? '${number++}. ' : '- ';
        final inner = StringBuffer();
        _blocks(item.nodes, inner, prefix: '');
        final lines = inner.toString().trimRight().split('\n')
          ..removeWhere((line) => line.trim().isEmpty);
        if (lines.isEmpty) lines.add('');
        out.write('$prefix$marker${lines.first}\n');
        for (final line in lines.skip(1)) {
          out.write('$prefix${' ' * marker.length}$line\n');
        }
      }
      out.write('\n');
    case 'pre':
      final code = element.text.replaceAll(RegExp(r'\n$'), '');
      var fence = '```';
      while (code.contains(fence)) {
        fence += '`';
      }
      _writeLines(out, '$fence\n$code\n$fence', prefix);
      out.write('\n\n');
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
      final inner = StringBuffer();
      for (final child in element.nodes) {
        _inline(child, inner);
      }
      final level = int.parse(element.localName!.substring(1));
      out.write('$prefix${'#' * level} ${inner.toString().trim()}\n\n');
    case 'hr':
      out.write('$prefix---\n\n');
    default: // p, div, table …
      final inner = StringBuffer();
      _blocks(element.nodes, inner, prefix: prefix);
      out
        ..write(inner.toString().trimRight())
        ..write('\n\n');
  }
}

String _wrap(dom.Element element, String open, [String? close]) {
  final inner = StringBuffer();
  for (final child in element.nodes) {
    _inline(child, inner);
  }
  final text = inner.toString();
  if (text.trim().isEmpty) return text;
  // Markers must hug the text: keep surrounding spaces outside them.
  final leading = text.substring(0, text.length - text.trimLeft().length);
  final trailing = text.substring(text.trimRight().length);
  return '$leading$open${text.trim()}${close ?? open}$trailing';
}

void _inline(dom.Node node, StringBuffer out) {
  if (node is dom.Text) {
    out.write(
      node.text
          .replaceAll(RegExp(r'\s*\n\s*'), ' ')
          .replaceAllMapped(_escapable, (m) => '\\${m[1]}'),
    );
    return;
  }
  if (node is! dom.Element) return;
  switch (node.localName) {
    case 'br':
      out.write('\n');
    case 'strong' || 'b':
      out.write(_wrap(node, '**'));
    case 'em' || 'i':
      out.write(_wrap(node, '*'));
    case 'u' || 'ins':
      out.write(_wrap(node, '<u>', '</u>'));
    case 'del' || 's' || 'strike':
      out.write(_wrap(node, '~~'));
    case 'code':
      final code = node.text;
      var fence = '`';
      while (code.contains(fence)) {
        fence += '`';
      }
      final pad = code.startsWith('`') || code.endsWith('`') ? ' ' : '';
      out.write('$fence$pad$code$pad$fence');
    case 'span' when node.attributes.containsKey('data-mx-spoiler'):
      out.write(_wrap(node, '||'));
    case 'a':
      final href = node.attributes['href'] ?? '';
      final user = _userPermalink.firstMatch(href);
      final text = node.text;
      if (user != null) {
        // The composer turns bare user IDs back into pills on send.
        out.write(Uri.decodeComponent(user[1]!));
      } else if (href.isEmpty || href == text) {
        out.write(text);
      } else {
        final label = StringBuffer();
        for (final child in node.nodes) {
          _inline(child, label);
        }
        out.write(
          '[${label.toString()}](${href.replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29')})',
        );
      }
    case 'img':
      out.write(node.attributes['alt'] ?? node.attributes['title'] ?? '');
    case 'mx-reply':
      return;
    default:
      for (final child in node.nodes) {
        _inline(child, out);
      }
  }
}
