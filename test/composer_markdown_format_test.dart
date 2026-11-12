import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/composer/markdown_format.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';

/// `|` marks a caret, `[` … `]` a selection.
TextEditingValue v(String marked) {
  final caret = marked.indexOf('|');
  if (caret >= 0) {
    return TextEditingValue(
      text: marked.replaceFirst('|', ''),
      selection: TextSelection.collapsed(offset: caret),
    );
  }
  final start = marked.indexOf('[');
  final end = marked.indexOf(']', start) - 1;
  return TextEditingValue(
    text: marked.replaceFirst('[', '').replaceFirst(']', ''),
    selection: TextSelection(baseOffset: start, extentOffset: end),
  );
}

String show(TextEditingValue value) {
  final s = value.selection;
  final text = value.text;
  if (s.isCollapsed) return text.replaceRange(s.start, s.start, '|');
  return text
      .replaceRange(s.end, s.end, ']')
      .replaceRange(s.start, s.start, '[');
}

String fmt(String marked, FormatAction action) =>
    show(applyFormat(v(marked), action));

/// Selection markers here use `⟦ ⟧` so `[`/`]` in markdown links stay text.
TextEditingValue sel(String marked) {
  final start = marked.indexOf('⟦');
  final end = marked.indexOf('⟧') - 1;
  return TextEditingValue(
    text: marked.replaceFirst('⟦', '').replaceFirst('⟧', ''),
    selection: TextSelection(baseOffset: start, extentOffset: end),
  );
}

String? html(String text) =>
    composeTextMessage(text)['formatted_body'] as String?;

