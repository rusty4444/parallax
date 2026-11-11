import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/message_text.dart';

void main() {
  test('strips SDK reply fallback and keeps the actual message', () {
    expect(
      visibleMessageBody(
        '> <@alice:example.org> original\n> another line\n\nMy reply',
        isReply: true,
      ),
      'My reply',
    );
  });

  test('preserves user quotes and malformed fallback', () {
    expect(
      visibleMessageBody(
        '> <@alice:example.org> quote\n\nMy text',
        isReply: false,
      ),
      '> <@alice:example.org> quote\n\nMy text',
    );
    expect(
      visibleMessageBody(
        '> <@alice:example.org> quote\nnot a quote\n\nText',
        isReply: true,
      ),
      '> <@alice:example.org> quote\nnot a quote\n\nText',
    );
  });
}
