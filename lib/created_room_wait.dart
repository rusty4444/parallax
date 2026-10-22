import 'dart:async';

import 'chat_backend.dart';

/// Wait for an acknowledged room without leaving SDK stream listeners alive or
/// submitting another create request. The caller retains the room ID on timeout.
class CreatedRoomWait {
  CreatedRoomWait({
    required this.backend,
    required this.roomId,
    required this.isCurrent,
    Duration timeout = const Duration(seconds: 10),
  }) {
    backend.addListener(_check);
    _timer = Timer(timeout, () => _finish(false));
    _check();
  }

  final ChatBackend backend;
  final String roomId;
  final bool Function() isCurrent;
  final _result = Completer<bool>();
  Timer? _timer;

  Future<bool> get result => _result.future;

  void _check() {
    if (!isCurrent()) {
      _finish(false);
    } else if (backend.rooms.any(
      (room) => room.id == roomId && !room.invited,
    )) {
      _finish(true);
    }
  }

  void cancel() => _finish(false);

  void _finish(bool ready) {
    if (_result.isCompleted) return;
    _timer?.cancel();
    backend.removeListener(_check);
    _result.complete(ready);
  }
}
