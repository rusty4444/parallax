import 'dart:async';

import 'package:matrix/matrix.dart' as matrix;

import 'send_cancellation.dart';

abstract interface class RecoverableRoomJoining {
  /// [via] names servers to join through when ours is not in the room yet
  /// (for example after resolving a remote alias).
  Future<String> waitForRoomJoin(
    String roomId,
    SendCancellation cancellation, {
    List<String> via,
  });
}

/// Session-owned acknowledgement records outlive route waits. Stopping a wait
/// never cancels delivery or authorises a second POST after an uncertain result.
class RoomJoinOwner {
  RoomJoinOwner(this.client, {required this.ownerCurrent});
  final matrix.Client client;
  final bool Function() ownerCurrent;
  final _requests = <String, _JoinRequest>{};

  void _retire(String roomId, _JoinRequest request) {
    if (identical(_requests[roomId], request)) _requests.remove(roomId);
  }

  Future<String> join(
    String roomId, {
    SendCancellation? cancellation,
    Duration deadline = const Duration(seconds: 30),
    List<String> via = const [],
  }) async {
    void check() {
      cancellation?.check();
      if (!ownerCurrent()) throw StateError('Join session changed');
    }

    check();
    bool joined(String id) =>
        client.getRoomById(id)?.membership == matrix.Membership.join;
    if (joined(roomId)) {
      final previous = _requests[roomId];
      if (previous != null) {
        previous.membershipConfirmed = true;
        if (previous.settled) _retire(roomId, previous);
      }
      return roomId;
    }
    final request = _requests.putIfAbsent(roomId, () {
      final record = _JoinRequest();
      // The generated SDK endpoint pins URL and bearer before its first await,
      // returns acknowledgement only, and performs no post-response mutation.
      unawaited(
        (via.isEmpty
                ? client.joinRoomById(roomId)
                : client.joinRoom(roomId, via: via))
            .then(
              (id) {
                record.id = id;
                record.settled = true;
                if (record.membershipConfirmed && ownerCurrent()) {
                  _retire(roomId, record);
                }
              },
              onError: (Object error) {
                record.error = error;
                record.settled = true;
                // Confirmed membership settles delivery even if its reply is lost.
                // Otherwise only definite Matrix rejections permit another POST;
                // transport, malformed responses and server failures stay uncertain.
                if ((record.membershipConfirmed && ownerCurrent()) ||
                    (error is matrix.MatrixException &&
                        {
                          'M_FORBIDDEN',
                          'M_NOT_FOUND',
                          'M_BAD_JSON',
                          'M_INVALID_PARAM',
                        }.contains(error.errcode))) {
                  _retire(roomId, record);
                }
              },
            ),
      );
      return record;
    });
    final result = Completer<String>();
    void inspect() {
      if (result.isCompleted) return;
      try {
        check();
        final id = request.id ?? roomId;
        if (joined(id)) {
          request.membershipConfirmed = true;
          if (request.settled) _retire(roomId, request);
          result.complete(id);
        } else if (request.settled && request.error != null) {
          result.completeError(request.error!);
        }
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }

    // Observe processed room membership, not only a future sync event: sync can
    // arrive before acknowledgement, or before a route is reopened.
    final sync = client.onSyncStatus.stream.listen((_) => inspect());
    final session = client.onLoginStateChanged.stream.listen((_) => inspect());
    final poll = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => inspect(),
    );
    final timer = Timer(deadline, () {
      if (!result.isCompleted) {
        result.completeError(
          TimeoutException('Join delivery or sync is still unconfirmed'),
        );
      }
    });
    unawaited(
      cancellation?.whenCancelled.then((_) => inspect()) ??
          Future<void>.value(),
    );
    inspect();
    try {
      return await result.future;
    } finally {
      timer.cancel();
      poll.cancel();
      await sync.cancel();
      await session.cancel();
    }
  }
}

class _JoinRequest {
  String? id;
  Object? error;
  bool settled = false;
  bool membershipConfirmed = false;
}
