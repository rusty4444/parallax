import 'dart:async';

import 'package:matrix/matrix.dart' as matrix;

import '../../room_background_store.dart';
import '../../room_events.dart';
import '../media/image_optimiser.dart';
import 'bubble_colours.dart';
import 'sync_ledger.dart';
import 'theme_pictures.dart';

export 'theme_pictures.dart'
    show FileDecrypter, FileEncrypter, MxcDownloader, sniffImageMimeType;

/// Keeps a room's bubble colours and background the same on every device
/// signed in to the account, through Matrix room account data:
///
/// * `net.samrusselltech.parallax.room_theme`: `bubbleColours`.
/// * `net.samrusselltech.parallax.room_background`: the picture, shrunk,
///   encrypted on the device and uploaded to the homeserver; the account data
///   holds its address and key (`file`, the format of encrypted attachments),
///   or `removed: true`.
///
/// The account copy wins unless this device changed the setting and could
/// not upload the change yet (offline); then the newer change wins (see
/// [decideSync]). A background can be kept to this device only.
///
/// Account data is not end-to-end encrypted: the homeserver can read the
/// colours and the background's key.
class RoomThemeSync {
  RoomThemeSync(
    Object backend, {
    RoomBubbleColourStore? colours,
    RoomBackgroundStore? backgrounds,
    SyncLedger? ledger,
    int Function()? now,
    ImagePreparer? prepareImage,
    MxcDownloader? download,
    FileEncrypter? encrypt,
    FileDecrypter? decrypt,
  }) : _access = backend is MatrixSdkAccess ? backend : null,
       colours = colours ?? RoomBubbleColourStore.shared,
       backgrounds = backgrounds ?? RoomBackgroundStore(),
       ledger = ledger ?? SyncLedger.shared,
       _now = now ?? _wallClock,
       _pictures = ThemePictures(
         prepareImage: prepareImage,
         download: download,
         encrypt: encrypt,
         decrypt: decrypt,
       );

  static const coloursType = 'net.samrusselltech.parallax.room_theme';
  static const backgroundType = 'net.samrusselltech.parallax.room_background';

  final MatrixSdkAccess? _access;
  final RoomBubbleColourStore colours;
  final RoomBackgroundStore backgrounds;
  final SyncLedger ledger;
  final int Function() _now;
  final ThemePictures _pictures;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Uploads queued and not started yet, so a slider drag uploads once.
  static final _queued = <String>{};

  /// Whether this helper can sync at all (a Matrix session).
  bool get available => _client != null;

  matrix.Client? get _client {
    final client = _access?.sdkClient;
    return client == null || client.userID == null ? null : client;
  }

  bool _current(matrix.Client client) =>
      _access?.isSessionCurrent(client) ?? false;

  static bool _hasSynced(matrix.Client client) => client.onSync.value != null;

  Object? _tokenColours = _unread, _tokenBackground = _unread;
  static const _unread = Object();

  /// True when the room's synced theme changed since the last call (another
  /// device wrote it, or it just arrived). Cheap: compares event identity.
  bool remoteChanged(String roomId) {
    final room = _client?.getRoomById(roomId);
    final colours = room?.roomAccountData[coloursType];
    final background = room?.roomAccountData[backgroundType];
    final changed =
        !identical(colours, _tokenColours) ||
        !identical(background, _tokenBackground);
    _tokenColours = colours;
    _tokenBackground = background;
    return changed;
  }

  String _key(String userId, String type, String roomId) =>
      SyncLedger.keyFor(userId, type, roomId);

  // Bubble colours ----------------------------------------------------------

