import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'location_model.dart';
import 'matrix_polls.dart';
import 'poll_model.dart';

/// Load state of a poll's related events (responses, ends, edits).
enum PollLoadState { loading, ready, failed }

/// Relations known for one poll start event.
@immutable
class PollSnapshot {
  const PollSnapshot({required this.state, this.relations = const []});

  final PollLoadState state;
  final List<PollRelation> relations;
}

/// Poll operations for the polls module. The live Matrix implementation is
/// [MatrixPolls]; tests implement this directly on a fake backend.
abstract interface class PollFeatures {
  /// Notifies when any poll snapshot changes.
  Listenable get pollUpdates;

  /// Relations known for [pollId], or null if never requested.
  PollSnapshot? pollSnapshot(String roomId, String pollId);

  /// Starts loading [pollId]'s relations once (idempotent; never notifies
  /// synchronously, so it is safe to call from `initState`/`build`).
  /// [retry] reloads after a failure.
  void ensurePollLoaded(String roomId, String pollId, {bool retry = false});

  /// Whether [userId] may end [pollSenderId]'s poll: the creator, or anyone
  /// with redaction power in the room (MSC3381).
  bool mayEndPoll(String roomId, String userId, String pollSenderId);

  Future<String> createPoll(String roomId, PollStart poll);
  Future<String> editPoll(String roomId, String pollId, PollStart poll);
  Future<String> respondToPoll(
    String roomId,
    String pollId,
    List<String> answerIds,
  );
  Future<String> endPoll(String roomId, String pollId);

  /// Redacts the poll (Element X "Delete Poll" while editing).
  Future<void> deletePoll(String roomId, String pollId);
}

/// Static location sharing for the polls/location module.
abstract interface class LocationFeatures {
  Future<String> shareLocation(
    String roomId,
    GeoPoint point, {
    required LocationAsset asset,
    String? description,
  });
}

final Expando<MatrixPolls> _matrixPolls = Expando('parallax.polls');

MatrixPolls? _matrixPollsFor(ChatBackend backend) {
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _matrixPolls[backend] ??= MatrixPolls(
      backend as MatrixSdkAccess,
      backend as RoomEventFeatures,
    );
  }
  return null;
}

/// Poll operations for [backend], or null when unsupported.
PollFeatures? pollFeaturesOf(ChatBackend backend) => backend is PollFeatures
    ? backend as PollFeatures
    : _matrixPollsFor(backend);

/// Location sharing for [backend], or null when unsupported.
LocationFeatures? locationFeaturesOf(ChatBackend backend) =>
    backend is LocationFeatures
    ? backend as LocationFeatures
    : _matrixPollsFor(backend);

/// Tallies [entry]-style poll data using [features] for relations and end
/// permissions. Returns null when the content is not a valid poll.
PollResults? pollResultsFor({
  required PollFeatures features,
  required String roomId,
  required String pollId,
  required String pollSender,
  required Map<String, Object?> content,
  required String? myUserId,
}) {
  final original = PollStart.fromContent(content);
  if (original == null) return null;
  final snapshot = features.pollSnapshot(roomId, pollId);
  return computePollResults(
    original: original,
    pollSender: pollSender,
    relations: snapshot?.relations ?? const [],
    myUserId: myUserId,
    mayEnd: (user) => features.mayEndPoll(roomId, user, pollSender),
  );
}
