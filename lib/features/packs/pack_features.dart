import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'matrix_packs.dart';
import 'pack_model.dart';

/// Custom emoji and sticker packs (MSC2545) for one signed-in account. The
/// live implementation is [MatrixPacks]; tests implement this directly.
abstract interface class PacksFeatures {
  /// Notifies when packs may have changed (sync, post-load, own writes).
  Listenable get packUpdates;

  /// Packs usable in [roomId] (personal, the room's, enabled everywhere), or
  /// only personal and enabled-everywhere packs when [roomId] is null.
  /// Reads local state; cheap enough for `build`.
  AvailablePacks availablePacks(String? roomId);

  /// Loads room state needed for [roomId]'s packs and packs enabled
  /// everywhere. Idempotent, never notifies synchronously.
  void ensurePacksLoaded(String? roomId);

  /// The room's own packs (including packs without images), by state key.
  List<RoomPackState> roomPacks(String roomId);

  /// Packs enabled for all rooms, in stored order.
  List<RoomPackState> globalPacks();

  /// The personal pack (`im.ponies.user_emotes`), empty when unset.
  ImagePack personalPack();

  /// Whether local power levels let this user change the room's packs. The
  /// homeserver makes the final decision on write.
  bool canEditRoomPacks(String roomId);

  bool isEnabledEverywhere(PackRef ref);

  /// Bytes of a pack image thumbnail if already cached.
  Uint8List? cachedPackImage(Uri url);

  /// Downloads a bounded pack image thumbnail (authenticated media), or null.
  Future<Uint8List?> loadPackImage(Uri url);

  /// Reads the current pack from the homeserver, applies [change] and writes
  /// it back. Writes are serialised per account. Returns the written pack.
  Future<ImagePack> updatePack(
    PackRef ref,
    ImagePack Function(ImagePack current) change,
  );

  /// Creates an empty room pack called [name] and returns its reference.
  Future<PackRef> createRoomPack(String roomId, String name);

  /// Removes a room pack (writes empty state) and its "use everywhere" entry.
  Future<void> deleteRoomPack(PackRef ref);

  /// Adds or removes a room pack from `im.ponies.emote_rooms`.
  Future<void> setEnabledEverywhere(PackRef ref, {required bool enabled});

  /// Uploads image bytes (unencrypted, as packs are shared) and returns the
  /// `mxc://` URI.
  Future<Uri> uploadPackImage(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
  });

  /// Sends [image] as an `m.sticker` through the guarded room-event path.
  Future<String> sendSticker(String roomId, PackImage image);
}

/// `m.sticker` content for [image] (MSC2545 / Matrix spec).
Map<String, Object?> stickerContent(PackImage image) {
  final info = <String, Object?>{
    'w': ?image.width,
    'h': ?image.height,
    'mimetype': ?image.mimetype,
    'size': ?image.size,
  };
  return {'body': image.description, 'url': image.url.toString(), 'info': info};
}

final Expando<MatrixPacks> _matrixPacks = Expando('parallax.packs');
WeakReference<ChatBackend>? _lastBackend;

MatrixPacks? _matrixPacksFor(ChatBackend backend) {
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _matrixPacks[backend] ??= MatrixPacks(
      backend as MatrixSdkAccess,
      backend as RoomEventFeatures,
    );
  }
  return null;
}

/// Pack operations for [backend], or null when unsupported. Also remembers
/// [backend] as the signed-in account for widgets that render custom emoji
/// without a backend in reach (see [currentPacksBackend]).
PacksFeatures? packsFeaturesOf(ChatBackend backend) {
  final features = backend is PacksFeatures
      ? backend as PacksFeatures
      : _matrixPacksFor(backend);
  if (features != null && _lastBackend?.target != backend) {
    _lastBackend = WeakReference(backend);
  }
  return features;
}

/// The backend most recently used with packs (the app has one signed-in
/// backend at a time). Its own session checks guard every load.
ChatBackend? get currentPacksBackend => _lastBackend?.target;

@visibleForTesting
void resetCurrentPacksBackend() => _lastBackend = null;
