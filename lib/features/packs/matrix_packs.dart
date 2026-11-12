import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as matrix;

import '../../media_download.dart';
import '../../room_events.dart';
import 'pack_features.dart';
import 'pack_model.dart';
import '../../matrix_room_names.dart';

const _maxThumbnailBytes = 512 * 1024;
const _maxCachedImages = 256;
const _maxCachedBytes = 16 * 1024 * 1024;
const _maxConcurrentLoads = 4;

String _roomName(matrix.Room room) {
  try {
    final name = room.parallaxName;
    return name.trim().isEmpty ? room.id : name;
  } catch (_) {
    return room.id;
  }
}

/// The room's own packs from local state (after `postLoad`), by state key.
/// Deleted packs (empty content) are skipped.
List<RoomPackState> roomPacksForClient(matrix.Client client, String roomId) {
  final room = client.getRoomById(roomId);
  final states = room?.states[roomPackEventType];
  if (room == null || states == null) return const [];
  final name = _roomName(room);
  final result = <RoomPackState>[
    for (final entry in states.entries.take(maxAvailablePacks))
      if (entry.value.content.isNotEmpty)
        RoomPackState(
          ref: PackRef.room(roomId, entry.key),
          pack: ImagePack.fromJson(entry.value.content),
          roomName: name,
        ),
  ];
  result.sort((a, b) => a.ref.stateKey.compareTo(b.ref.stateKey));
  return result;
}

/// Packs enabled everywhere, from local account data and room state.
List<RoomPackState> globalPacksForClient(matrix.Client client) {
  final enabled = parseEmoteRooms(
    client.accountData[emoteRoomsEventType]?.content,
  );
  final result = <RoomPackState>[];
  for (final entry in enabled.entries) {
    final room = client.getRoomById(entry.key);
    if (room == null) continue;
    final name = _roomName(room);
    for (final key in entry.value) {
      final state = room.getState(roomPackEventType, key);
      if (state == null || state.content.isEmpty) continue;
      result.add(
        RoomPackState(
          ref: PackRef.room(room.id, key),
          pack: ImagePack.fromJson(state.content),
          roomName: name,
        ),
      );
    }
  }
  return result;
}

ImagePack personalPackForClient(matrix.Client client) =>
    ImagePack.fromJson(client.accountData[userPackEventType]?.content);

/// Packs usable in [roomId] from the client's local state.
AvailablePacks availablePacksForClient(matrix.Client client, String? roomId) =>
    mergeAvailablePacks(
      personal: personalPackForClient(client),
      roomPacks: roomId == null ? const [] : roomPacksForClient(client, roomId),
      globalPacks: globalPacksForClient(client),
    );

/// The `:shortcode:` of a custom-emoji reaction [key] (an `mxc://` URI) in
/// [roomId]'s packs, for `com.beeper.reaction.shortcode` (MSC4027).
String? packShortcodeForKey(matrix.Client client, String roomId, String key) {
  final url = parseMxcUri(key);
  if (url == null) return null;
  try {
    final found = availablePacksForClient(client, roomId).findByUrl(url);
    return found == null ? null : ':${found.image.shortcode}:';
  } catch (_) {
    return null;
  }
}

/// Live [PacksFeatures] over the Matrix SDK. Reads come from the SDK's local
/// state; every write re-reads current server state first and re-checks the
/// session after each await.
class MatrixPacks extends ChangeNotifier implements PacksFeatures {
  MatrixPacks(this._access, this._events);

  final MatrixSdkAccess _access;
  final RoomEventFeatures _events;

  matrix.Client? _client;
  StreamSubscription<matrix.SyncUpdate>? _sync;
  int _generation = 0;
  final _images = <Uri, Uint8List>{};
  int _imageBytes = 0;
  final _inFlight = <Uri, Future<Uint8List?>>{};
  int _active = 0;
  final _waiters = Queue<Completer<void>>();
  final _postLoading = <String>{};
  Future<void> _writes = Future<void>.value();
  final _available = <String?, (List<Object?>, AvailablePacks)>{};
  bool _disposed = false;

  @override
  Listenable get packUpdates => this;

  /// The current client, resetting caches when the session changed. While
  /// offline the backend hides its client, but the session (and its local
  /// state) is unchanged, so reads keep using it.
  matrix.Client? _attach() {
    final previous = _client;
    final client =
        _access.sdkClient ??
        (previous != null && _access.isSessionCurrent(previous)
            ? previous
            : null);
    if (!identical(client, previous)) {
      unawaited(_sync?.cancel());
      _sync = null;
      _generation++;
      _images.clear();
      _imageBytes = 0;
      _inFlight.clear();
      _postLoading.clear();
      _available.clear();
      _client = client;
      if (client != null && !_disposed) {
        _sync = client.onSync.stream.listen(_onSync, onError: (_) {});
      }
    }
    if (client == null || !_access.isSessionCurrent(client)) return null;
    return client;
  }

  matrix.Client _require() {
    final client = _attach();
    if (client == null) throw StateError('Not signed in');
    return client;
  }

