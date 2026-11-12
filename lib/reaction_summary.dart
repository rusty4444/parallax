import 'chat_backend.dart';

/// Private marker inside the ciphertext of an encrypted reaction.
const encryptedReactionMarker = 'net.samrussell.parallax.encrypted_reaction';

/// Content for an `m.reaction` annotation of [eventId] with [key].
///
/// Matrix SDK 14.1's `encryptGroupMessagePayload` returns a payload that holds
/// nothing but `m.relates_to` unencrypted, so a plain reaction in an encrypted
/// room would leave as a plaintext `m.reaction` (which the final send guard
/// rightly refuses). For encrypted rooms a small marker keeps the payload
/// non-empty, so the SDK encrypts it as `m.room.encrypted` and, as the Matrix
/// spec requires, copies `m.relates_to` (target and key) to the cleartext
/// envelope. That is the same server-visible shape as an Element X reaction;
/// receiving SDKs restore the relation into the decrypted content.
Map<String, Object?> reactionEventContent(
  String eventId,
  String key, {
  required bool encrypted,
}) => {
  'm.relates_to': {'rel_type': 'm.annotation', 'event_id': eventId, 'key': key},
  if (encrypted) encryptedReactionMarker: true,
};

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