  /// Brings this device's bubble colours for [roomId] in line with the
  /// account. True when the colours here changed.
  Future<bool> reconcileColours(String roomId) async {
    final client = _client;
    if (client == null) return false;
    final userId = client.userID!;
    final key = _key(userId, coloursType, roomId);
    return SyncSerial.run(key, () async {
      final remote = await _remote(client, roomId, coloursType);
      if (!_current(client)) return false;
      final entry = await ledger.read(userId, coloursType, roomId);
      final local = await colours.load(roomId);
      final action = decideSync(
        remote: remote,
        entry: entry,
        hasLocal: !local.isEmpty,
        ownWrites: OwnWrites.of(key),
      );
      switch (action) {
        case SyncAction.none:
          return false;
        case SyncAction.adoptRemote:
          final adopted = BubbleColours.fromJson(remote!['bubbleColours']);
          if (!_current(client)) return false;
          await colours.save(roomId, adopted);
          await ledger.write(
            entry.copyWith(
              seen: () => contentHash(remote),
              pending: () => null,
            ),
          );
          return adopted != local;
        case SyncAction.pushLocal:
          // Before the first sync the account copy here may be old; a newer
          // change from another device must not be overwritten.
          if (!_hasSynced(client)) return false;
          await _pushColours(client, roomId, entry.pending ?? _now());
          return false;
      }
    });
  }

  /// Call after saving new colours for [roomId] on this device: records the
  /// change and uploads it (retried later if it can't be uploaded now).
  Future<void> coloursChanged(String roomId) async {
    final client = _client;
    if (client == null) return;
    final userId = client.userID!;
    final entry = await ledger.read(userId, coloursType, roomId);
    await ledger.write(entry.copyWith(pending: _now));
    _queueUpload(client, roomId, coloursType);
  }

  Future<void> _pushColours(
    matrix.Client client,
    String roomId,
    int updatedAt,
  ) async {
    final local = await colours.load(roomId);
    await _put(client, roomId, coloursType, {
      'version': 1,
      'updatedAt': updatedAt,
      'bubbleColours': local.toJson(),
    });
  }

  // Background --------------------------------------------------------------

  /// Brings this device's background for [roomId] in line with the account.
  /// True when the background file here changed.
  Future<bool> reconcileBackground(String roomId) async {
    final client = _client;
    if (client == null) return false;
    final userId = client.userID!;
    final key = _key(userId, backgroundType, roomId);
    return SyncSerial.run(key, () async {
      final entry = await ledger.read(userId, backgroundType, roomId);
      if (entry.localOnly) return false;
      final remote = await _remote(client, roomId, backgroundType);
      if (!_current(client)) return false;
      final local = await backgrounds.fileFor(roomId);
      final action = decideSync(
        remote: remote,
        entry: entry,
        hasLocal: local != null,
        ownWrites: OwnWrites.of(key),
      );
      switch (action) {
        case SyncAction.none:
          return false;
        case SyncAction.adoptRemote:
          final file = remote!['file'];
          if (remote['removed'] == true || file is! Map) {
            if (!_current(client)) return false;
            await backgrounds.clear(roomId);
          } else {
            final bytes = await _pictures.download(
              client,
              Map<String, Object?>.from(file),
              isCurrent: () => _current(client),
            );
            // Not marked as seen: the next open tries again.
            if (bytes == null || !_current(client)) return false;
            await backgrounds.replaceBytes(roomId, bytes);
          }
          await ledger.write(
            entry.copyWith(
              seen: () => contentHash(remote),
              pending: () => null,
            ),
          );
          return true;
        case SyncAction.pushLocal:
          if (!_hasSynced(client)) return false;
          await _pushBackground(client, roomId, entry.pending ?? _now());
          return false;
      }
    });
  }

  /// Call after choosing or removing [roomId]'s background on this device.
  Future<void> backgroundChanged(String roomId) async {
    final client = _client;
    if (client == null) return;
    final userId = client.userID!;
    final entry = await ledger.read(userId, backgroundType, roomId);
    if (entry.localOnly) return;
    await ledger.write(entry.copyWith(pending: _now));
    _queueUpload(client, roomId, backgroundType);
  }

  /// Whether [roomId]'s background stays on this device only.
  Future<bool> backgroundDeviceOnly(String roomId) async {
    final client = _client;
    if (client == null) return false;
    return (await ledger.read(
      client.userID!,
      backgroundType,
      roomId,
    )).localOnly;
  }

  /// Keeps [roomId]'s background on this device only, or syncs it again.
  /// Syncing again takes the account's background when there is one, else
  /// uploads this device's. True when the background file here changed.
  Future<bool> setBackgroundDeviceOnly(String roomId, bool deviceOnly) async {
    final client = _client;
    if (client == null) return false;
    final userId = client.userID!;
    final key = _key(userId, backgroundType, roomId);
    await SyncSerial.run(key, () async {
      final entry = await ledger.read(userId, backgroundType, roomId);
      await ledger.write(
        entry.copyWith(
          localOnly: deviceOnly,
          seen: () => null,
          pending: () => null,
        ),
      );
    });
    return deviceOnly ? false : reconcileBackground(roomId);
  }

