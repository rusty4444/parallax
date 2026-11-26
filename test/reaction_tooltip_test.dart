import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/reaction_summary.dart';
import 'package:parallax/timeline/reaction_pills.dart';

const _me = '@me:example.org';

ChatReactionSender _s(String id, [String? name]) =>
    ChatReactionSender(userId: id, name: name);

void main() {
  group('reaction hover text names who reacted', () {
    String tip(
      ChatReaction reaction, {
      String key = '👍',
      String suffix = '',
    }) => reactionSendersTooltip(reaction, key, ownUserId: _me, suffix: suffix);

    test('one, two and three people', () {
      expect(
        tip(
          ChatReaction(
            emoji: '👍',
            count: 1,
            mine: false,
            senders: [_s('@alice:example.org', 'Alice')],
          ),
        ),
        'Alice reacted with 👍',
      );
      expect(
        tip(
          ChatReaction(
            emoji: '👍',
            count: 2,
            mine: false,
            senders: [
              _s('@alice:example.org', 'Alice'),
              _s('@bob:example.org', 'Bob'),
            ],
          ),
        ),
        'Alice and Bob reacted with 👍',
      );
      expect(
        tip(
          ChatReaction(
            emoji: '👍',
            count: 3,
            mine: false,
            senders: [
              _s('@alice:example.org', 'Alice'),
              _s('@bob:example.org', 'Bob'),
              _s('@carol:example.org', 'Carol'),
            ],
          ),
        ),
        'Alice, Bob and Carol reacted with 👍',
      );
    });

    test('own reaction reads "You" and comes first', () {
      expect(
        tip(
          ChatReaction(
            emoji: '👍',
            count: 2,
            mine: true,
            senders: [_s('@alice:example.org', 'Alice'), _s(_me, 'Sam')],
          ),
        ),
        'You and Alice reacted with 👍',
      );
      expect(
        tip(
          ChatReaction(emoji: '👍', count: 1, mine: true, senders: [_s(_me)]),
        ),
        'You reacted with 👍',
      );
    });

    test('falls back to the user ID when no name is cached', () {
      expect(
        tip(
          ChatReaction(
            emoji: '👍',
            count: 1,
            mine: false,
            senders: [_s('@alice:example.org')],
          ),
        ),
        '@alice:example.org reacted with 👍',
      );
    });

    test('long lists stop at six names and count the rest', () {
      final senders = [
        for (var i = 1; i <= 9; i++) _s('@u$i:example.org', 'User $i'),
      ];
      expect(
        tip(ChatReaction(emoji: '👍', count: 9, mine: false, senders: senders)),
        'User 1, User 2, User 3, User 4, User 5, User 6 and 3 others '
        'reacted with 👍',
      );
    });

    test('without sender details the count still matches the pill', () {
      expect(
        tip(const ChatReaction(emoji: '👍', count: 1, mine: false)),
        '1 person reacted with 👍',
      );
      expect(
        tip(const ChatReaction(emoji: '👍', count: 4, mine: false)),
        '4 people reacted with 👍',
      );
      expect(
        tip(const ChatReaction(emoji: '👍', count: 2, mine: true)),
        'You and 1 other reacted with 👍',
      );
    });

    test('custom emoji shortcode and gallery photo suffix', () {
      expect(
        tip(
          ChatReaction(
            emoji: 'mxc://example.org/koala',
            count: 1,
            mine: false,
            senders: [_s('@alice:example.org', 'Alice')],
          ),
          key: ':koala:',
          suffix: ' to photo 2',
        ),
        'Alice reacted with :koala: to photo 2',
      );
    });
  });

  test('summaries keep each sender once, named, earliest first', () {
    final t = DateTime.utc(2026, 11, 26, 9);
    final result = summarizeReactions([
      ReactionVote(
        '👍',
        '@bob:example.org',
        name: 'Bob',
        time: t.add(const Duration(minutes: 2)),
      ),
      ReactionVote('👍', '@alice:example.org', time: t),
      // A duplicate vote can carry the name the first one lacked.
      ReactionVote(
        '👍',
        '@alice:example.org',
        name: 'Alice',
        time: t.add(const Duration(minutes: 5)),
      ),
      ReactionVote(
        '👍',
        _me,
        name: 'Sam',
        time: t.add(const Duration(minutes: 1)),
      ),
    ], _me);
    final reaction = result.single;
    expect(reaction.count, 3);
    expect(reaction.mine, isTrue);
    expect(reaction.senders.map((s) => s.userId), [
      '@alice:example.org',
      _me,
      '@bob:example.org',
    ]);
    expect(reaction.senders.map((s) => s.label), ['Alice', 'Sam', 'Bob']);
    expect(
      reactionSendersTooltip(reaction, '👍', ownUserId: _me),
      'You, Alice and Bob reacted with 👍',
    );
  });
}
