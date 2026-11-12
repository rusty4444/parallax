import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../matrix_room_features.dart';
import '../../room_events.dart';
import 'event_projection.dart';
import 'thread_models.dart';

/// Threads list, threaded read receipts and thread activity for a backend.
///
/// Thread replies themselves are still sent through
/// `MessagingFeatures.queueMessage(threadRootId: …)`, which keeps the outbox,
/// trust and encryption guards.
abstract interface class ThreadFeatures {
  /// One page of thread roots, most recent activity first.
  Future<ThreadListPage> loadThreads(
    String roomId, {
    ThreadListFilter filter = ThreadListFilter.all,
    String? nextBatch,
  });

  /// Sends a threaded read receipt for [eventId] (a reply in [rootId]).
  /// [public] false sends a private receipt only.
  Future<void> markThreadRead(
    String roomId,
    String rootId,
    String eventId, {
    required bool public,
  });

  /// Emits a thread root ID whenever a new reply arrives in [roomId].
  Stream<String> threadActivity(String roomId);
}

/// The homeserver does not offer the threads list endpoint (Matrix 1.4).
class ThreadListUnsupported implements Exception {
  const ThreadListUnsupported();
}

final _threads = Expando<ThreadFeatures>('threads');

/// Thread features for [backend], or null when the backend has none (for
/// example demonstration or test backends that do not implement them).
ThreadFeatures? threadFeaturesOf(ChatBackend backend) =>
    backend is ThreadFeatures
    ? backend as ThreadFeatures
    : backend is MatrixSdkAccess
    ? _threads[backend] ??= MatrixThreads(backend as MatrixSdkAccess)
    : null;

/// [ThreadFeatures] over the live Matrix SDK session.
class MatrixThreads implements ThreadFeatures {
  MatrixThreads(this._access);
  final MatrixSdkAccess _access;

  MatrixRoomFeatures _features() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      throw StateError('No signed-in Matrix session');
    }
    return MatrixRoomFeatures(
      client,
      ownerCurrent: () => _access.isSessionCurrent(client),
      mapEvent: projectStandaloneEvent,
    );
  }

  @override
  Future<ThreadListPage> loadThreads(
    String roomId, {
    ThreadListFilter filter = ThreadListFilter.all,
    String? nextBatch,
  }) async {
    try {
      return await _features().loadThreadRoots(
        roomId,
        filter: filter,
        nextBatch: nextBatch,
      );
    } on matrix.MatrixException catch (error) {
      if (error.errcode == 'M_UNRECOGNIZED' ||
          (error.response?.statusCode == 404 &&
              error.errcode != 'M_NOT_FOUND')) {
        throw const ThreadListUnsupported();
      }
      rethrow;
    }
  }

  @override
  Future<void> markThreadRead(
    String roomId,
    String rootId,
    String eventId, {
    required bool public,
  }) => _features().sendThreadReceipt(roomId, rootId, eventId, public: public);

  @override
  Stream<String> threadActivity(String roomId) {
    final client = _access.sdkClient;
    if (client == null) return const Stream<String>.empty();
    return client.onTimelineEvent.stream
        .where(
          (event) =>
              event.roomId == roomId &&
              _access.isSessionCurrent(client) &&
              event.relationshipType == matrix.RelationshipTypes.thread,
        )
        .map((event) => event.relationshipEventId)
        .where((root) => root != null && root.isNotEmpty)
        .cast<String>();
  }
}