  Future<void> _pushBackground(
    matrix.Client client,
    String roomId,
    int updatedAt,
  ) async {
    final file = await backgrounds.fileFor(roomId);
    if (file == null) {
      await _put(client, roomId, backgroundType, {
        'version': 1,
        'updatedAt': updatedAt,
        'removed': true,
      });
      return;
    }
    final picture = await _pictures.upload(
      client,
      await file.readAsBytes(),
      isCurrent: () => _current(client),
    );
    if (picture == null) return;
    await _put(client, roomId, backgroundType, {
      'version': 1,
      'updatedAt': updatedAt,
      ...picture,
    });
  }

  // Shared ------------------------------------------------------------------

  /// Uploads every change this device could not upload yet (offline, or the
  /// app closed first). Run once the session is ready.
  Future<void> flushPending() async {
    final client = _client;
    if (client == null) return;
    final entries = await ledger.pending(client.userID!);
    for (final entry in entries) {
      final roomId = entry.roomId;
      if (roomId == null || !_current(client)) continue;
      if (entry.type == coloursType) {
        await reconcileColours(roomId).catchError((Object _) => false);
      } else if (entry.type == backgroundType) {
        await reconcileBackground(roomId).catchError((Object _) => false);
      }
    }
  }

  void _queueUpload(matrix.Client client, String roomId, String type) {
    final key = _key(client.userID!, type, roomId);
    if (!_queued.add(key)) return;
    unawaited(
      SyncSerial.run(key, () async {
        _queued.remove(key);
        if (!_current(client)) return;
        final entry = await ledger.read(client.userID!, type, roomId);
        final pending = entry.pending;
        if (pending == null || entry.localOnly) return;
        if (type == coloursType) {
          await _pushColours(client, roomId, pending);
        } else {
          await _pushBackground(client, roomId, pending);
        }
      }).catchError((Object _) {
        // Stays pending: retried when the room opens or the app starts.
      }),
    );
  }

  /// Writes [content] to the account, then records it as this device's
  /// latest known copy. A newer local change made meanwhile stays pending.
  Future<void> _put(
    matrix.Client client,
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    final userId = client.userID!;
    if (!_current(client)) return;
    await client.request(
      matrix.RequestType.PUT,
      _path(userId, roomId, type),
      data: content,
    );
    if (!_current(client)) return;
    final hash = contentHash(content);
    OwnWrites.add(_key(userId, type, roomId), hash);
    // Until the sync echo arrives, readers see what was just written.
    final room = client.getRoomById(roomId);
    room?.roomAccountData[type] = matrix.BasicEvent(
      type: type,
      content: content,
    );
    final entry = await ledger.read(userId, type, roomId);
    final sent = content['updatedAt'];
    await ledger.write(
      entry.copyWith(
        seen: () => hash,
        pending: () => entry.pending == sent ? null : entry.pending,
      ),
    );
  }

  static String _path(String userId, String roomId, String type) =>
      '/client/v3/user/${Uri.encodeComponent(userId)}'
      '/rooms/${Uri.encodeComponent(roomId)}/account_data/$type';

  /// The account's copy: synced account data, else read from the server.
  /// Null when the account has none; throws when it can't be read.
  Future<Map<String, Object?>?> _remote(
    matrix.Client client,
    String roomId,
    String type,
  ) async {
    final room = client.getRoomById(roomId);
    final cached = room?.roomAccountData[type]?.content;
    if (cached != null) return Map<String, Object?>.from(cached);
    // Sync delivers every joined room's account data, and the SDK loads it
    // all at startup: after a sync, absent here means absent on the server.
    if (room != null && _hasSynced(client)) return null;
    try {
      return await client.request(
        matrix.RequestType.GET,
        _path(client.userID!, roomId, type),
      );
    } on matrix.MatrixException catch (error) {
      if (error.error == matrix.MatrixError.M_NOT_FOUND) return null;
      rethrow;
    }
  }
}