  void _check(matrix.Client client, int generation) {
    if (!_access.isSessionCurrent(client) || generation != _generation) {
      throw StateError('Session changed');
    }
  }

  void _changed() {
    _available.clear();
    if (!_disposed) notifyListeners();
  }

  void _onSync(matrix.SyncUpdate update) {
    bool relevantState(Iterable<matrix.MatrixEvent>? events) =>
        events?.any((event) => event.type == roomPackEventType) ?? false;
    final account =
        update.accountData?.any(
          (event) =>
              event.type == userPackEventType ||
              event.type == emoteRoomsEventType,
        ) ??
        false;
    final rooms =
        update.rooms?.join?.values.any(
          (room) =>
              relevantState(room.state) || relevantState(room.timeline?.events),
        ) ??
        false;
    if (account || rooms) _changed();
  }

  /// Identity of every local object [availablePacks] reads, so cached
  /// results are reused only while nothing changed (cheap: no parsing).
  List<Object?> _signature(matrix.Client client, String? roomId) {
    final emoteRooms = client.accountData[emoteRoomsEventType];
    return [
      client.accountData[userPackEventType],
      emoteRooms,
      if (roomId != null)
        ...?client.getRoomById(roomId)?.states[roomPackEventType]?.values,
      for (final entry in parseEmoteRooms(emoteRooms?.content).entries)
        for (final key in entry.value)
          client.getRoomById(entry.key)?.getState(roomPackEventType, key),
    ];
  }

  @override
  AvailablePacks availablePacks(String? roomId) {
    final client = _attach();
    if (client == null) return AvailablePacks.empty;
    try {
      final signature = _signature(client, roomId);
      final cached = _available[roomId];
      if (cached != null && _sameObjects(cached.$1, signature)) {
        return cached.$2;
      }
      final packs = availablePacksForClient(client, roomId);
      if (_available.length > 32) _available.clear();
      _available[roomId] = (signature, packs);
      return packs;
    } catch (_) {
      return AvailablePacks.empty;
    }
  }

