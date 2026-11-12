import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/composer/slash_commands.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';
import 'package:parallax/hooks/registry.dart';

class _Backend extends ChatBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the Matrix backend sends for composer [text].
Map<String, Object?> send(String text, {bool editing = false}) =>
    transformOutgoingText(
      OutgoingTextContext(
        backend: _Backend(),
        roomId: '!r:example.org',
        text: text,
        editing: editing,
      ),
      composeTextMessage(text, editEventId: editing ? r'$edited' : null),
    );

void main() {
  test('parses commands, escapes and paths', () {
    final shrug = parseSlashCommand('/Shrug hello there')!;
    expect(shrug.name, 'shrug');
    expect(shrug.args, 'hello there');
    expect(parseSlashCommand('/confetti')!.args, '');
    expect(
      parseSlashCommand('/spoiler line one\nline two')!.args,
      'line one\nline two',
    );
    expect(parseSlashCommand('//not a command'), isNull);
    expect(parseSlashCommand('/usr/bin is a path'), isNull);
    expect(parseSlashCommand('hello /shrug'), isNull);
  });

  test('refuses unknown commands and empty spoilers in the composer', () {
    expect(
      slashCommandError('/foo bar'),
      contains('Unrecognised command: /foo'),
    );
    expect(slashCommandError('/spoiler  '), 'Usage: /spoiler <message>');
    expect(slashCommandError('/shrug'), isNull);
    expect(slashCommandError('/me waves'), isNull);
    expect(slashCommandError('//foo'), isNull);
    expect(slashCommandError('plain text'), isNull);
    expect(slashCommandError('/usr/bin'), isNull);
  });

  test('emoticon commands send plain text with the prefix', () {
    final shrug = send('/shrug **fine**');
    expect(shrug['msgtype'], 'm.text');
    expect(shrug['body'], r'¯\_(ツ)_/¯ **fine**');
    expect(shrug.containsKey('formatted_body'), isFalse);
    expect(send('/tableflip')['body'], '(╯°□°）╯︵ ┻━┻');
    expect(send('/unflip')['body'], '┬──┬ ノ( ゜-゜ノ)');
    expect(send('/lenny hi')['body'], '( ͡° ͜ʖ ͡°) hi');
  });

  test('/plain skips markdown, /spoiler wraps the HTML', () {
    final plain = send('/plain **not bold**');
    expect(plain['body'], '**not bold**');
    expect(plain.containsKey('format'), isFalse);
    expect(plain.containsKey('formatted_body'), isFalse);

    final spoiler = send('/spoiler the butler');
    expect(spoiler['body'], 'the butler');
    expect(spoiler['format'], 'org.matrix.custom.html');
    expect(
      spoiler['formatted_body'],
      '<span data-mx-spoiler>the butler</span>',
    );
    expect(
      send('/spoiler **x** <b>')['formatted_body'],
      '<span data-mx-spoiler><strong>x</strong> &lt;b&gt;</span>',
    );
    expect(
      send('/spoiler a<b')['formatted_body'],
      '<span data-mx-spoiler>a&lt;b</span>',
    );
  });

  test('effect commands set Element Web msgtypes and fallbacks', () {
    final confetti = send('/confetti Happy birthday!');
    expect(confetti['msgtype'], 'nic.custom.confetti');
    expect(confetti['body'], 'Happy birthday!');
    expect(confetti.containsKey('formatted_body'), isFalse);
    expect(
      send('/fireworks **wow**')['formatted_body'],
      '<strong>wow</strong>',
    );
    expect(send('/fireworks x')['msgtype'], 'nic.custom.fireworks');
    expect(send('/rainfall x')['msgtype'], 'io.element.effect.rainfall');
    expect(send('/snowfall x')['msgtype'], 'io.element.effect.snowfall');
    expect(
      send('/spaceinvaders x')['msgtype'],
      'io.element.effects.space_invaders',
    );
    expect(send('/hearts x')['msgtype'], 'io.element.effect.hearts');

    final bare = send('/confetti');
    expect(bare['msgtype'], 'm.emote');
    expect(bare['body'], 'sends confetti 🎉');
    expect(send('/snowfall')['body'], 'sends snowfall ❄');
  });

  test('keeps mentions, /me, escapes and edits', () {
    final mention = send('/shrug @bob:example.org');
    expect(mention['m.mentions'], {
      'user_ids': ['@bob:example.org'],
    });
    final me = send('/me waves');
    expect(me['msgtype'], 'm.emote');
    expect(me['body'], 'waves');
    final escaped = send('//shrug **x**');
    expect(escaped['body'], '/shrug **x**');
    expect(escaped['formatted_body'], '/shrug <strong>x</strong>');
    expect(send('//etc')['body'], '/etc');
    final edit = send('/shrug', editing: true);
    expect(edit['body'], '* /shrug');
    expect((edit['m.new_content'] as Map)['body'], '/shrug');
    expect(send('/unknown thing')['body'], '/unknown thing');
  });

  test('suggests commands by prefix', () {
    final all = slashCommandSuggestions('');
    expect(
      [for (final s in all) s.id],
      containsAll(<String>[
        '/me',
        '/shrug',
        '/tableflip',
        '/lenny',
        '/plain',
        '/spoiler',
        '/confetti',
        '/fireworks',
        '/rainfall',
        '/snowfall',
        '/spaceinvaders',
        '/hearts',
      ]),
    );
    final matches = slashCommandSuggestions('sp');
    expect([for (final s in matches) s.id], ['/spoiler', '/spaceinvaders']);
    expect(matches.first.insertText, '/spoiler ');
    expect(slashCommandSuggestions('zzz'), isEmpty);
    expect(slashCommandSource.trigger, '/');
  });
}
