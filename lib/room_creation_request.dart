import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixException;

import 'chat_backend.dart';
import 'feature_settings_scope.dart';

/// Matrix error codes that prove `/createRoom` did not create a room. The SDK
/// does not retain the HTTP status on generated API errors, so M_UNKNOWN,
/// generic server errors, malformed replies and transport failures stay
/// uncertain.
const definiteRoomCreationRefusals = {
  'M_FORBIDDEN',
  'M_UNAUTHORIZED',
  'M_UNKNOWN_TOKEN',
  'M_MISSING_TOKEN',
  'M_USER_DEACTIVATED',
  'M_GUEST_ACCESS_FORBIDDEN',
  'M_LIMIT_EXCEEDED',
  'M_RESOURCE_LIMIT_EXCEEDED',
  'M_BAD_JSON',
  'M_NOT_JSON',
  'M_MISSING_PARAM',
  'M_INVALID_PARAM',
  'M_UNSUPPORTED_ROOM_VERSION',
  'M_ROOM_IN_USE',
  'M_EXCLUSIVE',
};

/// A typed definite failure for [error], or null when delivery is uncertain.
RoomCreationFailure? definiteRoomCreationFailure(Object error) {
  if (error is RoomCreationFailure) return error;
  if (error is MatrixException &&
      definiteRoomCreationRefusals.contains(error.errcode)) {
    return error.errcode == 'M_ROOM_IN_USE'
        ? const RoomCreationFailure.notSubmitted(
            'That room address is already taken. Choose another address.',
          )
        : const RoomCreationFailure.rejected();
  }
  return null;
}

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

  void start(String name, {required bool encrypted}) =>
      startWith(() => backend.createRoom(name, encrypted: encrypted));

  /// Starts any single non-idempotent create (for example a configured room
  /// from the start-chat flow) under the same session-owned admission.
  /// [submit] must throw [RoomCreationFailure] only for definite non-creation.
  void startWith(Future<String> Function() submit) {
    if (active || !_owner.isCurrent || _retired) return;
    failure = null;
    uncertain = false;
    // Future.sync also observes synchronous admission/validation failures.
    originalRequest = Future.sync(submit);
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
