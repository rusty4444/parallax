import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'live_location_model.dart';
import 'live_location_sharer.dart';
import 'matrix_live_location.dart';
import 'position_source.dart';

/// Someone's live share as displayed: the `beacon_info` and its latest
/// valid beacon.
@immutable
class LiveShareSnapshot {
  const LiveShareSnapshot({
    required this.info,
    required this.live,
    required this.displayName,
    required this.mine,
    this.latest,
    this.avatarUrl,
    this.loading = false,
  });

  final BeaconInfo info;
  final BeaconLocation? latest;

  /// Live now: `live` set, inside its period and not replaced by a later
  /// `beacon_info` for the same state key.
  final bool live;
  final String displayName;
  final Uri? avatarUrl;
  final bool mine;

  /// Earlier beacons are still being fetched.
  final bool loading;

  String get userId => info.sender;
}

/// Live location operations for the module. The live Matrix implementation
/// is [MatrixLiveLocation]; tests implement this directly.
abstract interface class LiveLocationFeatures {
  /// Notifies when shares, beacons or this device's sharing change.
  Listenable get updates;

  String? get myUserId;

  /// Device location used for sharing (permission checks/prompts).
  LivePositionSource get positions;

  /// Current live shares in [roomId] (one per sharer), own first, then the
  /// most recently started.
  List<LiveShareSnapshot> liveShares(String roomId);

  /// The share started by [info] (live or ended) with its latest beacon.
  LiveShareSnapshot shareSnapshot(String roomId, BeaconInfo info);

  /// Starts fetching [info]'s earlier beacons once (idempotent; never
  /// notifies synchronously).
  void ensureBeaconsLoaded(String roomId, BeaconInfo info);

  /// The share this device is running in [roomId], if any.
  OwnShare? deviceShare(String roomId);

  /// Whether the room's power levels let this user share live location
  /// (send `beacon_info` state and `beacon` events).
  bool canShareIn(String roomId);

  /// Starts sharing; location permission must already be granted.
  Future<void> startSharing(String roomId, Duration duration);

  /// Stops this user's live share in [roomId] (from any device).
  Future<void> stopSharing(String roomId);
}

/// Session-level operations used by the signed-in app wrapper.
abstract interface class LiveLocationLifecycle {
  /// Resumes shares this device started before a restart.
  Future<void> resumeShares();

  /// Ends every own share on the server and forgets local records. Call
  /// before signing out, while the session can still write.
  Future<void> stopAllShares();
}

final Expando<MatrixLiveLocation> _matrixLiveLocation = Expando(
  'parallax.live_location',
);

MatrixLiveLocation? _matrixLiveLocationFor(ChatBackend backend) {
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _matrixLiveLocation[backend] ??= MatrixLiveLocation(
      backend as MatrixSdkAccess,
      backend as RoomEventFeatures,
    );
  }
  return null;
}

/// Live location for [backend], or null when unsupported.
LiveLocationFeatures? liveLocationFeaturesOf(ChatBackend backend) =>
    backend is LiveLocationFeatures
    ? backend as LiveLocationFeatures
    : _matrixLiveLocationFor(backend);

/// Session lifecycle for [backend], or null when unsupported.
LiveLocationLifecycle? liveLocationLifecycleOf(ChatBackend backend) =>
    backend is LiveLocationLifecycle
    ? backend as LiveLocationLifecycle
    : _matrixLiveLocationFor(backend);
