import 'chat_backend.dart';

class ReactionVote {
  const ReactionVote(this.emoji, this.sender);
  final String emoji;
  final String sender;
}

/// Matrix can contain repeated reactions from one sender. Count each sender
/// once per emoji so a duplicate event does not inflate the visible total.
List<ChatReaction> summarizeReactions(
  Iterable<ReactionVote> votes,
  String? ownUserId,
) {
  final senders = <String, Set<String>>{};
  for (final vote in votes) {
    if (vote.emoji.isEmpty || vote.sender.isEmpty) continue;
    senders.putIfAbsent(vote.emoji, () => <String>{}).add(vote.sender);
  }
  final summaries = [
    for (final entry in senders.entries)
      ChatReaction(
        emoji: entry.key,
        count: entry.value.length,
        mine: ownUserId != null && entry.value.contains(ownUserId),
      ),
  ];
  summaries.sort((a, b) {
    final count = b.count.compareTo(a.count);
    return count == 0 ? a.emoji.compareTo(b.emoji) : count;
  });
  return List.unmodifiable(summaries);
}
