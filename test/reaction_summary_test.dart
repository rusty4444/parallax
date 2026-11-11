import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/reaction_summary.dart';

void main() {
  test('groups emoji reactions by distinct sender and identifies my vote', () {
    final result = summarizeReactions(const [
      ReactionVote('❤️', '@me:example.org'),
      ReactionVote('❤️', '@me:example.org'),
      ReactionVote('❤️', '@alice:example.org'),
      ReactionVote('👍', '@alice:example.org'),
      ReactionVote('', '@nobody:example.org'),
    ], '@me:example.org');
    expect(result.map((r) => r.emoji), ['❤️', '👍']);
    expect(result.map((r) => r.count), [2, 1]);
    expect(result.map((r) => r.mine), [true, false]);
  });
}
