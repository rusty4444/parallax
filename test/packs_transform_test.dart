import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/packs/emoticon_transform.dart';
import 'package:parallax/features/packs/pack_model.dart';
import 'package:parallax/features/packs/packs_hooks.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';
import 'package:parallax/hooks/hook_types.dart';

import 'packs_fakes.dart';

const _wave =
    '<img data-mx-emoticon src="mxc://example.org/wave" alt=":wave:" '
    'title=":wave:" height="32" />';
const _roo =
    '<img data-mx-emoticon src="mxc://example.org/roo" alt=":roo:" '
    'title=":roo:" height="32" />';

AvailablePacks _packs() => mergeAvailablePacks(
  personal: pack([packImage('wave', 'wave'), packImage('roo', 'roo')]),
  roomPacks: [
    RoomPackState(
      ref: const PackRef.room(packsRoomId, 'extra'),
      pack: pack([packImage('wave', 'other-wave')]),
      roomName: 'Room',
    ),
    RoomPackState(
      ref: const PackRef.room(packsRoomId, 'stickers'),
      pack: pack([packImage('big', 'big')], usage: const ['sticker']),
      roomName: 'Room',
    ),
  ],
);

void main() {
  group('outgoing transform', () {
    test('builds formatted_body from the escaped body; body keeps codes', () {
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': 'Hi <b>&</b> :wave:\nbye :roo:',
      }, _packs());
      expect(out['body'], 'Hi <b>&</b> :wave:\nbye :roo:');
      expect(out['format'], 'org.matrix.custom.html');
      expect(
        out['formatted_body'],
        'Hi &lt;b&gt;&amp;&lt;/b&gt; $_wave<br />bye $_roo',
      );
    });

    test('replaces every occurrence, including adjacent ones', () {
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': ':wave::wave: :roo:',
      }, _packs());
      expect(out['formatted_body'], '$_wave$_wave $_roo');
    });

    test('unknown codes and sticker-only images stay untouched', () {
      final content = {'msgtype': 'm.text', 'body': 'at 10:30:45 :nope: :big:'};
      expect(
        identical(transformOutgoingEmoticons(content, _packs()), content),
        isTrue,
      );
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': ':nope:wave: and :x:roo:',
      }, _packs());
      // ":nope:" is unknown, so its closing colon can start ":wave:".
      expect(out['formatted_body'], ':nope$_wave and :x$_roo');
    });

    test('slug~code selects a shadowed image', () {
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': ':extra~wave:',
      }, _packs());
      expect(
        out['formatted_body'],
        '<img data-mx-emoticon src="mxc://example.org/other-wave" '
        'alt=":wave:" title=":wave:" height="32" />',
      );
    });

    test('keeps markup; skips code, pre, links and reply fallbacks', () {
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': 'x',
        'format': 'org.matrix.custom.html',
        'formatted_body':
            '<p><strong>:wave:</strong> <code>:wave:</code></p>'
            '<pre><code>:roo:</code></pre>'
            '<a href="https://matrix.to/#/@roo:example.org">:roo:</a>'
            '<mx-reply>:wave:</mx-reply><br/>:roo:',
      }, _packs());
      expect(
        out['formatted_body'],
        '<p><strong>$_wave</strong> <code>:wave:</code></p>'
        '<pre><code>:roo:</code></pre>'
        '<a href="https://matrix.to/#/@roo:example.org">:roo:</a>'
        '<mx-reply>:wave:</mx-reply><br/>$_roo',
      );
    });

    test('edits convert both the fallback and m.new_content', () {
      final content = composeTextMessage(
        'fixed :wave:',
        ownUserId: '@sam:example.org',
        editEventId: r'$original',
      );
      final out = transformOutgoingEmoticons(content, _packs());
      expect(out['body'], '* fixed :wave:');
      expect(out['formatted_body'], '* fixed $_wave');
      final replacement = out['m.new_content']! as Map<String, Object?>;
      expect(replacement['body'], 'fixed :wave:');
      expect(replacement['formatted_body'], 'fixed $_wave');
      expect(out['m.relates_to'], content['m.relates_to']);
    });

    test('works on markdown output and emotes; ignores other msgtypes', () {
      final markdown = composeTextMessage('**hi** :roo:');
      final out = transformOutgoingEmoticons(markdown, _packs());
      expect(out['formatted_body'], contains('<strong>hi</strong> $_roo'));

      final emote = transformOutgoingEmoticons({
        'msgtype': 'm.emote',
        'body': 'waves :wave:',
      }, _packs());
      expect(emote['formatted_body'], 'waves $_wave');

      final file = {'msgtype': 'm.file', 'body': ':wave:'};
      expect(
        identical(transformOutgoingEmoticons(file, _packs()), file),
        isTrue,
      );
    });

    test('bounds the number of images per message', () {
      final out = transformOutgoingEmoticons({
        'msgtype': 'm.text',
        'body': List.filled(maxEmoticonsPerMessage + 5, ':wave:').join(),
      }, _packs());
      final html = out['formatted_body']! as String;
      expect(
        'data-mx-emoticon'.allMatches(html),
        hasLength(maxEmoticonsPerMessage),
      );
      expect(html, endsWith(':wave::wave::wave::wave::wave:'));
    });

    test('no packs, no change', () {
      final content = {'msgtype': 'm.text', 'body': ':wave:'};
      expect(
        identical(
          transformOutgoingEmoticons(content, AvailablePacks.empty),
          content,
        ),
        isTrue,
      );
    });

    test('hook uses the backend packs and passes other backends through', () {
      final backend = FakePacksBackend()
        ..personal = pack([packImage('wave', 'wave')]);
      final out = packsTransformOutgoing(
        OutgoingTextContext(
          backend: backend,
          roomId: packsRoomId,
          text: ':wave:',
        ),
        {'msgtype': 'm.text', 'body': ':wave:'},
      );
      expect(out['formatted_body'], _wave);
    });
  });
}
