import 'dart:async';

import 'message_draft_store.dart';

/// Route/revision ownership and I/O ordering for one account/room draft.
///
/// A retained send may clear an accepted draft after its route closes, but
/// claiming a replacement route revokes that right even for identical text.
/// Scopes outlive routes only while a send or storage operation retains them.
class RoomDraftOwner {
  RoomDraftOwner.claim(this.accountKey, this.roomId)
    : _scope = _scopes.putIfAbsent((accountKey, roomId), _RoomDraftScope.new) {
    _scope.current = this;
    _scope.references++;
    _scope.revision++;
  }

  static final _scopes = <(String, String), _RoomDraftScope>{};
  final String accountKey;
  final String roomId;
  final _RoomDraftScope _scope;

  bool get isCurrent => identical(_scope.current, this);
  int get revision => _scope.revision;

  void revise() {
    if (isCurrent) _scope.revision++;
  }

  void retain() => _scope.references++;

  void release() {
    _scope.references--;
    if (_scope.references == 0) {
      _scopes.remove((accountKey, roomId));
    }
  }

  Future<String?> read(MessageDraftStore store) =>
      _ordered(() => store.read(accountKey, roomId));

  /// Recheck at actual invocation, not before waiting behind older I/O.
  Future<void> write(
    MessageDraftStore store,
    String text, {
    required int revision,
    required bool Function() sessionIsCurrent,
  }) => _ordered(() async {
    if (!isCurrent || this.revision != revision || !sessionIsCurrent()) return;
    await store.write(accountKey, roomId, text);
  });

  Future<T> _ordered<T>(Future<T> Function() operation) {
    retain();
    final result = _scope.tail.then((_) => operation());
    _scope.tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result.whenComplete(release);
  }
}

class _RoomDraftScope {
  RoomDraftOwner? current;
  int references = 0;
  int revision = 0;
  Future<void> tail = Future<void>.value();
}
