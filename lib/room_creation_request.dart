import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_backend.dart';
import 'feature_settings_scope.dart';

/// Session-owned, non-idempotent POST. A visible deadline is NOT cancellation.
/// Pending/uncertain requests retain their future and lock across route disposal.
/// Only a typed definite non-creation failure permits a corrected submission.
class RoomCreationRequest extends ChangeNotifier {
  RoomCreationRequest._(this.backend) : _owner = BackendSessionOwner(backend);

  static final _requests = Expando<RoomCreationRequest>();

  static RoomCreationRequest forBackend(ChatBackend backend) {
    final previous = _requests[backend];
    if (previous != null && previous._owner.isCurrent) return previous;
    previous?._retire();
    return _requests[backend] = RoomCreationRequest._(backend);
  }

  final ChatBackend backend;
  final BackendSessionOwner _owner;
  Timer? _timer;
  Future<String>? originalRequest;
  String? roomId;
  RoomCreationFailure? failure;
  bool uncertain = false;
  bool _retired = false;

  bool get active => originalRequest != null;

  void start(String name, {required bool encrypted}) {
    if (active || !_owner.isCurrent || _retired) return;
    failure = null;
    uncertain = false;
    // Future.sync also observes synchronous admission/validation failures.
    originalRequest = Future.sync(
      () => backend.createRoom(name, encrypted: encrypted),
    );
    _timer = Timer(const Duration(seconds: 10), () {
      if (_retired || !_owner.isCurrent) return;
      uncertain = true;
      notifyListeners();
    });
    originalRequest!.then(
      (id) {
        _timer?.cancel();
        if (_retired || !_owner.isCurrent) return;
        roomId = id;
        uncertain = false;
        notifyListeners();
      },
      onError: (Object error, StackTrace _) {
        _timer?.cancel();
        if (_retired || !_owner.isCurrent) return;
        if (error is RoomCreationFailure) {
          originalRequest = null;
          failure = error;
          uncertain = false;
          notifyListeners();
          return;
        }
        // A transport failure can happen after delivery. Without an ID there
        // is no safe correlation/retry for createRoom; never issue another POST.
        uncertain = true;
        notifyListeners();
      },
    );
    notifyListeners();
  }

  void acknowledgeOpened(String id) {
    if (roomId != id || !_owner.isCurrent) return;
    originalRequest = null;
    roomId = null;
    uncertain = false;
  }

  void detach(VoidCallback listener) {
    removeListener(listener);
    if (!active && !hasListeners) {
      _requests[backend] = null;
      _retire();
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _timer?.cancel();
    _owner.release();
  }
}