  static bool _sameObjects(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  void ensurePacksLoaded(String? roomId) {
    final client = _attach();
    if (client == null) return;
    final ids = <String>{
      ?roomId,
      ...parseEmoteRooms(client.accountData[emoteRoomsEventType]?.content).keys,
    };
    final generation = _generation;
    for (final id in ids) {
      final room = client.getRoomById(id);
      if (room == null || !room.partial || !_postLoading.add(id)) continue;
      // Database read only (no network); notify once it has loaded.
      unawaited(
        Future<void>(() async {
          try {
            await room.postLoad();
            if (_access.isSessionCurrent(client) && generation == _generation) {
              _changed();
            }
          } catch (_) {
            if (generation == _generation) _postLoading.remove(id);
          }
        }),
      );
    }
  }

  @override
  List<RoomPackState> roomPacks(String roomId) {
    final client = _attach();
    if (client == null) return const [];
    try {
      return roomPacksForClient(client, roomId);
    } catch (_) {
      return const [];
    }
  }

  @override
  List<RoomPackState> globalPacks() {
    final client = _attach();
    if (client == null) return const [];
    try {
      return globalPacksForClient(client);
    } catch (_) {
      return const [];
    }
  }

  @override
  ImagePack personalPack() {
    final client = _attach();
    return client == null ? ImagePack.empty : personalPackForClient(client);
  }

  @override
  bool canEditRoomPacks(String roomId) {
    final client = _attach();
    final room = client?.getRoomById(roomId);
    if (room == null) return false;
    try {
      return room.canChangeStateEvent(roomPackEventType);
    } catch (_) {
      return false;
    }
  }

  @override
  bool isEnabledEverywhere(PackRef ref) {
    final client = _attach();
    final roomId = ref.roomId;
    if (client == null || roomId == null) return false;
    return parseEmoteRooms(
          client.accountData[emoteRoomsEventType]?.content,
        )[roomId]?.contains(ref.stateKey) ??
        false;
  }

  @override
  Uint8List? cachedPackImage(Uri url) {
    final bytes = _images.remove(url);
    if (bytes != null) _images[url] = bytes;
    return bytes;
  }

  @override
  Future<Uint8List?> loadPackImage(Uri url) {
    if (parseMxcUri(url.toString()) == null) return Future.value();
    final client = _attach();
    if (client == null) return Future.value();
    final cached = cachedPackImage(url);
    if (cached != null) return Future.value(cached);
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final generation = _generation;
    final pending = _fetch(client, url, generation);
    _inFlight[url] = pending;
    pending.whenComplete(() {
      if (identical(_inFlight[url], pending)) _inFlight.remove(url);
    }).ignore();
    return pending;
  }

  Future<Uint8List?> _fetch(
    matrix.Client client,
    Uri url,
    int generation,
  ) async {
    if (_active >= _maxConcurrentLoads) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      bool current() =>
          _access.isSessionCurrent(client) && generation == _generation;
      if (!current()) return null;
      final thumbnail = await matrix.MxcUriExtension(url).getThumbnailUri(
        client,
        width: 128,
        height: 128,
        method: matrix.ThumbnailMethod.scale,
      );
      final homeserver = client.homeserver;
      final token = client.accessToken;
      if (!current() || homeserver == null || token == null) return null;
      final bytes = await downloadMatrixMedia(
        httpClient: client.httpClient,
        homeserver: homeserver,
        uri: thumbnail,
        accessToken: token,
        maxBytes: _maxThumbnailBytes,
      );
      if (!current() || bytes.isEmpty) return null;
      _images[url] = bytes;
      _imageBytes += bytes.length;
      while (_images.length > _maxCachedImages ||
          _imageBytes > _maxCachedBytes) {
        final oldest = _images.keys.first;
        _imageBytes -= _images.remove(oldest)!.length;
      }
      return bytes;
    } catch (_) {
      return null;
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _writes;
    final next = () async {
      try {
        await previous;
      } catch (_) {}
      return action();
    }();
    _writes = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Map<String, Object?>?> _accountData(
    matrix.Client client,
    String type,
  ) async {
    try {
      return await client.getAccountData(client.userID!, type);
    } on matrix.MatrixException catch (error) {
      if (error.error == matrix.MatrixError.M_NOT_FOUND) return null;
      rethrow;
    }
  }

  Future<ImagePack> _read(matrix.Client client, PackRef ref) async {
    final roomId = ref.roomId;
    final content = roomId == null
        ? await _accountData(client, userPackEventType)
        : await _events.roomState(
            roomId,
            roomPackEventType,
            stateKey: ref.stateKey,
          );
    return ImagePack.fromJson(content);
  }

  Future<void> _write(
    matrix.Client client,
    PackRef ref,
    Map<String, Object?> content,
  ) async {
    final roomId = ref.roomId;
    if (roomId == null) {
      await client.setAccountData(client.userID!, userPackEventType, content);
    } else {
      await _events.setRoomState(
        roomId,
        roomPackEventType,
        content,
        stateKey: ref.stateKey,
      );
    }
  }

  @override
  Future<ImagePack> updatePack(
    PackRef ref,
    ImagePack Function(ImagePack current) change,
  ) => _serial(() async {
    final client = _require();
    final generation = _generation;
    final current = await _read(client, ref);
    _check(client, generation);
    final next = change(current);
    await _write(client, ref, next.toJson());
    _check(client, generation);
    _changed();
    return next;
  });

  @override
  Future<PackRef> createRoomPack(String roomId, String name) =>
      _serial(() async {
        final client = _require();
        final generation = _generation;
        final trimmed = name.trim();
        if (trimmed.isEmpty) throw ArgumentError('A pack needs a name');
        // The first pack uses the default state key, which FluffyChat's
        // room emote settings edit; later packs get a slug of their name.
        final base = packSlug(trimmed);
        final candidates = ['', base, for (var n = 2; n < 20; n++) '$base-$n'];
        for (final key in candidates) {
          final existing = await _events.roomState(
            roomId,
            roomPackEventType,
            stateKey: key,
          );
          _check(client, generation);
          if (existing != null && existing.isNotEmpty) continue;
          final ref = PackRef.room(roomId, key);
          await _write(client, ref, ImagePack(displayName: trimmed).toJson());
          _check(client, generation);
          _changed();
          return ref;
        }
        throw StateError('Too many packs with this name');
      });

  @override
  Future<void> deleteRoomPack(PackRef ref) async {
    if (ref.personal) throw ArgumentError('Only room packs can be deleted');
    await _serial(() async {
      final client = _require();
      final generation = _generation;
      await _write(client, ref, const {});
      _check(client, generation);
      _changed();
    });
    if (isEnabledEverywhere(ref)) {
      await setEnabledEverywhere(ref, enabled: false);
    }
  }

  @override
  Future<void> setEnabledEverywhere(PackRef ref, {required bool enabled}) =>
      _serial(() async {
        final client = _require();
        final generation = _generation;
        final current = await _accountData(client, emoteRoomsEventType);
        _check(client, generation);
        await client.setAccountData(
          client.userID!,
          emoteRoomsEventType,
          setEmoteRoom(current, ref, enabled: enabled),
        );
        _check(client, generation);
        _changed();
      });

  @override
  Future<Uri> uploadPackImage(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
  }) async {
    final client = _require();
    final generation = _generation;
    final uri = await client.uploadContent(
      bytes,
      filename: fileName,
      contentType: mimeType,
    );
    _check(client, generation);
    final mxc = parseMxcUri(uri.toString());
    if (mxc == null) throw StateError('Upload returned an invalid URI');
    return mxc;
  }

  @override
  Future<String> sendSticker(String roomId, PackImage image) => _events
      .sendRoomEvent(roomId, matrix.EventTypes.Sticker, stickerContent(image));

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sync?.cancel());
    super.dispose();
  }
}
