import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/composer/edit_markdown.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';

ChatEntry formatted(String body, String? html) => ChatEntry(
  id: r'$e',
  sender: '@me:example.org',
  body: body,
  time: DateTime(2026),
  mine: true,
  formattedBody: html,
);

void main() {
  test('markdown sources edit as typed', () {
    for (final body in [
      '**hi** there',
      '- one\n- two',
      '> quote',
      'see [docs](https://example.com)',
      'hi <u>there</u>',
    ]) {
      final html = composeTextMessage(body)['formatted_body'] as String?;
      expect(composerTextForEdit(formatted(body, html)), body);
    }
    expect(composerTextForEdit(formatted('plain', null)), 'plain');
  });

  test('rich-text (Element X) HTML converts back to markdown', () {
    String edit(String body, String html) =>
        composerTextForEdit(formatted(body, html));

    expect(edit('hi there', '<strong>hi</strong> there'), '**hi** there');
    expect(
      edit('a b c d', '<em>a</em> <u>b</u> <del>c</del> <code>d</code>'),
      '*a* <u>b</u> ~~c~~ `d`',
    );
    expect(
      edit('one\ntwo', '<ul><li>one</li><li>two</li></ul>'),
      '- one\n- two',
    );
    expect(
      edit(
        'one two three',
        '<ol><li>one<ol><li>two</li></ol></li><li>three</li></ol>',
      ),
      '1. one\n   1. two\n2. three',
    );
    expect(
      edit('quote two', '<blockquote><p>quote<br/>two</p></blockquote>'),
      '> quote\n> two',
    );
    expect(edit('a\nb', '<pre><code>a\nb\n</code></pre>'), '```\na\nb\n```');
    expect(
      edit('site', '<a href="https://example.com">site</a>'),
      '[site](https://example.com)',
    );
    expect(
      edit(
        'Bob: hi',
        '<a href="https://matrix.to/#/@bob:example.org">Bob</a>: hi',
      ),
      '@bob:example.org: hi',
    );
    expect(edit('secret', '<span data-mx-spoiler>secret</span>'), '||secret||');
    expect(edit('2*3', '<em>2*3</em>'), r'*2\*3*');
    expect(
      edit(
        'reply',
        '<mx-reply><blockquote>old</blockquote></mx-reply><strong>reply</strong>',
      ),
      '**reply**',
    );
  });

  test('converted markdown round-trips to equivalent HTML', () {
    for (final html in [
      '<strong>hi</strong> there',
      '<ul><li>one</li><li>two</li></ul>',
      '<ol><li>one<ol><li>two</li></ol></li><li>three</li></ol>',
      '<blockquote><p>quote<br/>two</p></blockquote>',
      '<a href="https://example.com">site</a>',
    ]) {
      final markdown = htmlToComposerMarkdown(html).trim();
      expect(markdownToMatrixHtml(markdown), html, reason: markdown);
    }
  });
}
