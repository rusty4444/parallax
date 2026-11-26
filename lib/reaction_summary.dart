import 'package:matrix/matrix.dart' as matrix;

import 'chat_backend.dart';

/// Reactions to [eventId] from the SDK aggregation and from the timeline
/// itself. The aggregation can lag behind a just-sent reaction (or a
/// fragmented timeline), so scanning the timeline events keeps the first
/// tap on your own reaction a removal instead of sending a duplicate.
Iterable<matrix.Event> reactionEventsFor(
  matrix.Timeline timeline,
  String eventId,
) {
  final seen = <String>{};
  final result = <matrix.Event>[];
  void add(matrix.Event event) {
    final key = event.eventId.isNotEmpty
        ? event.eventId
        : event.transactionId ?? '';
    if (key.isEmpty || !seen.add(key)) return;
    result.add(event);
  }

  final aggregated =
      timeline.aggregatedEvents[eventId]?[matrix.RelationshipTypes.reaction];
  if (aggregated != null) {
    for (final event in aggregated) {
      add(event);
    }
  }
  for (final event in timeline.events) {
    if (event.relationshipType == matrix.RelationshipTypes.reaction &&
        event.relationshipEventId == eventId) {
      add(event);
    }
  }
  return result;
}

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
  const ReactionVote(this.emoji, this.sender, {this.name, this.time});
  final String emoji;
  final String sender;

  /// The sender's display name from cached membership, if known.
  final String? name;
  final DateTime? time;
}

/// Matrix can contain repeated reactions from one sender. Count each sender
/// once per emoji so a duplicate event does not inflate the visible total.
/// Each summary lists its senders earliest first, for the hover text.
List<ChatReaction> summarizeReactions(
  Iterable<ReactionVote> votes,
  String? ownUserId,
) {
  // emoji -> sender -> (earliest time, a known name, arrival order)
  final senders =
      <String, Map<String, ({DateTime? time, String? name, int order})>>{};
  var order = 0;
  for (final vote in votes) {
    if (vote.emoji.isEmpty || vote.sender.isEmpty) continue;
    final bySender = senders.putIfAbsent(vote.emoji, () => {});
    final seen = bySender[vote.sender];
    final name = (vote.name?.trim().isNotEmpty ?? false) ? vote.name : null;
    if (seen == null) {
      bySender[vote.sender] = (time: vote.time, name: name, order: order++);
      continue;
    }
    final time = seen.time == null
        ? vote.time
        : vote.time != null && vote.time!.isBefore(seen.time!)
        ? vote.time
        : seen.time;
    bySender[vote.sender] = (
      time: time,
      name: seen.name ?? name,
      order: seen.order,
    );
  }
  List<ChatReactionSender> ordered(
    Map<String, ({DateTime? time, String? name, int order})> bySender,
  ) {
    final list = bySender.entries.toList()
      // Earliest first; unknown times after known ones; then arrival order.
      ..sort((a, b) {
        final at = a.value.time, bt = b.value.time;
        if (at == null || bt == null) {
          if (at != bt) return at == null ? 1 : -1;
        } else if (at != bt) {
          return at.compareTo(bt);
        }
        return a.value.order.compareTo(b.value.order);
      });
    return List.unmodifiable([
      for (final e in list)
        ChatReactionSender(userId: e.key, name: e.value.name),
    ]);
  }

  final summaries = [
    for (final entry in senders.entries)
      ChatReaction(
        emoji: entry.key,
        count: entry.value.length,
        mine: ownUserId != null && entry.value.containsKey(ownUserId),
        senders: ordered(entry.value),
      ),
  ];
  summaries.sort((a, b) {
    final count = b.count.compareTo(a.count);
    return count == 0 ? a.emoji.compareTo(b.emoji) : count;
  });
  return List.unmodifiable(summaries);
}
