import 'dart:async';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'retention_model.dart';

/// Backend surface of the disappearing-messages module.
abstract interface class RetentionFeatures {
  /// The room's retention policy read fresh from the homeserver.
  Future<RoomRetention> retentionOf(String roomId);

  /// Sets (or clears, with null) the room's `m.room.retention` policy.
  Future<void> setRetention(String roomId, Duration? lifetime);

  /// Synchronous projection from loaded room state, for hooks. Null when the
  /// room's state is not loaded yet.
  RoomRetention? cachedRetention(String roomId);
}

final _features = Expando<RetentionFeatures>();

RetentionFeatures? retentionFeaturesOf(ChatBackend backend) {
  if (backend is RetentionFeatures) return backend as RetentionFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _features[backend] ??= MatrixRetention(backend);
  }
  return null;
}

/// Live implementation over the Matrix SDK. Reads go through `sdkClient`,
/// the policy write through [RoomEventFeatures.setRoomState] (the server makes
/// the final authorisation decision); every await is followed by a session
/// check.
class MatrixRetention implements RetentionFeatures {
  MatrixRetention(this.backend)
    : assert(backend is MatrixSdkAccess && backend is RoomEventFeatures);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;
  RoomEventFeatures get _events => backend as RoomEventFeatures;

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !client.isLogged()) {
      throw StateError('Not signed in');
    }
    return client;
  }

  @override
  RoomRetention? cachedRetention(String roomId) {
    final room = _sdk.sdkClient?.getRoomById(roomId);
    if (room == null) return null;
    final state = room.getState(RoomRetention.eventType);
    if (state == null) return null;
    return RoomRetention.fromContent(state.content);
  }

  @override
  Future<RoomRetention> retentionOf(String roomId) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Room is not joined');
    // Retention is not an important state event: load it for rooms that were
    // never opened before reading the fresh server value.
    await room.postLoad();
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
    final content = await _events.roomState(roomId, RoomRetention.eventType);
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
    return RoomRetention.fromContent(content);
  }

  @override
  Future<void> setRetention(String roomId, Duration? lifetime) async {
    final client = _client();
    final content = RoomRetention(maxLifetime: lifetime).toContent();
    await _events.setRoomState(roomId, RoomRetention.eventType, content);
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
  }
}