void main() {
  group('inline toolbar formats', () {
    test('wrap and unwrap a selection', () {
      expect(fmt('hello [world]', FormatAction.bold), 'hello **[world]**');
      expect(fmt('hello **[world]**', FormatAction.bold), 'hello [world]');
      expect(fmt('hello [**world**]', FormatAction.bold), 'hello [world]');
      expect(fmt('hello [world]', FormatAction.italic), 'hello *[world]*');
      expect(fmt('hello *[world]*', FormatAction.italic), 'hello [world]');
      expect(
        fmt('hello [world]', FormatAction.underline),
        'hello <u>[world]</u>',
      );
      expect(
        fmt('hello <u>[world]</u>', FormatAction.underline),
        'hello [world]',
      );
      expect(
        fmt('hello [world]', FormatAction.strikethrough),
        'hello ~~[world]~~',
      );
      expect(fmt('hello [world]', FormatAction.inlineCode), 'hello `[world]`');
      expect(fmt('hello `[world]`', FormatAction.inlineCode), 'hello [world]');
    });

    test('caret inserts markers, steps out and removes empty markers', () {
      expect(fmt('hello |', FormatAction.bold), 'hello **|**');
      expect(fmt('hello **|**', FormatAction.bold), 'hello |');
      expect(fmt('a **bold|** b', FormatAction.bold), 'a **bold**| b');
      expect(fmt('a **bo|ld** b', FormatAction.bold), 'a bo|ld b');
      expect(fmt('x |', FormatAction.underline), 'x <u>|</u>');
      expect(fmt('x |', FormatAction.inlineCode), 'x `|`');
    });

    test('trims whitespace and merges nested markers of the same format', () {
      expect(fmt('say [ hi ] now', FormatAction.bold), 'say  **[hi]**  now');
      expect(fmt('[a **b** c]', FormatAction.bold), '**[a b c]**');
    });

    test('inline code fences around backticks', () {
      expect(fmt('x [a`b] y', FormatAction.inlineCode), 'x ``[a`b]`` y');
    });

    test('multi-line selections format each line', () {
      expect(fmt('[one\ntwo]', FormatAction.italic), '*[one*\n*two]*');
      expect(fmt('[**one**\n**two**]', FormatAction.bold), '[one\ntwo]');
      expect(
        fmt('[- one\n- two]', FormatAction.bold),
        '- **[one**\n- **two]**',
      );
    });

    test('inline formats are disabled inside code blocks', () {
      final value = v('```\nco|de\n```');
      expect(applyFormat(value, FormatAction.bold), value);
      final state = formattingStateFor(value);
      expect(state.active, contains(FormatAction.codeBlock));
      expect(state.disabled, contains(FormatAction.bold));
      expect(state.disabled, isNot(contains(FormatAction.codeBlock)));
    });
  });

  group('block toolbar formats', () {
    test('bullet and numbered lists toggle and switch', () {
      expect(fmt('hello|', FormatAction.bulletList), '- hello|');
      expect(fmt('[one\ntwo]', FormatAction.bulletList), '- [one\n- two]');
      expect(fmt('- one\n- tw|o', FormatAction.bulletList), '- one\ntw|o');
      expect(fmt('[a\nb\nc]', FormatAction.numberedList), '1. [a\n2. b\n3. c]');
      expect(fmt('[- a\n- b]', FormatAction.numberedList), '[1. a\n2. b]');
      expect(fmt('1. a|', FormatAction.numberedList), 'a|');
      expect(fmt('|', FormatAction.bulletList), '- |');
    });

    test('quote toggles every selected line', () {
      expect(fmt('hi|', FormatAction.quote), '> hi|');
      expect(fmt('> hi|', FormatAction.quote), 'hi|');
      expect(fmt('[a\n\nb]', FormatAction.quote), '> [a\n>\n> b]');
      expect(fmt('[> a\n> b]', FormatAction.quote), '[a\nb]');
    });

    test('code block wraps lines and removes its fences', () {
      expect(fmt('[a\nb]', FormatAction.codeBlock), '```\n[a\nb]\n```');
      expect(fmt('|', FormatAction.codeBlock), '```\n|\n```');
      expect(fmt('```\na|\n```', FormatAction.codeBlock), 'a|');
      expect(
        fmt('x\n```\na|\nb\n```\ny', FormatAction.codeBlock),
        'x\na|\nb\ny',
      );
    });

    test('indent and unindent nest list items', () {
      expect(fmt('- a\n- b|', FormatAction.indent), '- a\n  - b|');
      expect(fmt('- a\n  - b|', FormatAction.unindent), '- a\n- b|');
      expect(fmt('1. a\n2. b|', FormatAction.indent), '1. a\n   1. b|');
      expect(
        fmt('1. a\n   1. b\n2. c|', FormatAction.indent),
        '1. a\n   1. b\n   2. c|',
      );
      expect(fmt('1. a\n   1. b|', FormatAction.unindent), '1. a\n2. b|');
    });

    test('indent state follows the list', () {
      expect(
        formattingStateFor(v('- a|')).disabled,
        containsAll([FormatAction.indent, FormatAction.unindent]),
      );
      expect(
        formattingStateFor(v('- a\n- b|')).disabled,
        isNot(contains(FormatAction.indent)),
      );
      expect(
        formattingStateFor(v('- a\n  - b|')).disabled,
        isNot(contains(FormatAction.unindent)),
      );
      expect(
        formattingStateFor(v('plain|')).disabled,
        containsAll([FormatAction.indent, FormatAction.unindent]),
      );
    });
  });

  group('active state at the caret', () {
    test('reports inline and block formats', () {
      expect(
        formattingStateFor(v('**bo|ld**')).active,
        contains(FormatAction.bold),
      );
      expect(
        formattingStateFor(v('**bold**|')).active,
        isNot(contains(FormatAction.bold)),
      );
      expect(
        formattingStateFor(v('***b|i***')).active,
        containsAll([FormatAction.bold, FormatAction.italic]),
      );
      expect(
        formattingStateFor(v('- item|')).active,
        contains(FormatAction.bulletList),
      );
      expect(
        formattingStateFor(v('2. item|')).active,
        contains(FormatAction.numberedList),
      );
      expect(
        formattingStateFor(v('> quoted|')).active,
        contains(FormatAction.quote),
      );
      expect(
        formattingStateFor(
          sel('see [do|cs](https://x.org)'.replaceFirst('|', '⟦⟧')),
        ).active,
        contains(FormatAction.link),
      );
      final code = formattingStateFor(v('`co|de`'));
      expect(code.active, contains(FormatAction.inlineCode));
      expect(code.disabled, contains(FormatAction.bold));
    });

    test('selections are active only when every line is covered', () {
      expect(
        formattingStateFor(v('[**a**\n**b**]')).active,
        contains(FormatAction.bold),
      );
      expect(
        formattingStateFor(v('[**a**\nb]')).active,
        isNot(contains(FormatAction.bold)),
      );
    });
  });

  group('scanner', () {
    test('ignores markers in code, escapes and URLs', () {
      final spans = scanMarkdown(r'`**x**` \*y\* https://a.org/b_c_d').spans;
      expect(spans.where((s) => s.format == InlineFormat.bold), isEmpty);
      expect(spans.where((s) => s.format == InlineFormat.italic), isEmpty);
      expect(
        spans.singleWhere((s) => s.format == InlineFormat.autolink).url,
        'https://a.org/b_c_d',
      );
    });

    test('classifies lines', () {
      final lines = scanMarkdown('- a\n1. b\n> c\n```\n- d\n```\ne').lines;
      expect(
        [for (final l in lines) l.kind],
        [
          LineKind.bullet,
          LineKind.numbered,
          LineKind.quote,
          LineKind.fence,
          LineKind.code,
          LineKind.fence,
          LineKind.text,
        ],
      );
    });
  });

  group('links', () {
    test('validates http, https and mailto only', () {
      expect(normaliseLinkUrl('example.com'), 'https://example.com');
      expect(
        normaliseLinkUrl(' https://example.com/a?b=c '),
        'https://example.com/a?b=c',
      );
      expect(normaliseLinkUrl('http://example.com'), 'http://example.com');
      expect(normaliseLinkUrl('mailto:a@b.co'), 'mailto:a@b.co');
      expect(normaliseLinkUrl('a@b.co'), 'mailto:a@b.co');
      expect(normaliseLinkUrl('javascript:alert(1)'), isNull);
      expect(normaliseLinkUrl('ftp://example.com'), isNull);
      expect(normaliseLinkUrl('https://'), isNull);
      expect(normaliseLinkUrl('https://exa mple.com'), isNull);
      expect(normaliseLinkUrl('mailto:nobody'), isNull);
      expect(normaliseLinkUrl(''), isNull);
      expect(normaliseLinkUrl('word'), isNull);
    });

    test('inserts, edits and removes links', () {
      final created = applyLink(
        sel('see ⟦docs⟧ now'),
        text: 'docs',
        url: 'https://example.com',
      );
      expect(show(created), 'see [docs](https://example.com)| now');
      final target = linkTargetAt(
        created.copyWith(selection: const TextSelection.collapsed(offset: 6)),
      );
      expect(target.text, 'docs');
      expect(target.url, 'https://example.com');
      expect(target.span, isNotNull);
      final edited = applyLink(
        created.copyWith(selection: const TextSelection.collapsed(offset: 6)),
        text: 'the docs',
        url: 'https://example.org/a b',
      );
      expect(edited.text, 'see [the docs](https://example.org/a%20b) now');
      final removed = removeLink(
        edited.copyWith(selection: const TextSelection.collapsed(offset: 6)),
      );
      expect(show(removed), 'see the docs| now');
    });

    test('escapes brackets in link text', () {
      expect(
        linkMarkdown('a [b]', 'https://x.org/(y)'),
        r'[a \[b\]](https://x.org/%28y%29)',
      );
    });
  });

  group('list continuation', () {
    TextEditingValue? enter(String marked) {
      final before = v(marked);
      final caret = before.selection.start;
      final after = TextEditingValue(
        text: before.text.replaceRange(caret, caret, '\n'),
        selection: TextSelection.collapsed(offset: caret + 1),
      );
      return continueListOnNewline(before, after);
    }

    test('continues and ends lists and quotes', () {
      expect(show(enter('- a|')!), '- a\n- |');
      expect(show(enter('  * a|')!), '  * a\n  * |');
      expect(show(enter('1. a|')!), '1. a\n2. |');
      expect(show(enter('1. a\n2. b|\n3. c')!), '1. a\n2. b\n3. |\n4. c');
      expect(show(enter('> q|')!), '> q\n> |');
      expect(show(enter('- |')!), '|');
      expect(show(enter('a\n- |')!), 'a\n|');
      expect(enter('- a|b'), isNull);
      expect(enter('plain|'), isNull);
    });
  });

  group('markdown → Matrix HTML round trips', () {
    String apply(String marked, FormatAction action) =>
        applyFormat(v(marked), action).text;

    test('inline toolbar formats', () {
      expect(
        html(apply('hello [world]', FormatAction.bold)),
        'hello <strong>world</strong>',
      );
      expect(
        html(apply('hello [world]', FormatAction.italic)),
        'hello <em>world</em>',
      );
      expect(
        html(apply('hello [world]', FormatAction.underline)),
        'hello <u>world</u>',
      );
      expect(
        html(apply('hello [world]', FormatAction.strikethrough)),
        'hello <del>world</del>',
      );
      expect(
        html(apply('hello [world]', FormatAction.inlineCode)),
        'hello <code>world</code>',
      );
      final link = applyLink(
        sel('hello ⟦world⟧'),
        text: 'world',
        url: 'https://example.com',
      ).text;
      expect(html(link), 'hello <a href="https://example.com">world</a>');
      final mail = applyLink(
        sel('⟦mail me⟧'),
        text: 'mail me',
        url: 'mailto:a@b.co',
      ).text;
      expect(html(mail), '<a href="mailto:a@b.co">mail me</a>');
    });

    test('block toolbar formats', () {
      expect(
        html(apply('[one\ntwo]', FormatAction.bulletList)),
        '<ul><li>one</li><li>two</li></ul>',
      );
      expect(
        html(apply('[one\ntwo]', FormatAction.numberedList)),
        '<ol><li>one</li><li>two</li></ol>',
      );
      expect(
        html(apply('[one\ntwo]', FormatAction.quote)),
        '<blockquote><p>one<br/>two</p></blockquote>',
      );
      expect(
        html(apply('[one\ntwo]', FormatAction.codeBlock)),
        '<pre><code>one\ntwo\n</code></pre>',
      );
      expect(
        html(apply('- one\n- two|', FormatAction.indent)),
        '<ul><li>one<ul><li>two</li></ul></li></ul>',
      );
      expect(
        html(apply('1. one\n2. two|', FormatAction.indent)),
        '<ol><li>one<ol><li>two</li></ol></li></ol>',
      );
    });

    test(
      'underline survives combined formatting and stays literal in code',
      () {
        expect(html('<u>**both**</u>'), '<u><strong>both</strong></u>');
        expect(html('**<u>both</u>**'), '<strong><u>both</u></strong>');
        expect(
          html('<u>a **b</u> c**'),
          '<u>a <strong>b</strong></u><strong> c</strong>',
        );
        expect(html('`<u>x</u>`'), isNot(contains('<u>')));
        expect(html('```\n<u>x</u>\n```'), isNot(contains('<u>')));
        expect(html('<u>unclosed'), isNot(contains('<u>')));
        expect(html('<b>no</b>'), isNull);
        final content = composeTextMessage('hi <u>there</u>');
        expect(content['body'], 'hi <u>there</u>');
        expect(content['formatted_body'], 'hi <u>there</u>');
      },
    );

    test('edits keep the formatted replacement', () {
      final content = composeTextMessage('**new**', editEventId: r'$e');
      expect(content['formatted_body'], '* <strong>new</strong>');
      expect(
        (content['m.new_content'] as Map)['formatted_body'],
        '<strong>new</strong>',
      );
    });
  });
}
